#!/usr/bin/env python3
"""Execute Ouro's committed compute shaders on Vulkan (including lavapipe).

Run: uv run --with vulkan --with pillow python test/vulkan-cursor.py
Optional: --capture path.png (uses installed Adwaita Xcursor assets).
Use --compare-shader-dir with saved pre-change SPIR-V for identical-source A/B.
No DRM device, compositor session, or display server is required.
"""

import argparse
from contextlib import ExitStack
import math
from pathlib import Path
import struct

import vulkan as v
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def sampling_filter(source_size, size, crop):
    sw, sh = source_size
    w, h = size
    x, y, cw, ch = crop
    if cw == w and ch == h and x == int(x) and y == int(y):
        return "nearest"
    if cw > 2 * w or ch > 2 * h:
        return "area"
    if crop == (0, 0, sw, sh) and cw < w and ch < h:
        return "bilinear"
    return "reconstruction"


class Renderer:
    def __init__(self):
        self.draw_count = 0
        self.instance = v.vkCreateInstance(v.VkInstanceCreateInfo(), None)
        self.gpu = v.vkEnumeratePhysicalDevices(self.instance)[0]
        self.family = next(i for i, p in enumerate(v.vkGetPhysicalDeviceQueueFamilyProperties(self.gpu))
                           if p.queueFlags & v.VK_QUEUE_COMPUTE_BIT)
        self.device = v.vkCreateDevice(self.gpu, v.VkDeviceCreateInfo(
            pQueueCreateInfos=[v.VkDeviceQueueCreateInfo(queueFamilyIndex=self.family,
                                                       pQueuePriorities=[1.0])],
            pEnabledFeatures=v.VkPhysicalDeviceFeatures(shaderStorageImageWriteWithoutFormat=True)), None)
        self.queue = v.vkGetDeviceQueue(self.device, self.family, 0)
        self.memory = v.vkGetPhysicalDeviceMemoryProperties(self.gpu)
        print("Vulkan device:", v.vkGetPhysicalDeviceProperties(self.gpu).deviceName)

    def close(self):
        v.vkDestroyDevice(self.device, None)
        v.vkDestroyInstance(self.instance, None)

    def render(self, pixels, source_size, size, mode, xrgb=False,
               alpha=255, crop=None, transform=0, filtering=None, shader_dir=None,
               alpha_mode=0, background=(80, 100, 120), background_alpha=255, ten_bit=False,
               output_transfer=0, source_transfer=0, color_matrix=(1, 0, 0, 0, 1, 0, 0, 0, 1),
               luminance_scale=1, capture_matrix=(1, 0, 0, 0, 1, 0, 0, 0, 1),
               capture_phases=None, continuation=False, capture_sequence=False, copy_capture=False):
        d = self.device
        sw, sh = source_size
        w, h = size
        texture = mode != "buffer"
        with ExitStack() as cleanup:
            def own(create, destroy, info):
                obj = create(d, info, None)
                cleanup.callback(destroy, d, obj, None)
                return obj

            def memory(requirements, flags):
                index = next(i for i in range(self.memory.memoryTypeCount)
                             if requirements.memoryTypeBits & (1 << i) and
                             self.memory.memoryTypes[i].propertyFlags & flags == flags)
                return own(v.vkAllocateMemory, v.vkFreeMemory, v.VkMemoryAllocateInfo(
                    allocationSize=requirements.size, memoryTypeIndex=index))

            def buffer(data, usage):
                b = v.vkCreateBuffer(d, v.VkBufferCreateInfo(size=len(data), usage=usage), None)
                m = memory(v.vkGetBufferMemoryRequirements(d, b),
                           v.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | v.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
                cleanup.callback(v.vkDestroyBuffer, d, b, None)
                v.vkBindBufferMemory(d, b, m, 0)
                mapped = v.vkMapMemory(d, m, 0, len(data), 0)
                mapped[:] = data
                v.vkUnmapMemory(d, m)
                return b, m, len(data)

            subresource = v.VkImageSubresourceRange(aspectMask=v.VK_IMAGE_ASPECT_COLOR_BIT,
                                                   levelCount=1, layerCount=1)

            def image(width, height, fmt, usage):
                im = v.vkCreateImage(d, v.VkImageCreateInfo(imageType=v.VK_IMAGE_TYPE_2D,
                    format=fmt, extent=v.VkExtent3D(width=width, height=height, depth=1),
                    mipLevels=1, arrayLayers=1, samples=v.VK_SAMPLE_COUNT_1_BIT,
                    tiling=v.VK_IMAGE_TILING_OPTIMAL, usage=usage), None)
                m = memory(v.vkGetImageMemoryRequirements(d, im), 0)
                cleanup.callback(v.vkDestroyImage, d, im, None)
                v.vkBindImageMemory(d, im, m, 0)
                view = own(v.vkCreateImageView, v.vkDestroyImageView, v.VkImageViewCreateInfo(
                    image=im, viewType=v.VK_IMAGE_VIEW_TYPE_2D, format=fmt, subresourceRange=subresource))
                return im, view

            sx, sy, cw, ch = crop or (0, 0, sw, sh)
            native_destination = size[::-1] if transform % 2 else size
            dx, dy = int(cw * 65536) // native_destination[0], int(ch * 65536) // native_destination[1]
            left, top = int(sx * 65536) + dx // 2, int(sy * 65536) + dy // 2
            right, bottom = int((sx + cw) * 65536) - dx // 2, int((sy + ch) * 65536) - dy // 2
            xx, xy, x0, yx, yy, y0 = (
                (dx, 0, left, 0, dy, top), (0, -dx, right, dy, 0, top),
                (-dx, 0, right, 0, -dy, bottom), (0, dx, left, -dy, 0, bottom),
                (-dx, 0, right, 0, dy, top), (0, dx, left, dy, 0, top),
                (dx, 0, left, 0, -dy, bottom), (0, -dx, right, -dy, 0, bottom),
            )[transform]
            filtering = filtering or sampling_filter(source_size, native_destination, (sx, sy, cw, ch))
            flags = {"nearest": 0, "reconstruction": 1, "bilinear": 2, "area": 3}[filtering] << 28
            flags |= 0x40000000 if mode == "texture-buffer" else 0
            # Include the opaque fast path: it must not bypass filtering.
            if xrgb and alpha == 255 and output_transfer == source_transfer:
                flags |= 0x80000000
            sample = struct.pack("<4I12i4I8i12f", 0, sw, sh, sw * 4,
                int(sx * 65536), int(sy * 65536), int(cw * 65536), int(ch * 65536),
                0, 0, w, h, 0, 0, w, h, int(xrgb), flags, alpha, source_transfer,
                xx, xy, x0, yx, yy, y0, alpha_mode, 0,
                *color_matrix[:3], luminance_scale, *color_matrix[3:6], 0, *color_matrix[6:], 0)
            storage = v.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
            samples = buffer(sample, storage)
            source = buffer(pixels, storage | v.VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
            lut = buffer(bytes(16), storage)
            readback = buffer(bytes(w * h * 4), v.VK_BUFFER_USAGE_TRANSFER_DST_BIT)
            captures = [buffer(bytes([37]) * (w * h * 4), storage | v.VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
                        for _ in range(2)]
            target, target_view = image(w, h, v.VK_FORMAT_A2B10G10R10_UNORM_PACK32 if ten_bit else v.VK_FORMAT_R8G8B8A8_UNORM,
                v.VK_IMAGE_USAGE_STORAGE_BIT | v.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
            src_image, src_view = image(sw, sh, v.VK_FORMAT_B8G8R8A8_UNORM,
                v.VK_IMAGE_USAGE_SAMPLED_BIT | v.VK_IMAGE_USAGE_TRANSFER_DST_BIT)
            linear, linear_view = image(w, h, v.VK_FORMAT_R16G16B16A16_SFLOAT, v.VK_IMAGE_USAGE_STORAGE_BIT)
            if copy_capture:
                copied, _ = image(w, h, v.VK_FORMAT_B8G8R8A8_UNORM,
                                  v.VK_IMAGE_USAGE_TRANSFER_DST_BIT | v.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
                copied_readback = buffer(bytes(w * h * 4), v.VK_BUFFER_USAGE_TRANSFER_DST_BIT)
            sampler = own(v.vkCreateSampler, v.vkDestroySampler, v.VkSamplerCreateInfo(
                magFilter=v.VK_FILTER_NEAREST, minFilter=v.VK_FILTER_NEAREST,
                addressModeU=v.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeV=v.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeW=v.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE))
            types = {0: (v.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1),
                     1: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1),
                     4: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1),
                     10: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1),
                     11: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)}
            if texture:
                types.update({3: (v.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 32),
                              5: (v.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1),
                              6: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)})
            else:
                types[2] = (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)
            layout = own(v.vkCreateDescriptorSetLayout, v.vkDestroyDescriptorSetLayout,
                v.VkDescriptorSetLayoutCreateInfo(pBindings=[v.VkDescriptorSetLayoutBinding(
                    binding=b, descriptorType=t, descriptorCount=n, stageFlags=v.VK_SHADER_STAGE_COMPUTE_BIT)
                    for b, (t, n) in types.items()]))
            pool = own(v.vkCreateDescriptorPool, v.vkDestroyDescriptorPool, v.VkDescriptorPoolCreateInfo(
                maxSets=1, pPoolSizes=[v.VkDescriptorPoolSize(type=t, descriptorCount=n)
                                     for t, n in types.values()]))
            ds = v.vkAllocateDescriptorSets(d, v.VkDescriptorSetAllocateInfo(
                descriptorPool=pool, pSetLayouts=[layout]))[0]
            writes = []
            for b, (t, n) in types.items():
                if b in (1, 2, 4, 6, 10, 11):
                    buf = captures[b - 10] if b >= 10 else samples if b == 1 else lut if b == 4 else source
                    args = dict(pBufferInfo=[v.VkDescriptorBufferInfo(buffer=buf[0], offset=0, range=buf[2])])
                else:
                    view = target_view if b == 0 else linear_view if b == 5 else src_view
                    args = dict(pImageInfo=[v.VkDescriptorImageInfo(sampler=sampler, imageView=view,
                                                                  imageLayout=v.VK_IMAGE_LAYOUT_GENERAL)] * n)
                writes.append(v.VkWriteDescriptorSet(dstSet=ds, dstBinding=b, descriptorType=t,
                                                    descriptorCount=n, **args))
            v.vkUpdateDescriptorSets(d, len(writes), writes, 0, None)
            pl = own(v.vkCreatePipelineLayout, v.vkDestroyPipelineLayout, v.VkPipelineLayoutCreateInfo(
                pSetLayouts=[layout], pPushConstantRanges=[v.VkPushConstantRange(
                    stageFlags=v.VK_SHADER_STAGE_COMPUTE_BIT, size=112)]))
            shader_name = "vulkan_texture_composite" if texture else "vulkan_composite"
            code = ((shader_dir or ROOT / "src/render") /
                    (shader_name + ("_10bit" if ten_bit else "") + ".spv")).read_bytes()
            module = own(v.vkCreateShaderModule, v.vkDestroyShaderModule,
                         v.VkShaderModuleCreateInfo(codeSize=len(code), pCode=code))
            stage = v.VkPipelineShaderStageCreateInfo(stage=v.VK_SHADER_STAGE_COMPUTE_BIT,
                                                    module=module, pName="main")
            pipeline = v.vkCreateComputePipelines(d, v.VK_NULL_HANDLE, 1,
                [v.VkComputePipelineCreateInfo(stage=stage, layout=pl)], None)[0]
            cleanup.callback(v.vkDestroyPipeline, d, pipeline, None)
            cp = own(v.vkCreateCommandPool, v.vkDestroyCommandPool,
                     v.VkCommandPoolCreateInfo(queueFamilyIndex=self.family))
            cmd = v.vkAllocateCommandBuffers(d, v.VkCommandBufferAllocateInfo(commandPool=cp,
                level=v.VK_COMMAND_BUFFER_LEVEL_PRIMARY, commandBufferCount=1))[0]
            v.vkBeginCommandBuffer(cmd, v.VkCommandBufferBeginInfo())
            barriers = [v.VkImageMemoryBarrier(oldLayout=v.VK_IMAGE_LAYOUT_UNDEFINED,
                newLayout=v.VK_IMAGE_LAYOUT_GENERAL, image=im, subresourceRange=subresource,
                srcQueueFamilyIndex=v.VK_QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex=v.VK_QUEUE_FAMILY_IGNORED,
                dstAccessMask=v.VK_ACCESS_SHADER_WRITE_BIT | v.VK_ACCESS_TRANSFER_WRITE_BIT)
                for im in (target, src_image, linear)]
            v.vkCmdPipelineBarrier(cmd, v.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                v.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, None, 0, None, len(barriers), barriers)
            def region(width, height):
                return v.VkBufferImageCopy(imageSubresource=v.VkImageSubresourceLayers(
                    aspectMask=v.VK_IMAGE_ASPECT_COLOR_BIT, layerCount=1),
                    imageExtent=v.VkExtent3D(width=width, height=height, depth=1))
            v.vkCmdCopyBufferToImage(cmd, source[0], src_image, v.VK_IMAGE_LAYOUT_GENERAL, 1, [region(sw, sh)])
            def barrier(src, dst, src_access, dst_access):
                v.vkCmdPipelineBarrier(cmd, src, dst, 0, 1, [v.VkMemoryBarrier(
                    srcAccessMask=src_access, dstAccessMask=dst_access)], 0, None, 0, None)
            barrier(v.VK_PIPELINE_STAGE_TRANSFER_BIT, v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    v.VK_ACCESS_TRANSFER_WRITE_BIT, v.VK_ACCESS_SHADER_READ_BIT)
            v.vkCmdBindPipeline(cmd, v.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
            v.vkCmdBindDescriptorSets(cmd, v.VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, [ds], 0, None)
            def dispatch(count, phases=capture_phases):
                push = struct.pack("<16I12f", background_alpha, *background, w, h,
                    int(background_alpha == 255), count, 0, 0, w, h, output_transfer, 0, 0, 0,
                    *capture_matrix[:3], phases or 0,
                    *capture_matrix[3:6], 0, *capture_matrix[6:], 0)
                v.vkCmdPushConstants(cmd, pl, v.VK_SHADER_STAGE_COMPUTE_BIT, 0, 112, v.ffi.from_buffer(push))
                v.vkCmdDispatch(cmd, (w + 7) // 8, (h + 7) // 8, 1)
            if capture_sequence:
                dispatch(0, 1)
                barrier(v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                        v.VK_ACCESS_SHADER_WRITE_BIT, v.VK_ACCESS_SHADER_WRITE_BIT)
                dispatch(1, 2)
            elif continuation:
                assert texture
                dispatch(0x40000001)
                barrier(v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                        v.VK_ACCESS_SHADER_WRITE_BIT, v.VK_ACCESS_SHADER_READ_BIT | v.VK_ACCESS_SHADER_WRITE_BIT)
                dispatch(0x80000000)
            else:
                dispatch(1)
            barrier(v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, v.VK_PIPELINE_STAGE_TRANSFER_BIT,
                    v.VK_ACCESS_SHADER_WRITE_BIT, v.VK_ACCESS_TRANSFER_READ_BIT)
            v.vkCmdCopyImageToBuffer(cmd, target, v.VK_IMAGE_LAYOUT_GENERAL, readback[0], 1, [region(w, h)])
            if copy_capture:
                # Same 8-bit buffer-to-image export used for DMA-BUF capture,
                # even when the scanout image is packed 10-bit HDR.
                ready = v.VkImageMemoryBarrier(oldLayout=v.VK_IMAGE_LAYOUT_UNDEFINED,
                    newLayout=v.VK_IMAGE_LAYOUT_GENERAL, image=copied, subresourceRange=subresource,
                    srcQueueFamilyIndex=v.VK_QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex=v.VK_QUEUE_FAMILY_IGNORED,
                    dstAccessMask=v.VK_ACCESS_TRANSFER_WRITE_BIT)
                v.vkCmdPipelineBarrier(cmd, v.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    v.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, None, 0, None, 1, [ready])
                v.vkCmdCopyBufferToImage(cmd, captures[0][0], copied, v.VK_IMAGE_LAYOUT_GENERAL, 1, [region(w, h)])
                barrier(v.VK_PIPELINE_STAGE_TRANSFER_BIT, v.VK_PIPELINE_STAGE_TRANSFER_BIT,
                        v.VK_ACCESS_TRANSFER_WRITE_BIT, v.VK_ACCESS_TRANSFER_READ_BIT)
                v.vkCmdCopyImageToBuffer(cmd, copied, v.VK_IMAGE_LAYOUT_GENERAL, copied_readback[0], 1, [region(w, h)])
            barrier(v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, v.VK_PIPELINE_STAGE_HOST_BIT,
                    v.VK_ACCESS_SHADER_WRITE_BIT, v.VK_ACCESS_HOST_READ_BIT)
            barrier(v.VK_PIPELINE_STAGE_TRANSFER_BIT, v.VK_PIPELINE_STAGE_HOST_BIT,
                    v.VK_ACCESS_TRANSFER_WRITE_BIT, v.VK_ACCESS_HOST_READ_BIT)
            v.vkEndCommandBuffer(cmd)
            v.vkQueueSubmit(self.queue, 1, [v.VkSubmitInfo(pCommandBuffers=[cmd])], v.VK_NULL_HANDLE)
            v.vkQueueWaitIdle(self.queue)
            mapped = v.vkMapMemory(d, readback[1], 0, readback[2], 0)
            result = bytes(mapped)
            v.vkUnmapMemory(d, readback[1])
            self.draw_count += 1
            if ten_bit:
                result = bytes(channel for (pixel,) in struct.iter_unpack("<I", result)
                               for channel in (round((pixel & 1023) * 255 / 1023),
                                               round(((pixel >> 10) & 1023) * 255 / 1023),
                                               round(((pixel >> 20) & 1023) * 255 / 1023),
                                               ((pixel >> 30) & 3) * 85))
            if capture_phases is not None:
                captured = []
                for buf in captures:
                    mapped = v.vkMapMemory(d, buf[1], 0, buf[2], 0)
                    captured.append(bytes(mapped))
                    v.vkUnmapMemory(d, buf[1])
                if copy_capture:
                    mapped = v.vkMapMemory(d, copied_readback[1], 0, copied_readback[2], 0)
                    assert bytes(mapped) == captured[0], "8-bit capture image export differs from SHM"
                    v.vkUnmapMemory(d, copied_readback[1])
                return result, *captured
            return result


def test(renderer, compare_shader_dir):
    # BGRA: opaque red next to transparent black. Correct premultiplied
    # filtering keeps saturated red, without dark/colored fringes.
    pixels = bytes([0, 0, 255, 255, 0, 0, 0, 0])
    start = renderer.draw_count
    for size in [(2, 1), (3, 2), (5, 3), (1, 1)]:
        for alpha in (255, 128):
            for xrgb in (False, True):
                for transform in (0, 2):
                    results = [renderer.render(pixels, (2, 1), size, mode, alpha=alpha,
                                               xrgb=xrgb, transform=transform)
                               for mode in ("buffer", "texture", "texture-buffer")]
                    assert results[0] == results[1] == results[2], (size, alpha, xrgb, transform)
    for mode in ("buffer", "texture", "texture-buffer"):
        identity = renderer.render(pixels, (2, 1), (2, 1), mode)
        assert identity == renderer.render(pixels, (2, 1), (2, 1), mode, filtering="nearest")
        midpoint = renderer.render(pixels, (2, 1), (3, 1), mode)[4:8]
        # Linear OVER: half red plus half background (RGB 80,100,120).
        assert all(abs(a - b) <= 1 for a, b in zip(midpoint, (86, 71, 194, 255))), midpoint
        # Fractional crop at 1:1 density still requires filtering.
        cropped = renderer.render(pixels, (2, 1), (1, 1), mode, crop=(0.5, 0, 1, 1))
        assert cropped == midpoint
        enlarged = renderer.render(pixels, (2, 1), (5, 1), mode)
        assert enlarged != renderer.render(pixels, (2, 1), (5, 1), mode, filtering="nearest")
        assert enlarged[:4] == identity[:4] and enlarged[-4:] == identity[-4:]
    # Client 2x buffers resized to 100%, 125%, 150%, and 200% outputs.
    pattern = bytes(channel for y in range(48) for x in range(48)
                    for channel in ((255, 255, 255, 255) if x <= y else (0, 0, 0, 0)))
    for size in (24, 30, 36, 48):
        results = [renderer.render(pattern, (48, 48), (size, size), mode)
                   for mode in ("buffer", "texture", "texture-buffer")]
        assert results[0] == results[1] == results[2], size

    for mode in ("buffer", "texture", "texture-buffer"):
        # Interpolate encoded values BEFORE transfer decoding. Opaque black /
        # white midpoint must be 128, not the linear-light midpoint of 188.
        black_white = bytes((0, 0, 0, 255, 255, 255, 255, 255))
        midpoint = renderer.render(black_white, (2, 1), (3, 1), mode, xrgb=True)[4:8]
        assert all(abs(v - 128) <= 1 for v in midpoint[:3]), midpoint

        # Independent 1-D cubic reference (polynomial interpolation of four
        # control values, rather than the shader's distance-based tap weights).
        values = (0, 0, 255, 255, 0, 0)
        ramp = bytes(c for p in values for c in (p, p, p, 255))
        expected = []
        for x in range(4):
            position = (x + 0.5) * 6 / 4 - 0.5
            base = math.floor(position)
            t = position - base
            a, b, c, d = (values[min(5, max(0, base + i))] for i in (-1, 0, 1, 2))
            value = (2*b + (-a+c)*t + (2*a-5*b+4*c-d)*t*t + (-a+3*b-3*c+d)*t*t*t) / 2
            expected.append(round(min(255, max(0, value))))
        cubic = renderer.render(ramp, (6, 1), (4, 1), mode, xrgb=True)
        assert all(abs(cubic[x * 4] - value) <= 1 for x, value in enumerate(expected)), (cubic, expected)

        # 3:1 reduction lands on texel centers: area integration must not be
        # bypassed as an opaque 1:1 fetch or a zero-fraction bilinear sample.
        stripes = bytes(c for _ in range(3) for x in range(9)
                        for c in ((255, 255, 255, 255) if x % 3 == 1 else (0, 0, 0, 255)))
        for transform in range(8):
            size = (1, 3) if transform % 2 else (3, 1)
            area = renderer.render(stripes, (9, 3), size, mode, transform=transform, xrgb=True)
            assert all(abs(area[x] - 85) <= 1 for x in range(12) if x % 4 != 3), area

        # Integer crop boundaries must exclude brightly colored neighboring
        # texels even when the cubic/area kernel extends beyond that crop.
        crop_pixels = bytes((0, 255, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255))
        for filtering in ("bilinear", "reconstruction", "area"):
            cropped = renderer.render(crop_pixels, (3, 1), (5, 1), mode,
                                      crop=(1, 0, 1, 1), filtering=filtering)
            assert cropped == bytes((0, 0, 255, 255)) * 5, cropped

        # Equivalent electrical-premultiplied, optical-premultiplied and
        # straight half-red texels. Straight transparent pixels may hold RGB.
        representations = ((0, 0, 128, 128, 0, 0, 0, 0),
                           (0, 0, 188, 128, 0, 0, 0, 0),
                           (0, 0, 255, 128, 255, 255, 0, 0))
        for alpha in (128, 255):
            for filtering in ("bilinear", "reconstruction", "area"):
                results = [renderer.render(bytes(data), (2, 1), (5, 1), mode,
                                           filtering=filtering, alpha_mode=representation, alpha=alpha,
                                           background=(0, 0, 0), background_alpha=0)
                           for representation, data in enumerate(representations)]
                for result in results[1:]:
                    assert all(abs(a - b) <= 2 for a, b in zip(results[0], result)), results
                for result in results:
                    for x in range(0, len(result), 4):
                        assert result[x:x+2] == bytes(2), result  # no hidden-color fringe
                        assert result[x+2] <= result[x+3] + 1, result

        # Opaque -> transparent cubic overshoot must not exceed global alpha,
        # including optical-alpha sources filtered in linear light.
        for alpha_mode in range(3):
            result = renderer.render(pixels, (2, 1), (7, 1), mode, alpha=128,
                                     alpha_mode=alpha_mode, filtering="reconstruction",
                                     background=(0, 0, 0), background_alpha=0)
            assert max(result[3::4]) <= 128, result
        for filtering in ("nearest", "bilinear", "reconstruction", "area"):
            normal = renderer.render(ramp, (6, 1), (4, 1), mode, filtering=filtering)
            ten_bit = renderer.render(ramp, (6, 1), (4, 1), mode, filtering=filtering, ten_bit=True)
            assert all(abs(a - b) <= 1 for a, b in zip(normal, ten_bit)), (normal, ten_bit)
        if compare_shader_dir:
            for size in ((2, 1), (3, 2), (1, 1)):
                previous = renderer.render(pixels, (2, 1), size, mode, filtering="nearest",
                                           shader_dir=compare_shader_dir)
                current = renderer.render(pixels, (2, 1), size, mode, filtering="nearest")
                assert previous == current, "ordinary nearest sampling changed"
    print(f"PASS: {renderer.draw_count - start} Vulkan cursor draws; sampling, alpha, crop and fallback checks")


def test_hdr_capture(renderer, capture_path):
    # D65 sRGB <-> BT.2020 matrices, independent of the Zig compiler's matrix
    # construction (whose round-trip is tested in vulkan_platform.zig).
    to_2020 = (0.627404, 0.329283, 0.043313,
               0.069097, 0.919540, 0.011362,
               0.016391, 0.088013, 0.895595)
    to_srgb = (1.660491, -0.587641, -0.072850,
               -0.124550, 1.132900, -0.008349,
               -0.018151, -0.100579, 1.118730)
    capture_matrix = tuple(x * 203 / 80 for x in to_srgb)
    # Neutral ramp, primaries, mixed colors and transparent edges.
    pixels = bytes(c for x in range(256) for c in (x, x, x, 255))
    pixels += bytes((0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255,
                     41, 173, 96, 255, 0, 0, 128, 128, 0, 0, 0, 0))
    size = (len(pixels) // 4, 1)
    start = renderer.draw_count
    for mode in ("buffer", "texture", "texture-buffer"):
        for ten_bit in (False, True):
            for transfer in (4, 5):  # PQ and HLG output
                options = dict(ten_bit=ten_bit, output_transfer=transfer,
                               color_matrix=to_2020, luminance_scale=80 / 203,
                               capture_matrix=capture_matrix, background=(0, 0, 0), background_alpha=0)
                scanout = renderer.render(pixels, size, size, mode, **options)
                for phases in (0, 1, 2, 3):
                    actual, before, after = renderer.render(pixels, size, size, mode,
                        capture_phases=phases, copy_capture=phases == 1, **options)
                    assert actual == scanout, "capture changed HDR scanout"
                    for bit, captured in ((1, before), (2, after)):
                        if phases & bit:
                            assert all(abs(a - b) <= 1 for a, b in zip(captured, pixels)), (mode, transfer, phases)
                        else:
                            assert captured == bytes([37]) * len(pixels), "inactive phase was overwritten"
                actual, before, after = renderer.render(pixels, size, size, mode,
                    capture_phases=3, capture_sequence=True, **options)
                assert actual == scanout
                assert before == bytes(len(pixels)), "later cursor pass overwrote cursor-free capture"
                assert all(abs(a - b) <= 1 for a, b in zip(after, pixels))
                if mode != "buffer":
                    _, before, after = renderer.render(pixels, size, size, mode,
                        capture_phases=3, continuation=True, **options)
                    assert before == after
                    assert all(abs(a - b) <= 1 for a, b in zip(before, pixels)), "linear continuation capture"
        # The opaque sRGB fast path must not skip the capture write.
        _, before, after = renderer.render(pixels, size, size, mode, xrgb=True, capture_phases=3)
        assert before == after
        assert all(abs(a - b) <= 1 for a, b in zip(before[:256*4], pixels[:256*4]))
        # Native PQ content can use the exact encoded passthrough on scanout.
        # Exporting it must decode for capture without changing that passthrough.
        levels = (0, 101, 124, 192, 255)
        pq_pixels = bytes(c for p in levels for c in (p, p, p, 255))
        pq_size = (len(levels), 1)
        for ten_bit in (False, True):
            options = dict(xrgb=True, ten_bit=ten_bit, source_transfer=4, output_transfer=4,
                           luminance_scale=10000 / 203, capture_matrix=capture_matrix)
            scanout = renderer.render(pq_pixels, pq_size, pq_size, mode, **options)
            actual, captured, _ = renderer.render(pq_pixels, pq_size, pq_size, mode,
                                                 capture_phases=1, **options)
            assert actual == scanout, "capture changed native HDR passthrough"
            for i, level in enumerate(levels):
                p = (level / 255) ** (32 / 2523)
                linear = (max(p - 3424 / 4096, 0) / (2413 / 128 - 2392 / 128 * p)) ** (16384 / 2610) * 10000 / 80
                srgb = 12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055
                expected = round(min(1, max(0, srgb)) * 255)
                assert all(abs(v - expected) <= 1 for v in captured[i * 4:i * 4 + 3]), (level, captured, expected)
    print(f"PASS: {renderer.draw_count - start} Vulkan capture draws; PQ/HLG brightness, gamut, alpha, phases, continuation, image export, unchanged scanout")

    if capture_path:
        chart = Image.new("RGB", (256, 160))
        draw = ImageDraw.Draw(chart)
        for x in range(256):
            draw.line((x, 0, x, 79), fill=(x, x, x))
        for i, rgb in enumerate(((255, 0, 0), (0, 255, 0), (0, 0, 255), (96, 173, 41))):
            draw.rectangle((i * 64, 80, (i + 1) * 64 - 1, 159), fill=rgb)
        data = chart.convert("RGBA").tobytes("raw", "BGRA")
        old, corrected, _ = renderer.render(data, chart.size, chart.size, "texture", ten_bit=True,
            output_transfer=4, color_matrix=to_2020, luminance_scale=80 / 203,
            capture_matrix=capture_matrix, capture_phases=1)
        sheet = Image.new("RGB", (800, 200), "#202020")
        labels = ("Source (sRGB)", "Before: HDR bytes as sRGB", "After: sRGB capture")
        for i, (label, image) in enumerate(zip(labels, (chart,
                Image.frombytes("RGBA", chart.size, old, "raw", "BGRA"),
                Image.frombytes("RGBA", chart.size, corrected, "raw", "BGRA")))):
            ImageDraw.Draw(sheet).text((8 + i * 264, 10), label, fill="white")
            sheet.paste(image, (8 + i * 264, 32))
        capture_path.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(capture_path)
        print("HDR capture comparison:", capture_path)


def xcursor(name, requested):
    data = (Path("/usr/share/icons/Adwaita/cursors") / name).read_bytes()
    header, _, count = struct.unpack_from("<3I", data, 4)
    toc = [struct.unpack_from("<3I", data, header + i * 12) for i in range(count)]
    _, nominal, offset = min((t for t in toc if t[0] == 0xfffd0002),
                             key=lambda t: (t[1] < requested, t[1] if t[1] >= requested else -t[1]))
    chunk, _, _, _, w, h, _, _, _ = struct.unpack_from("<9I", data, offset)
    return data[offset + chunk:offset + chunk + w * h * 4], (w, h), nominal


def capture(renderer, path, compare_shader_dir):
    scales = (0.5, 1, 1.25, 1.5, 2)
    variants = [("encoded bilinear", "bilinear", None), ("adaptive", None, None)]
    if compare_shader_dir:
        variants.insert(0, ("previous linear-light", "bilinear", compare_shader_dir))
    sheet = Image.new("RGB", (1000, 66 + 4 * len(variants) * 160), "#18212b")
    draw = ImageDraw.Draw(sheet)
    draw.text((16, 10), "Identical cursor sources - Vulkan shader readback (3x pixel zoom)", fill="white")
    for col, scale in enumerate(scales):
        draw.text((220 + col * 150, 36), f"{scale * 100:g}%", fill="white")
    for row, (shape, client, variant) in enumerate((s, c, v) for s in ("default", "text")
                                                 for c in (False, True) for v in variants):
        title, filtering, shader_dir = variant
        label = f"{shape} / {'client 2x' if client else 'theme'}\n{title}"
        y = 66 + row * 160
        draw.text((16, y + 12), label, fill="white")
        for col, scale in enumerate(scales):
            requested = 48 if client else int(24 * scale)
            pixels, (w, h), nominal = xcursor(shape, requested)
            logical = (round(w * 24 / nominal), round(h * 24 / nominal))
            size = tuple(round(n * scale) for n in logical)
            result = renderer.render(pixels, (w, h), size, "texture", filtering=filtering,
                                     shader_dir=shader_dir)
            if size == (w, h) and compare_shader_dir and shader_dir is None:
                previous = renderer.render(pixels, (w, h), size, "texture", filtering="bilinear",
                                           shader_dir=compare_shader_dir)
                assert previous == result, "aligned 1:1 cursor changed"
            im = Image.frombytes("RGBA", size, result, "raw", "BGRA").convert("RGB")
            # Zoom is nearest so the sheet exposes, rather than smooths, GPU pixels.
            sheet.paste(im.resize((size[0] * 3, size[1] * 3), Image.Resampling.NEAREST), (210 + col * 150, y))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)
    print("Capture:", path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--capture-hdr", type=Path)
    parser.add_argument("--compare-shader-dir", type=Path)
    args = parser.parse_args()
    renderer = Renderer()
    try:
        test(renderer, args.compare_shader_dir)
        test_hdr_capture(renderer, args.capture_hdr)
        if args.capture:
            capture(renderer, args.capture, args.compare_shader_dir)
    finally:
        renderer.close()
