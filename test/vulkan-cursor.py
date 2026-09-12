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
import statistics
import struct

import vulkan as v
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def scene_sample(source_size, destination, affine, filtering="nearest", clip=None, crop=None):
    """Pack a recorded SDR sample without recomputing its affine mapping.

    Identity primaries, premultiplied ARGB, global alpha 255, no LUT or direct
    color shortcut. Pixel opacity remains a property of the synthetic texture.
    """
    sw, sh = source_size
    crop = crop or (0, 0, sw * 65536, sh * 65536)
    flags = {"nearest": 0, "reconstruction": 1, "bilinear": 2, "area": 3}[filtering] << 28
    return struct.pack("<4I12i4I8i12f", 0, sw, sh, sw * 4,
                       *crop, *destination, *(clip or destination), 0, flags, 255, 0,
                       *affine, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0)


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
            pEnabledFeatures=v.VkPhysicalDeviceFeatures(shaderStorageImageWriteWithoutFormat=True,
                                                       shaderSampledImageArrayDynamicIndexing=True)), None)
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
               capture_phases=None, continuation=False, capture_sequence=False, copy_capture=False,
               timings=None, scene=None, damage=None, timing_repeats=1,
               source_format=0, source_stride=None, raw_output=False, output_reference=80,
               video_planes=None, representation=0, capture_transfer=0, capture_shoulder=False, rgb_output=False,
               capture16=False, blur=False):
        d = self.device
        sw, sh = source_size
        w, h = size
        bpp = (1 if source_format in (13, 14, 18, 19) else 2) if source_format >= 13 else 16 if source_format == 12 else 8 if source_format in (2, 9, 10, 11) else 4
        source_stride = source_stride or sw * bpp
        source_vk_format = {0: v.VK_FORMAT_B8G8R8A8_UNORM,
                            2: v.VK_FORMAT_R16G16B16A16_UNORM,
                            3: v.VK_FORMAT_A2R10G10B10_UNORM_PACK32,
                            4: v.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
                            5: v.VK_FORMAT_R8G8B8A8_UNORM, 6: v.VK_FORMAT_R8G8B8A8_UNORM,
                            7: v.VK_FORMAT_A2R10G10B10_UNORM_PACK32,
                            8: v.VK_FORMAT_A2B10G10R10_UNORM_PACK32,
                            9: v.VK_FORMAT_R16G16B16A16_UNORM,
                            10: v.VK_FORMAT_R16G16B16A16_SFLOAT,
                            11: v.VK_FORMAT_R16G16B16A16_SFLOAT,
                            12: v.VK_FORMAT_R32G32B32A32_SFLOAT}.get(source_format, v.VK_FORMAT_R8_UNORM)
        texture = mode != "buffer"
        damage = damage or [(0, 0, w, h)]
        assert timing_repeats >= 1 and (timings is not None or timing_repeats == 1)
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
                if not usage & (v.VK_IMAGE_USAGE_SAMPLED_BIT | v.VK_IMAGE_USAGE_STORAGE_BIT):
                    return im, None  # Transfer-only capture targets do not need a view.
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
            sample = struct.pack("<4I12i4I8i12f", 0, sw, sh, source_stride,
                int(sx * 65536), int(sy * 65536), int(cw * 65536), int(ch * 65536),
                0, 0, w, h, 0, 0, w, h, source_format or int(xrgb), flags, alpha, source_transfer,
                xx, xy, x0, yx, yy, y0, alpha_mode, 0,
                *color_matrix[:3], luminance_scale, *color_matrix[3:6],
                struct.unpack("<f", struct.pack("<I", representation))[0], *color_matrix[6:], 0)
            # Explicit scenes retain the recorded affine/crop instead of
            # deriving a new mapping from rounded destination dimensions.
            layers = scene if scene is not None else [(sample, pixels, source_size)]
            assert 1 <= len(layers) <= 32
            packed_samples, source_pixels, offsets = [], [], []
            source_offset = 0
            for packed, data, dimensions in layers:
                assert len(packed) == 160 and len(data) == struct.unpack_from("<I", packed, 12)[0] * dimensions[1]
                packed = bytearray(packed)
                struct.pack_into("<I", packed, 0, source_offset)
                if mode == "texture-buffer":
                    struct.pack_into("<I", packed, 68, struct.unpack_from("<I", packed, 68)[0] | 0x40000000)
                packed_samples.append(packed)
                source_pixels.append(data)
                offsets.append(source_offset)
                source_offset += len(data)
            storage = v.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
            samples = buffer(b"".join(packed_samples), storage)
            source = buffer(b"".join(source_pixels), storage | v.VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
            lut = buffer(bytes(16), storage)
            readback = buffer(bytes(w * h * 4), v.VK_BUFFER_USAGE_TRANSFER_DST_BIT)
            captures = [buffer(bytes([37]) * (w * h * (12 if capture16 else 4)), storage | v.VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
                        for _ in range(2)]
            target, target_view = image(w, h, v.VK_FORMAT_A2B10G10R10_UNORM_PACK32 if ten_bit else v.VK_FORMAT_R8G8B8A8_UNORM,
                v.VK_IMAGE_USAGE_STORAGE_BIT | v.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
            source_images = [image(*dimensions, source_vk_format,
                v.VK_IMAGE_USAGE_SAMPLED_BIT | v.VK_IMAGE_USAGE_TRANSFER_DST_BIT)
                for _, _, dimensions in layers]
            if video_planes:
                assert mode == "texture" and scene is None
                source_images = [image(*dimensions, fmt, v.VK_IMAGE_USAGE_SAMPLED_BIT | v.VK_IMAGE_USAGE_TRANSFER_DST_BIT)
                                 for data, dimensions, fmt, stride, texel_bytes in video_planes]
                plane_uploads = [buffer(data, v.VK_BUFFER_USAGE_TRANSFER_SRC_BIT) for data, *_ in video_planes]
            linear, linear_view = image(w, h, v.VK_FORMAT_R32G32B32A32_SFLOAT,
                v.VK_IMAGE_USAGE_STORAGE_BIT | v.VK_IMAGE_USAGE_SAMPLED_BIT)
            if blur:
                assert texture and continuation
                blurred, blurred_view = image(w, h, v.VK_FORMAT_R32G32B32A32_SFLOAT,
                    v.VK_IMAGE_USAGE_STORAGE_BIT | v.VK_IMAGE_USAGE_SAMPLED_BIT)
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
                types.update({3: (v.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 96 if video_planes else 32),
                              5: (v.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1),
                              6: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)})
            else:
                types[2] = (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)
            if blur:
                types.update({7: (v.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1),
                              8: (v.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1),
                              9: (v.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1)})
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
                    views = ([target_view] if b == 0 else [linear_view] if b in (5, 8) else [blurred_view] if b in (7, 9) else
                             [view for _, view in source_images] + [source_images[0][1]] * (n - len(layers)))
                    if b == 3 and video_planes:
                        views = [source_images[0][1]] * 96
                        for plane, (_, view) in enumerate(source_images):
                            views[32 * plane] = view
                    args = dict(pImageInfo=[v.VkDescriptorImageInfo(sampler=sampler, imageView=view,
                                                                  imageLayout=v.VK_IMAGE_LAYOUT_GENERAL) for view in views])
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
            descriptor_data = struct.pack("<I", 96 if video_planes else 32)
            stage = v.VkPipelineShaderStageCreateInfo(stage=v.VK_SHADER_STAGE_COMPUTE_BIT,
                module=module, pName="main", pSpecializationInfo=v.VkSpecializationInfo(
                    pMapEntries=[v.VkSpecializationMapEntry(constantID=0, offset=0, size=4)],
                    dataSize=4, pData=v.ffi.from_buffer(descriptor_data)) if texture else None)
            pipeline = v.vkCreateComputePipelines(d, v.VK_NULL_HANDLE, 1,
                [v.VkComputePipelineCreateInfo(stage=stage, layout=pl)], None)[0]
            cleanup.callback(v.vkDestroyPipeline, d, pipeline, None)
            if blur:
                code = (ROOT / "src/render/vulkan_backdrop_blur.spv").read_bytes()
                module = own(v.vkCreateShaderModule, v.vkDestroyShaderModule,
                    v.VkShaderModuleCreateInfo(codeSize=len(code), pCode=code))
                blur_stage = v.VkPipelineShaderStageCreateInfo(
                    stage=v.VK_SHADER_STAGE_COMPUTE_BIT, module=module, pName="main")
                blur_pipeline = v.vkCreateComputePipelines(d, v.VK_NULL_HANDLE, 1,
                    [v.VkComputePipelineCreateInfo(stage=blur_stage, layout=pl)], None)[0]
                cleanup.callback(v.vkDestroyPipeline, d, blur_pipeline, None)
            cp = own(v.vkCreateCommandPool, v.vkDestroyCommandPool,
                     v.VkCommandPoolCreateInfo(queueFamilyIndex=self.family))
            cmd = v.vkAllocateCommandBuffers(d, v.VkCommandBufferAllocateInfo(commandPool=cp,
                level=v.VK_COMMAND_BUFFER_LEVEL_PRIMARY, commandBufferCount=1))[0]
            v.vkBeginCommandBuffer(cmd, v.VkCommandBufferBeginInfo())
            barriers = [v.VkImageMemoryBarrier(oldLayout=v.VK_IMAGE_LAYOUT_UNDEFINED,
                newLayout=v.VK_IMAGE_LAYOUT_GENERAL, image=im, subresourceRange=subresource,
                srcQueueFamilyIndex=v.VK_QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex=v.VK_QUEUE_FAMILY_IGNORED,
                dstAccessMask=v.VK_ACCESS_SHADER_WRITE_BIT | v.VK_ACCESS_TRANSFER_WRITE_BIT)
                for im in [target, linear] + ([blurred] if blur else []) + [im for im, _ in source_images]]
            v.vkCmdPipelineBarrier(cmd, v.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                v.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, None, 0, None, len(barriers), barriers)
            def region(width, height, offset=0):
                return v.VkBufferImageCopy(bufferOffset=offset, imageSubresource=v.VkImageSubresourceLayers(
                    aspectMask=v.VK_IMAGE_ASPECT_COLOR_BIT, layerCount=1),
                    imageExtent=v.VkExtent3D(width=width, height=height, depth=1))
            if video_planes:
                for (im, _), (data, dimensions, fmt, stride, texel_bytes), upload in zip(source_images, video_planes, plane_uploads):
                    copy = region(*dimensions)
                    copy.bufferRowLength = stride // texel_bytes
                    v.vkCmdCopyBufferToImage(cmd, upload[0], im, v.VK_IMAGE_LAYOUT_GENERAL, 1, [copy])
            else:
                for (im, _), (packed, _, dimensions), offset in zip(source_images, layers, offsets):
                    copy = region(*dimensions, offset)
                    copy.bufferRowLength = struct.unpack_from("<I", packed, 12)[0] // bpp
                    v.vkCmdCopyBufferToImage(cmd, source[0], im, v.VK_IMAGE_LAYOUT_GENERAL, 1, [copy])
            def barrier(src, dst, src_access, dst_access):
                v.vkCmdPipelineBarrier(cmd, src, dst, 0, 1, [v.VkMemoryBarrier(
                    srcAccessMask=src_access, dstAccessMask=dst_access)], 0, None, 0, None)
            barrier(v.VK_PIPELINE_STAGE_TRANSFER_BIT, v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    v.VK_ACCESS_TRANSFER_WRITE_BIT, v.VK_ACCESS_SHADER_READ_BIT)
            if timings is not None:
                # Upload once, then replay composition with the same resources.
                # No allocation, upload or pipeline compilation in timed spans.
                v.vkEndCommandBuffer(cmd)
                v.vkQueueSubmit(self.queue, 1, [v.VkSubmitInfo(pCommandBuffers=[cmd])], v.VK_NULL_HANDLE)
                v.vkQueueWaitIdle(self.queue)
                v.vkResetCommandPool(d, cp, 0)
                v.vkBeginCommandBuffer(cmd, v.VkCommandBufferBeginInfo())
                # Include prior readback/capture writes when replaying, not
                # just the target's shader writes. This is outside the timer.
                barrier(v.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, v.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                        v.VK_ACCESS_MEMORY_WRITE_BIT, v.VK_ACCESS_MEMORY_READ_BIT | v.VK_ACCESS_MEMORY_WRITE_BIT)
                queries = own(v.vkCreateQueryPool, v.vkDestroyQueryPool, v.VkQueryPoolCreateInfo(
                    queryType=v.VK_QUERY_TYPE_TIMESTAMP, queryCount=2))
                v.vkCmdResetQueryPool(cmd, queries, 0, 2)
                v.vkCmdWriteTimestamp(cmd, v.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, queries, 0)
            v.vkCmdBindPipeline(cmd, v.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
            v.vkCmdBindDescriptorSets(cmd, v.VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, [ds], 0, None)
            def dispatch(count, phases=capture_phases):
                for rect in damage:
                    push = struct.pack("<16I12f", background_alpha, *background, w, h,
                        int(background_alpha == 255) | (int(rgb_output) << 31), count, *rect, output_transfer,
                        struct.unpack("<I", struct.pack("<f", output_reference))[0], 0, 0,
                        *capture_matrix[:3], phases or 0,
                        *capture_matrix[3:6], capture_transfer, *capture_matrix[6:], int(capture_shoulder) | (int(capture16) << 1))
                    v.vkCmdPushConstants(cmd, pl, v.VK_SHADER_STAGE_COMPUTE_BIT, 0, 112, v.ffi.from_buffer(push))
                    v.vkCmdDispatch(cmd, (rect[2] + 7) // 8, (rect[3] + 7) // 8, 1)
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
                if blur:
                    v.vkCmdBindPipeline(cmd, v.VK_PIPELINE_BIND_POINT_COMPUTE, blur_pipeline)
                    for vertical in (0, 1):
                        push = struct.pack("<16I", 0, 0, 0, 0, w, h, 0, 0, 0, 0, w, h,
                            vertical, 0x3f800000, 0, 0)
                        v.vkCmdPushConstants(cmd, pl, v.VK_SHADER_STAGE_COMPUTE_BIT, 0, 64, v.ffi.from_buffer(push))
                        v.vkCmdDispatch(cmd, (w + 7) // 8, (h + 7) // 8, 1)
                        barrier(v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                            v.VK_ACCESS_SHADER_WRITE_BIT, v.VK_ACCESS_SHADER_READ_BIT | v.VK_ACCESS_SHADER_WRITE_BIT)
                    v.vkCmdBindPipeline(cmd, v.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
                dispatch(0x80000000)
            else:
                dispatch(len(layers))
            if timings is not None:
                v.vkCmdWriteTimestamp(cmd, v.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, queries, 1)
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
            for _ in range(timing_repeats):
                v.vkQueueSubmit(self.queue, 1, [v.VkSubmitInfo(pCommandBuffers=[cmd])], v.VK_NULL_HANDLE)
                v.vkQueueWaitIdle(self.queue)
                if timings is not None:
                    ticks = v.ffi.new("uint64_t[2]")
                    v.vkGetQueryPoolResults(d, queries, 0, 2, 16, ticks, 8, v.VK_QUERY_RESULT_64_BIT)
                    bits = v.vkGetPhysicalDeviceQueueFamilyProperties(self.gpu)[self.family].timestampValidBits
                    assert bits > 0, "selected queue does not support GPU timestamps"
                    period = v.vkGetPhysicalDeviceProperties(self.gpu).limits.timestampPeriod
                    timings.append(((ticks[1] - ticks[0]) % (1 << bits)) * period / 1e6)
            mapped = v.vkMapMemory(d, readback[1], 0, readback[2], 0)
            result = bytes(mapped)
            v.vkUnmapMemory(d, readback[1])
            self.draw_count += 1
            if ten_bit and not raw_output:
                result = bytes(channel for (pixel,) in struct.iter_unpack("<I", result)
                               for channel in (round((pixel & 1023) * 255 / 1023),
                                               round(((pixel >> 10) & 1023) * 255 / 1023),
                                               round(((pixel >> 20) & 1023) * 255 / 1023),
                                               ((pixel >> 30) & 3) * 85))
            if capture_phases is not None:
                captured = []
                for buf in captures:
                    mapped = v.vkMapMemory(d, buf[1], 0, buf[2], 0)
                    captured.append(bytes(mapped)[w * h * 4:] if capture16 else bytes(mapped)[:w * h * 4])
                    v.vkUnmapMemory(d, buf[1])
                if copy_capture:
                    mapped = v.vkMapMemory(d, copied_readback[1], 0, copied_readback[2], 0)
                    assert bytes(mapped) == captured[0], "8-bit capture image export differs from SHM"
                    v.vkUnmapMemory(d, copied_readback[1])
                return result, *captured
            return result


def test_shm(renderer, capture_path):
    """Independent UNORM/OVER/sRGB oracle, including values below 8-bit linear."""
    def srgb(linear):
        return 12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055

    background = (29, 83, 151)
    background_linear = [c / 255 / 12.92 if c / 255 <= 0.04045
                         else ((c / 255 + 0.055) / 1.055) ** 2.4 for c in background]
    preview = Image.new("RGB", (720, 290), "#202020")
    draw = ImageDraw.Draw(preview)
    draw.text((16, 10), "SHM integer formats: Vulkan sRGB captures (nearest pixel enlargement)", fill="white")
    start_count = renderer.draw_count
    for column, (fmt, label) in enumerate(((2, "ABGR16161616"), (3, "ARGB2101010"), (4, "ABGR2101010"))):
        if fmt == 2:
            maximum, alpha_maximum, bpp = 65535, 65535, 8
            values = [(64, 129, 257, 65535), (15000, 7500, 1250, 21845),
                      (400, 900, 1200, 32769), (60000, 40000, 30000, 65535)]
            pack = lambda r, g, b, a: struct.pack("<4H", r, g, b, a)
        else:
            maximum, alpha_maximum, bpp = 1023, 3, 4
            values = [(1, 2, 3, 3), (230, 113, 19, 1), (7, 14, 25, 2), (941, 627, 470, 3)]
            pack = lambda r, g, b, a: struct.pack("<I", (a << 30) | (g << 10) |
                                                 ((r << 20) | b if fmt == 3 else (b << 20) | r))
        # Poison padding catches both incorrect row stride and 4/8-byte addressing.
        pixels = b"".join(pack(*values[y * 2]) + pack(*values[y * 2 + 1]) + b"\xee" * bpp for y in range(2))
        for mode in ("buffer", "texture", "texture-buffer"):
            for ten_bit in (False, True):
                for transparent in (False, True):
                    result, before, after = renderer.render(
                        pixels, (2, 2), (2, 2), mode, source_format=fmt, source_stride=3 * bpp,
                        source_transfer=1, alpha_mode=1, background=background,
                        background_alpha=0 if transparent else 255, ten_bit=ten_bit,
                        raw_output=True, capture_phases=3, copy_capture=True)
                    expected_capture, expected_output = [], []
                    for r, g, b, a in values:
                        source_alpha = a / alpha_maximum
                        alpha = source_alpha if transparent else 1
                        rgb = [c / maximum + (0 if transparent else bg * (1 - source_alpha))
                               for c, bg in zip((r, g, b), background_linear)]
                        encoded = [srgb(c / alpha) * alpha for c in rgb]
                        expected_capture.extend([round(c * 255) for c in encoded[::-1]] + [round(alpha * 255)])
                        expected_output.extend([round(c * (1023 if ten_bit else 255)) for c in encoded[::-1]] +
                                               [round(alpha * (3 if ten_bit else 255))])
                    actual_output = ([c for (p,) in struct.iter_unpack("<I", result)
                                      for c in (p & 1023, (p >> 10) & 1023, (p >> 20) & 1023, p >> 30)]
                                     if ten_bit else list(result))
                    # One output-code tolerance permits implementation rounding, not 8-bit ingestion.
                    assert max(abs(a - b) for a, b in zip(actual_output, expected_output)) <= 1, (label, mode, actual_output, expected_output)
                    assert max(abs(a - b) for a, b in zip(before, expected_capture)) <= 1, (label, mode, before, expected_capture)
                    assert before == after
                    if mode == "texture" and not ten_bit and not transparent:
                        image = Image.frombytes("RGBA", (2, 2), before, "raw", "BGRA")
                        preview.paste(image.convert("RGB").resize((208, 208), Image.Resampling.NEAREST), (16 + column * 240, 56))
        draw.text((16 + column * 240, 36), label, fill="white")
    for mode in ("buffer", "texture", "texture-buffer"):
        # Alpha 129/65535 attenuates linear white to code 1021. Premature UNORM8
        # alpha rounding would give code 1019; zero alpha must leave white intact.
        for alpha, expected in ((0, 1023), (129, 1021)):
            result = renderer.render(struct.pack("<4H", 0, 0, 0, alpha), (1, 1), (1, 1), mode,
                                     source_format=2, source_transfer=1, output_transfer=1,
                                     background=(255, 255, 255), ten_bit=True, raw_output=True)
            assert struct.unpack("<I", result)[0] == (3 << 30) | (expected << 20) | (expected << 10) | expected
    if capture_path:
        preview.save(capture_path)
    print(f"SHM precision: {renderer.draw_count - start_count} draws passed (3 layouts, 3 paths, 8/10-bit output, alpha and capture)")


def test_modern_rgb(renderer, capture_path):
    start = renderer.draw_count
    preview = Image.new("RGB", (1024, 170), "#202020")
    draw = ImageDraw.Draw(preview)
    # The unused alpha bits deliberately contain zero. Each expected RGB is
    # independent of the shader and differs under a red/blue swap.
    cases = [(5, struct.pack("<4B", 12, 63, 115, 128), (12 / 255, 63 / 255, 115 / 255), 128 / 255),
             (6, struct.pack("<4B", 12, 63, 115, 0), (12 / 255, 63 / 255, 115 / 255), 1),
             (7, struct.pack("<I", (23 << 20) | (127 << 10) | 503), (23 / 1023, 127 / 1023, 503 / 1023), 1),
             (8, struct.pack("<I", (503 << 20) | (127 << 10) | 23), (23 / 1023, 127 / 1023, 503 / 1023), 1),
             (9, struct.pack("<4H", 129, 8001, 31003, 0), (129 / 65535, 8001 / 65535, 31003 / 65535), 1)]
    # A transform brings extended-range RGB into the output gamut. Clamping
    # either the negative green or >1 red before the transform changes output.
    matrix = (0.25, 0.25, 0, 0, -0.5, 0, 0, 0, 0.5)
    for fmt, alpha in ((10, 0.5), (11, 1), (12, 0.5)):
        bits = struct.pack("<4f" if fmt == 12 else "<4e", 2, -0.25, 0.125, 0 if fmt == 11 else alpha)
        cases.append((fmt, bits, (0.4375, 0.125, 0.0625), alpha))
    for column, (fmt, pixel, rgb, alpha) in enumerate(cases):
        for mode in ("buffer", "texture", "texture-buffer"):
            for filtering in ("nearest", "bilinear", "reconstruction", "area"):
                # Padding must survive the source upload without becoming a texel.
                data = (pixel * 2 + b"\xee" * len(pixel)) * 2
                result, before, after = renderer.render(data, (2, 2), (2, 2), mode,
                    source_format=fmt, source_stride=3 * len(pixel), source_transfer=1,
                    alpha_mode=1, output_transfer=1, background=(17, 41, 73), filtering=filtering,
                    color_matrix=matrix if fmt >= 10 else (1, 0, 0, 0, 1, 0, 0, 0, 1),
                    capture_phases=3, copy_capture=True, raw_output=True)
                expected = [round(x * 255 + bg * (1 - alpha)) for x, bg in zip(rgb[::-1], (73, 41, 17))] + [255]
                assert max(abs(a - b) for a, b in zip(result, expected * 4)) <= 1, (fmt, mode, filtering, list(result), expected)
                assert before == after
                if mode == "texture" and filtering == "nearest":
                    image = Image.frombytes("RGBA", (2, 2), before, "raw", "BGRA")
                    preview.paste(image.convert("RGB").resize((112, 112)), (column * 128 + 8, 40))
                    label = {5: "ABGR8", 6: "XBGR8", 7: "XRGB10", 8: "XBGR10", 9: "XBGR16", 10: "ABGR16F", 11: "XBGR16F", 12: "single pixel"}[fmt]
                    draw.text((column * 128 + 8, 16), label, fill="white")
    if capture_path:
        preview.save(capture_path.with_stem(capture_path.stem + "-extended"))
    print(f"Modern RGB: {renderer.draw_count - start} draws passed (X bits, float range, all filters and capture)")


def test_desktop_color(renderer, capture_path):
    start = renderer.draw_count
    sheet = Image.new("RGB", (640, 200), "#202020")
    draw = ImageDraw.Draw(sheet)
    for mode in ("buffer", "texture", "texture-buffer"):
        for transfer in (0, 2):
            pixels = bytes(c for x in range(256) for c in (x, x, x, 255))
            result, capture, _ = renderer.render(pixels, (256, 1), (256, 1), mode,
                source_transfer=transfer, output_transfer=2, capture_phases=1)
            expected = []
            for x in range(256):
                linear = (x / 255) ** 2.2 if transfer == 2 else x / 255 / 12.92 if x <= 10 else ((x / 255 + 0.055) / 1.055) ** 2.4
                srgb = 12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055
                expected.extend([round(srgb * 255)] * 3 + [255])
                assert abs(result[4 * x] - round(linear ** (1 / 2.2) * 255)) <= 1
            assert max(abs(a - b) for a, b in zip(capture, expected)) <= 1
            if mode == "texture":
                y = 20 if transfer == 2 else 110
                draw.text((12, y), "gamma22 desktop: sRGB capture" if transfer == 2 else "explicit compound_power_2_4: sRGB capture", fill="white")
                sheet.paste(Image.frombytes("RGBA", (256, 1), capture, "raw", "BGRA").resize((616, 48)), (12, y + 20))
        # The same absolute 203-nit white must receive the same PQ code with
        # either an 80-nit or 203-nit working reference white.
        expected_pq = ((3424 / 4096 + (2413 / 128) * (203 / 10000) ** (2610 / 16384)) /
                       (1 + (2392 / 128) * (203 / 10000) ** (2610 / 16384))) ** (2523 / 32)
        for reference in (80, 203):
            result = renderer.render(struct.pack("<4e", 1, 1, 1, 1), (1, 1), (1, 1), mode,
                source_format=10, source_transfer=1, output_transfer=4, output_reference=reference,
                luminance_scale=203 / reference, ten_bit=True, raw_output=True)
            actual = struct.unpack("<I", result)[0] & 1023
            assert abs(actual - round(expected_pq * 1023)) <= 1, (mode, reference, actual)
    if capture_path:
        sheet.save(capture_path.with_stem(capture_path.stem + "-gamma22"))
    print(f"Desktop color: {renderer.draw_count - start} draws passed (gamma22, explicit sRGB, reference-independent PQ)")


def test_capture_roundtrip(renderer, capture_path):
    start = renderer.draw_count
    # Asymmetric low-light desktop RGB. Capture protocols carry no color tag.
    pixels = bytes(c for x in range(65) for c in (x, x * 2, x * 3, 255))
    def srgb_encode(linear):
        return 12.92 * linear if linear <= .0031308 else 1.055 * linear ** (1 / 2.4) - .055
    def srgb_decode(electrical):
        return electrical / 12.92 if electrical <= .04045 else ((electrical + .055) / 1.055) ** 2.4
    managed_expected = bytes(255 if i % 4 == 3 else round(255 * srgb_encode((n / 255) ** 2.2)) for i, n in enumerate(pixels))
    for mode in ("buffer", "texture", "texture-buffer"):
        original, raw, _ = renderer.render(pixels, (65, 1), (65, 1), mode,
            source_transfer=2, output_transfer=2, capture_phases=1, capture_transfer=2)
        assert raw == pixels and original == pixels, mode
        redisplay = renderer.render(raw, (65, 1), (65, 1), mode, source_transfer=2, output_transfer=2)
        assert redisplay == original, mode
        _, managed, _ = renderer.render(pixels, (65, 1), (65, 1), mode,
            source_transfer=2, output_transfer=2, capture_phases=1, capture_transfer=0)
        assert max(abs(a - b) for a, b in zip(managed, managed_expected)) <= 1
        tagged = renderer.render(managed, (65, 1), (65, 1), mode, source_transfer=0, output_transfer=2)
        want = bytes(255 if i % 4 == 3 else round(255 * srgb_decode(n / 255) ** (1 / 2.2)) for i, n in enumerate(managed))
        assert max(abs(a - b) for a, b in zip(tagged, want)) <= 1
        wrong = renderer.render(managed, (65, 1), (65, 1), mode, source_transfer=2, output_transfer=2)
        assert abs(tagged[64] - 16) <= 1 and wrong[64] == 7, (mode, tagged[64], wrong[64])
    if capture_path:
        sheet = Image.new("RGB", (720, 400), "#202020")
        draw = ImageDraw.Draw(sheet)
        for row, (label, data) in enumerate((("Desktop original", original), ("Raw gamma22 capture -> untagged desktop (exact)", redisplay),
                ("Managed sRGB capture -> explicitly sRGB surface", tagged), ("Incorrect: sRGB bytes -> untagged gamma22 (darker)", wrong))):
            draw.text((12, 10 + row * 100), label, fill="white")
            # Encode the review image itself as sRGB for browser viewing.
            preview = bytes(255 if i % 4 == 3 else round(255 * srgb_encode((n / 255) ** 2.2)) for i, n in enumerate(data))
            sheet.paste(Image.frombytes("RGBA", (65, 1), preview, "raw", "BGRA").resize((696, 60)), (12, 30 + row * 100))
        sheet.save(capture_path)
    print(f"Capture round trip: {renderer.draw_count - start} draws passed (exact raw low-light identity, explicit sRGB, rejected interpretation)")


def test_capture16(renderer):
    start = renderer.draw_count
    values = ((1, 7, 31, 65535), (31, 67, 127, 129), (129, 503, 9001, 32769), (12345, 23456, 34567, 65535))
    pixels = b"".join(struct.pack("<8H", *values[2 * y], *values[2 * y + 1]) + bytes([0xcc]) * 8 for y in range(2))
    expected = [component for r, g, b, a in values for component in
                (*(round((c / 65535) ** (1 / 2.2) * a) for c in (r, g, b)), a)]
    for mode, continuation in (("buffer", False), ("texture", False), ("texture-buffer", False), ("texture", True), ("texture-buffer", True)):
        for ten_bit in (False, True):
            _, before, after = renderer.render(pixels, (2, 2), (2, 2), mode,
                source_format=2, source_stride=24, source_transfer=1, output_transfer=2, alpha_mode=2,
                background_alpha=0, capture_transfer=2, capture_phases=3, capture16=True, ten_bit=ten_bit, continuation=continuation)
            actual = struct.unpack("<16H", before)
            assert max(abs(a - b) for a, b in zip(actual, expected)) <= 2, (mode, actual, expected)
            assert actual[7] == 129 and before == after
            assert actual[0] % 257 != 0, "capture must not be expanded from 8 bits"
    print(f"RGBA16 capture: {renderer.draw_count - start} draws passed (low RGB/alpha, channel order, padded stride, 8/10-bit display)")


def test_blur_precision(renderer):
    # Independent 49-tap Gaussian, not the shader's paired weights/offsets.
    width, height = 9, 7
    values = [[(x / 16, y / 12, int(x == 1 and y == 4), 1)
               for x in range(width)] for y in range(height)]
    weights = [math.exp(-i * i / 128) for i in range(-24, 25)]
    total = sum(weights)
    horizontal = [[[sum(values[y][min(width - 1, max(0, x + i))][c] * weights[i + 24]
                        for i in range(-24, 25)) / total for c in range(4)]
                   for x in range(width)] for y in range(height)]
    expected = [round(sum(horizontal[min(height - 1, max(0, y + i))][x][c] * weights[i + 24]
                         for i in range(-24, 25)) / total * 65535)
                for y in range(height) for x in range(width) for c in range(4)]
    pixels = b"".join(struct.pack("<4f", *pixel) for row in values for pixel in row)
    for mode in ("texture", "texture-buffer"):
        _, actual, _ = renderer.render(pixels, (width, height), (width, height), mode,
            source_format=12, source_transfer=1, output_transfer=1, capture_transfer=1,
            background_alpha=0, alpha_mode=2, continuation=True, blur=True, capture16=True, capture_phases=1)
        actual = struct.unpack(f"<{width * height * 4}H", actual)
        assert max(abs(a - b) for a, b in zip(actual, expected)) <= 2, (mode, actual, expected)
    print("FP32 blur: 2 draws passed (independent Gaussian, clamped edges, low impulse, RGBA16 export)")


def test_output_order(renderer):
    start = renderer.draw_count
    for mode in ("buffer", "texture", "texture-buffer"):
        for ten_bit in (False, True):
            for alpha in (1, .25):
                captures = []
                for rgb in (False, True):
                    output, before, _ = renderer.render(struct.pack("<4e", .125, .25, .5, alpha), (1, 1), (1, 1), mode,
                        source_format=10, source_transfer=1, output_transfer=1, alpha_mode=2, background_alpha=0,
                        capture_phases=1, ten_bit=ten_bit, raw_output=True, rgb_output=rgb)
                    if ten_bit:
                        word, = struct.unpack("<I", output)
                        actual = (word & 1023, (word >> 10) & 1023, (word >> 20) & 1023, word >> 30)
                    else:
                        actual = output
                    channels = (.125, .25, .5) if rgb else (.5, .25, .125)
                    expected = [round(x * alpha * (1023 if ten_bit else 255)) for x in channels] + [round(alpha * (3 if ten_bit else 255))]
                    assert max(abs(a - b) for a, b in zip(actual, expected)) <= 1, (mode, rgb, actual, expected)
                    captures.append(before)
                assert captures[0] == captures[1], "raw capture must not inherit output channel order"
    print(f"Output order: {renderer.draw_count - start} draws passed (RGB/BGR, 8/10-bit, alpha, independent capture)")


def test_capture_shoulder(renderer, capture_path):
    start = renderer.draw_count
    # Independent evaluated points: shadow, knee, reference white, 2x and 4x.
    peaks = (1 / 1024, .5, 1, 2, 4)
    mapped = (1 / 1024, .5, .75, .875, .9375)
    for mode in ("buffer", "texture", "texture-buffer"):
        for alpha in (1, .25):
            pixels = b"".join(struct.pack("<4e", peak, peak / 4, peak / 16, alpha) for peak in peaks)
            args = dict(source_format=10, source_transfer=1, alpha_mode=2, output_transfer=2,
                        background_alpha=0, capture_phases=3, capture_transfer=2, copy_capture=True)
            original, clipped, _ = renderer.render(pixels, (5, 1), (5, 1), mode, **args)
            output, before, after = renderer.render(pixels, (5, 1), (5, 1), mode, capture_shoulder=True, **args)
            expected = bytes(c for peak in mapped for c in
                (*(round(255 * alpha * (peak * ratio) ** (1 / 2.2)) for ratio in (1 / 16, 1 / 4, 1)), round(255 * alpha)))
            assert output == original and before == after
            assert max(abs(a - b) for a, b in zip(before, expected)) <= 1, (mode, before, expected)
            assert before[:8] == clipped[:8], "shoulder must preserve shadows and knee"
            assert before[10] < before[14] < before[18], "above-white detail must not clip"
            if capture_path and mode == "texture" and alpha == 1:
                sheet = Image.new("RGB", (720, 220), "#202020")
                draw = ImageDraw.Draw(sheet)
                for row, (label, data) in enumerate((("Clipped SDR: shadow / knee / white / 2x / 4x", clipped),
                                                     ("SDR shoulder: shadows unchanged, highlight detail retained", before))):
                    draw.text((12, row * 110 + 10), label, fill="white")
                    preview = []
                    for i, n in enumerate(data):
                        linear = (n / 255) ** 2.2
                        encoded = 12.92 * linear if linear <= .0031308 else 1.055 * linear ** (1 / 2.4) - .055
                        preview.append(255 if i % 4 == 3 else round(255 * encoded))
                    sheet.paste(Image.frombytes("RGBA", (5, 1), bytes(preview), "raw", "BGRA").resize((696, 60), Image.Resampling.NEAREST), (12, row * 110 + 35))
                sheet.save(capture_path.with_stem(capture_path.stem + "-shoulder"))
    print(f"SDR shoulder: {renderer.draw_count - start} draws passed (HDR detail, low light, alpha, image export, unchanged display)")


def test_video(renderer, capture_path):
    start = renderer.draw_count
    names = ("NV12", "NV21", "P010", "P012", "P016", "YUV420", "YVU420", "YUYV", "UYVY")
    sheet = Image.new("RGB", (720, 240), "#202020")
    draw = ImageDraw.Draw(sheet)

    def planes_for(fmt, y, cb, cr):
        wide = fmt in (15, 16, 17)
        shift = 6 if fmt == 15 else 4 if fmt == 16 else 0
        def words(values):
            # Poison insignificant low bits: interpreting P010 as UNORM16
            # without removing padding must not affect reconstruction.
            return b"".join(struct.pack("<H", (n << shift) | ((1 << shift) - 1)) if wide else bytes([n]) for n in values)
        cb = [cb] * 4 if isinstance(cb, int) else cb
        cr = [cr] * 4 if isinstance(cr, int) else cr
        if fmt >= 20:
            row = bytes([y, cb[0], y + 13, cr[0]] if fmt == 20 else [cb[0], y, cr[0], y + 13]) * 2 + b"\xff" * 4
            return [(row * 4, (2, 4), v.VK_FORMAT_R8G8B8A8_UNORM, 12, 4)]
        bpp = 2 if wide else 1
        row = words([y] * 4) + bytes([213]) * (2 * bpp)
        result = [(row * 4, (4, 4), v.VK_FORMAT_R16_UNORM if wide else v.VK_FORMAT_R8_UNORM, 6 * bpp, bpp)]
        if fmt in (14, 19):
            cb, cr = cr, cb
        channels = [list(sum(zip(cb, cr), ()))] if fmt < 18 else [cb, cr]
        count = 2 if fmt < 18 else 1
        for channel in channels:
            data = b"".join(words(channel[row * 2 * count:(row + 1) * 2 * count]) + bytes([207]) * (2 * count * bpp) for row in range(2))
            result.append((data, (2, 2), (v.VK_FORMAT_R16G16_UNORM if wide else v.VK_FORMAT_R8G8_UNORM) if count == 2 else v.VK_FORMAT_R8_UNORM, 4 * count * bpp, count * bpp))
        return result

    def expected(y, cb, cr, scale, full, kr, kb, alpha=255):
        maximum = 256 * scale - 1
        y = y / maximum if full else (y - 16 * scale) / (219 * scale)
        cb = (cb - 128 * scale) / (maximum if full else 224 * scale)
        cr = (cr - 128 * scale) / (maximum if full else 224 * scale)
        # Independent H.273 expanded matrix, not a shader implementation call.
        rgb = (y + (2 - 2 * kr) * cr,
               y - (2 * kb - 2 * kb * kb) / (1 - kr - kb) * cb - (2 * kr - 2 * kr * kr) / (1 - kr - kb) * cr,
               y + (2 - 2 * kb) * cb)
        def encode(n):
            n = max(0, n * alpha / 255)
            return round(255 * min(1, 12.92 * n if n <= .0031308 else 1.055 * n ** (1 / 2.4) - .055))
        return bytes([encode(n) for n in reversed(rgb)] + [255])

    for fmt, name in enumerate(names, 13):
        scale = {15: 4, 16: 16, 17: 256}.get(fmt, 1)
        y, cb, cr = 117 * scale, 96 * scale, 171 * scale
        planes = planes_for(fmt, y, cb, cr)
        for coefficients, kr, kb in ((2, .2126, .0722), (3, .299, .114), (4, .2627, .0593)):
            for full in (False, True):
                result, capture, _ = renderer.render(planes[0][0], (4, 4), (4, 4), "texture",
                    source_format=fmt, source_stride=planes[0][3], video_planes=planes,
                    representation=coefficients | ((1 if full else 2) << 4), source_transfer=1,
                    background=(0, 0, 0), capture_phases=1, alpha=128)
                want = expected(y, cb, cr, scale, full, kr, kb, 128) * 16
                if fmt >= 20:
                    want = (expected(y, cb, cr, scale, full, kr, kb, 128) + expected(y + 13, cb, cr, scale, full, kr, kb, 128)) * 8
                assert max(abs(a - b) for a, b in zip(capture, want)) <= 1, (name, coefficients, full, list(capture[:4]), list(want[:4]))
                if coefficients == 2 and not full:
                    x, top = ((fmt - 13) % 5) * 144, ((fmt - 13) // 5) * 120
                    draw.text((x + 8, top + 8), name + " / 709 limited", fill="white")
                    sheet.paste(Image.frombytes("RGBA", (4, 4), capture, "raw", "BGRA").resize((128, 80)), (x + 8, top + 28))
    for location, (ox, oy) in enumerate(((0, .5), (.5, .5), (0, 0), (.5, 0), (0, 1), (.5, 1)), 1):
        planes = planes_for(13, 117, [90, 110, 130, 150], 171)
        _, capture, _ = renderer.render(planes[0][0], (4, 4), (4, 4), "texture",
            source_format=13, source_stride=planes[0][3], video_planes=planes,
            representation=2 | (2 << 4) | (location << 8), source_transfer=1, capture_phases=1,
            damage=[(1, 1, 2, 2)])
        want = expected(117, 90 + 20 * (1 - ox) / 2 + 40 * (1 - oy) / 2, 171, 1, False, .2126, .0722)
        assert max(abs(a - b) for a, b in zip(capture[20:24], want)) <= 1, (location, capture[20:24], want)
        assert capture[:20] == bytes([37]) * 20 and capture[-16:] == bytes([37]) * 16
    for fmt, scale in ((15, 4), (16, 16), (17, 256)):
        planes = planes_for(fmt, 16 * scale + 1, 128 * scale, 128 * scale)
        # Exposure makes a single low linear-light step visible after export.
        result = renderer.render(planes[0][0], (4, 4), (4, 4), "texture", source_format=fmt,
            source_stride=planes[0][3], video_planes=planes, source_transfer=1, luminance_scale=64)
        linear = 64 / (219 * scale)
        code = round(255 * (12.92 * linear if linear <= .0031308 else 1.055 * linear ** (1 / 2.4) - .055))
        assert abs(result[0] - code) <= 1 and result[0] > 0, (fmt, result[:4], code)
    if capture_path:
        sheet.save(capture_path)
    print(f"Native video: {renderer.draw_count - start} draws passed (9 layouts, matrices/ranges, chroma siting, stride/damage, alpha, low light)")


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


def test_scene(renderer):
    # Distinct textures, a clipped non-origin destination, and overlapping top
    # layer catch descriptor reuse, wrong upload offsets, order and clip errors.
    identity = (65536, 0, 32768, 0, 65536, 32768)
    background = bytes((17, 61, 193, 255)) * 20
    middle = bytes(c for y in range(2) for x in range(3)
                   for c in (x * 37 + y * 11, x * 9 + y * 43, x * 67 + y * 3, 255))
    top = bytes((85, 23, 172, 255))
    scene = [
        (scene_sample((5, 4), (0, 0, 5, 4), identity), background, (5, 4)),
        (scene_sample((3, 2), (1, 1, 2, 2), identity, clip=(2, 0, 2, 3)), middle, (3, 2)),
        (scene_sample((1, 1), (2, 2, 1, 1), identity), top, (1, 1)),
    ]
    expected = bytearray(background)
    # Output (2,1) reads middle texel (1,0), not a re-derived 3:2 mapping.
    # Output (2,2) is covered by the third texture.
    expected[28:32] = bytes((37, 9, 67, 255))
    expected[48:52] = top
    for mode in ("buffer", "texture", "texture-buffer"):
        for ten_bit in (False, True):
            for damage in (None, [(0, 0, 5, 1), (0, 1, 2, 3), (2, 1, 3, 3)]):
                timings = []
                result = renderer.render(background, (5, 4), (5, 4), mode, scene=scene,
                                         ten_bit=ten_bit, damage=damage, timings=timings, timing_repeats=3)
                assert len(timings) == 3 and all(math.isfinite(t) and t > 0 for t in timings), timings
                assert all(abs(a - b) <= 1 for a, b in zip(result, expected)), (mode, ten_bit, damage, result)
    print("PASS: 12 multi-layer scene draws; 8/10-bit, packed/texture/content, affine, clipping, damage, query replay")


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
                options = dict(ten_bit=ten_bit, output_transfer=transfer, output_reference=203,
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


def capture_surface(renderer, source_path, path):
    """Compare identical 2x app pixels with old and default surface sampling."""
    source = Image.open(source_path).convert("RGBA")
    pixels = source.tobytes("raw", "BGRA")
    scales = (1.25, 1.5, 1.75, 2)
    sizes = [tuple(round(n * scale / 2) for n in source.size) for scale in scales]
    column = source.width + 24
    sheet = Image.new("RGB", (column * 2 + 24, sum(h + 40 for _, h in sizes) + 50), "#18212b")
    draw = ImageDraw.Draw(sheet)
    draw.text((16, 12), "Before: nearest", fill="white")
    draw.text((column + 16, 12), "After: adaptive - identical GTK 2x source, Vulkan readback", fill="white")
    y = 45
    for scale, size in zip(scales, sizes):
        results = []
        for col, filtering in enumerate(("nearest", None)):
            result = renderer.render(pixels, source.size, size, "texture", filtering=filtering)
            # Normalized texture fetches and integer-buffer conversion can
            # round interpolated colors differently by one 8-bit code value.
            storage = renderer.render(pixels, source.size, size, "buffer", filtering=filtering)
            assert max(abs(a - b) for a, b in zip(result, storage)) <= 1
            results.append(result)
            draw.text((16 + col * column, y), f"{scale * 100:g}% - native output pixels", fill="white")
            sheet.paste(Image.frombytes("RGBA", size, result, "raw", "BGRA").convert("RGB"),
                        (16 + col * column, y + 22))
        if size == source.size:
            assert results[0] == results[1], "aligned 1:1 surface changed"
        else:
            assert results[0] != results[1], "fractional surface was not filtered"
        y += size[1] + 40
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)
    print("PASS: 16 Vulkan app draws; fractional filtering, native 1:1, SHM/texture parity; capture:", path)


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


def benchmark(renderer):
    # A 2x client on a 125% UHD output: 1.6 source texels per output pixel.
    # This is a controlled single opaque surface, not a replay of a live frame.
    source_size, size = (6144, 3456), (3840, 2160)
    pattern = Image.new("RGBA", (96, 54))
    pattern.putdata([((x * 17 + y * 3) % 256, (x * 7 + y * 19) % 256,
                      (x * 23 + y * 11) % 256, 255) for y in range(54) for x in range(96)])
    pixels = pattern.resize(source_size, Image.Resampling.NEAREST).tobytes("raw", "BGRA")
    results = {mode: [] for mode in ("nearest", "bilinear", "reconstruction")}
    # Interleave variants to reduce warmup/frequency/order bias. Discard the
    # first measurement of each. Setup, upload and readback are outside timing.
    for iteration in range(6):
        modes = list(results)
        if iteration % 2:
            modes.reverse()
        for mode in modes:
            renderer.render(pixels, source_size, size, "texture", xrgb=True,
                            filtering=mode, timings=results[mode])
    for mode, values in results.items():
        values = values[1:]
        print(f"BENCH {mode}: median={statistics.median(values):.3f} ms "
              f"min={min(values):.3f} max={max(values):.3f} samples={values}")
    print("GPU spans include preemption/waits. Nearest and bilinear are cost controls, not quality-equivalent replacements.")


def benchmark_stall(renderer):
    # 2026-09-11 09:34:40, output 3840x2160, submit_ns=70231935993529.
    # Live sampled span: 35.637 ms. All source/output transfers are sRGB,
    # no LUTs, global alpha 255, ARGB, direct_color_eligible=false.
    identity = (65536, 0, 32768, 0, 65536, 32768)
    geometry = [
        ((3840, 2160), (0, 0, 3840, 2160), identity, "nearest"),
        ((3850, 2133), (0, 53, 3840, 2107), (65536, 0, 360448, 0, 65566, 32783), "reconstruction"),
        ((3840, 50), (0, 0, 3840, 50), identity, "nearest"),
        ((30, 30), (161, 223, 30, 30), identity, "nearest"),
    ]
    scene = []
    for seed, (dimensions, destination, affine, filtering) in enumerate(geometry):
        pattern = Image.new("RGBA", (96, 54))
        pattern.putdata([((x * 17 + y * 3 + seed * 41) % 256,
                          (x * 7 + y * 19 + seed * 13) % 256,
                          (x * 23 + y * 11 + seed * 71) % 256, 255)
                         for y in range(54) for x in range(96)])
        image = pattern.resize(dimensions, Image.Resampling.NEAREST)
        if seed == 3:
            image = Image.new("RGBA", dimensions)
            ImageDraw.Draw(image).polygon([(1, 1), (1, 26), (9, 19), (19, 19)], fill=(255, 255, 255, 255))
        scene.append((scene_sample(dimensions, destination, affine, filtering),
                      image.tobytes("raw", "BGRA"), dimensions))
    cases = [
        ("recorded-cubic-10bit", "reconstruction", True, False, None),
        ("bilinear-control-10bit", "bilinear", True, False, None),
        ("nearest-control-10bit", "nearest", True, False, None),
        ("cubic-8bit", "reconstruction", False, False, None),
        ("cubic-window-only-10bit", "reconstruction", True, True, None),
        ("cubic-small-damage-10bit", "reconstruction", True, False, [(100, 200, 768, 432)]),
    ]
    results = {name: [] for name, *_ in cases}
    print("STALL workload: external 09:34:40; recorded geometry/flags, synthetic pixels, identity color matrices.")
    print("Optimal-tiled textures replace imported DMA-BUFs; no ICC LUT, client fences or cross-output queue replay.")
    # Reverse case order in the second round. Each batch uploads/compiles once
    # and replays 12 submissions; discard two warmups, retain 20 samples/case.
    for round_index in range(2):
        for name, filtering, ten_bit, window_only, damage in (cases if round_index == 0 else cases[::-1]):
            layers = list(scene)
            dimensions, destination, affine, _ = geometry[1]
            layers[1] = (scene_sample(dimensions, destination, affine, filtering), scene[1][1], dimensions)
            if window_only:
                layers = layers[1:2]
            timings = []
            renderer.render(scene[0][1], (3840, 2160), (3840, 2160), "texture", scene=layers,
                            ten_bit=ten_bit, damage=damage, timings=timings, timing_repeats=12)
            results[name].extend(timings[2:])
            print(f"STALL batch={round_index + 1} case={name} samples_ms={timings[2:]}", flush=True)
    for name, values in results.items():
        p95 = sorted(values)[math.ceil(0.95 * len(values)) - 1]
        print(f"STALL {name}: median={statistics.median(values):.3f} ms p95={p95:.3f} "
              f"min={min(values):.3f} max={max(values):.3f} n={len(values)}")
    print("Filter/depth variants are diagnostic controls, not quality-equivalent proposed replacements.")
    print("GPU spans still include preemption. The running desktop shares this GPU.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--capture-hdr", type=Path)
    parser.add_argument("--capture-shm", type=Path)
    parser.add_argument("--capture-video", type=Path)
    parser.add_argument("--capture-roundtrip", type=Path)
    parser.add_argument("--capture-surface", type=Path, nargs=2, metavar=("SOURCE_2X", "OUTPUT"))
    parser.add_argument("--compare-shader-dir", type=Path)
    parser.add_argument("--benchmark", action="store_true", help="time UHD sampled-composition filter variants offscreen")
    parser.add_argument("--benchmark-stall", action="store_true", help="time the recorded UHD multi-layer cubic workload and controls")
    args = parser.parse_args()
    renderer = Renderer()
    try:
        if args.benchmark:
            benchmark(renderer)
        test(renderer, args.compare_shader_dir)
        test_scene(renderer)
        test_hdr_capture(renderer, args.capture_hdr)
        test_shm(renderer, args.capture_shm)
        test_modern_rgb(renderer, args.capture_shm)
        test_desktop_color(renderer, args.capture_shm)
        test_capture_roundtrip(renderer, args.capture_roundtrip)
        test_capture_shoulder(renderer, args.capture_roundtrip)
        test_capture16(renderer)
        test_blur_precision(renderer)
        test_output_order(renderer)
        test_video(renderer, args.capture_video)
        if args.benchmark_stall:
            benchmark_stall(renderer)
        if args.capture:
            capture(renderer, args.capture, args.compare_shader_dir)
        if args.capture_surface:
            capture_surface(renderer, *args.capture_surface)
    finally:
        renderer.close()
