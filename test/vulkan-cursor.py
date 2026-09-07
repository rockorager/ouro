#!/usr/bin/env python3
"""Execute Ouro's committed compute shaders on Vulkan (including lavapipe).

Run: uv run --with vulkan --with pillow python test/vulkan-cursor.py
Optional: --capture path.png (uses installed Adwaita Xcursor assets).
No DRM device, compositor session, or display server is required.
"""

import argparse
from contextlib import ExitStack
from pathlib import Path
import struct

import vulkan as v
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


class Renderer:
    def __init__(self):
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

    def render(self, pixels, source_size, size, mode, bilinear=True, xrgb=False,
               alpha=255, crop=None, transform=0):
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
            xx, yy = int(cw * 65536) // w, int(ch * 65536) // h
            x0, y0 = int(sx * 65536) + xx // 2, int(sy * 65536) + yy // 2
            if transform == 2:  # 180-degree buffer transform
                x0 = int((sx + cw) * 65536) - xx // 2
                y0 = int((sy + ch) * 65536) - yy // 2
                xx, yy = -xx, -yy
            flags = (0x20000000 if bilinear else 0) | (0x40000000 if mode == "texture-buffer" else 0)
            # Include the opaque fast path: it must not bypass filtering.
            if xrgb and alpha == 255:
                flags |= 0x80000000
            sample = struct.pack("<4I12i4I8i12f", 0, sw, sh, sw * 4,
                int(sx * 65536), int(sy * 65536), int(cw * 65536), int(ch * 65536),
                0, 0, w, h, 0, 0, w, h, int(xrgb), flags, alpha, 0,
                xx, 0, x0, 0, yy, y0, 0, 0,
                1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0)
            storage = v.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
            samples = buffer(sample, storage)
            source = buffer(pixels, storage | v.VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
            lut = buffer(bytes(16), storage)
            readback = buffer(bytes(w * h * 4), v.VK_BUFFER_USAGE_TRANSFER_DST_BIT)
            target, target_view = image(w, h, v.VK_FORMAT_R8G8B8A8_UNORM,
                v.VK_IMAGE_USAGE_STORAGE_BIT | v.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
            src_image, src_view = image(sw, sh, v.VK_FORMAT_B8G8R8A8_UNORM,
                v.VK_IMAGE_USAGE_SAMPLED_BIT | v.VK_IMAGE_USAGE_TRANSFER_DST_BIT)
            linear, linear_view = image(w, h, v.VK_FORMAT_R16G16B16A16_SFLOAT, v.VK_IMAGE_USAGE_STORAGE_BIT)
            sampler = own(v.vkCreateSampler, v.vkDestroySampler, v.VkSamplerCreateInfo(
                magFilter=v.VK_FILTER_NEAREST, minFilter=v.VK_FILTER_NEAREST,
                addressModeU=v.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeV=v.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeW=v.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE))
            types = {0: (v.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1),
                     1: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1),
                     4: (v.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1)}
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
                if b in (1, 2, 4, 6):
                    buf = samples if b == 1 else lut if b == 4 else source
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
                    stageFlags=v.VK_SHADER_STAGE_COMPUTE_BIT, size=64)]))
            code = (ROOT / "src/render" / ("vulkan_texture_composite.spv" if texture else "vulkan_composite.spv")).read_bytes()
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
            push = struct.pack("<16I", 255, 80, 100, 120, w, h, 1, 1, 0, 0, w, h, 0, 0, 0, 0)
            v.vkCmdPushConstants(cmd, pl, v.VK_SHADER_STAGE_COMPUTE_BIT, 0, 64, v.ffi.from_buffer(push))
            v.vkCmdDispatch(cmd, (w + 7) // 8, (h + 7) // 8, 1)
            barrier(v.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, v.VK_PIPELINE_STAGE_TRANSFER_BIT,
                    v.VK_ACCESS_SHADER_WRITE_BIT, v.VK_ACCESS_TRANSFER_READ_BIT)
            v.vkCmdCopyImageToBuffer(cmd, target, v.VK_IMAGE_LAYOUT_GENERAL, readback[0], 1, [region(w, h)])
            barrier(v.VK_PIPELINE_STAGE_TRANSFER_BIT, v.VK_PIPELINE_STAGE_HOST_BIT,
                    v.VK_ACCESS_TRANSFER_WRITE_BIT, v.VK_ACCESS_HOST_READ_BIT)
            v.vkEndCommandBuffer(cmd)
            v.vkQueueSubmit(self.queue, 1, [v.VkSubmitInfo(pCommandBuffers=[cmd])], v.VK_NULL_HANDLE)
            v.vkQueueWaitIdle(self.queue)
            mapped = v.vkMapMemory(d, readback[1], 0, readback[2], 0)
            result = bytes(mapped)
            v.vkUnmapMemory(d, readback[1])
            return result


def test(renderer):
    # BGRA: opaque red next to transparent black. Correct premultiplied
    # filtering keeps saturated red, without dark/colored fringes.
    pixels = bytes([0, 0, 255, 255, 0, 0, 0, 0])
    count = 0
    for size in [(2, 1), (3, 2), (5, 3), (1, 1)]:
        for alpha in (255, 128):
            for xrgb in (False, True):
                for transform in (0, 2):
                    results = [renderer.render(pixels, (2, 1), size, mode, alpha=alpha,
                                               xrgb=xrgb, transform=transform)
                               for mode in ("buffer", "texture", "texture-buffer")]
                    assert results[0] == results[1] == results[2], (size, alpha, xrgb, transform)
                    count += 3
    for mode in ("buffer", "texture", "texture-buffer"):
        identity = renderer.render(pixels, (2, 1), (2, 1), mode)
        assert identity == renderer.render(pixels, (2, 1), (2, 1), mode, bilinear=False)
        midpoint = renderer.render(pixels, (2, 1), (3, 1), mode)[4:8]
        # Linear OVER: half red plus half background (RGB 80,100,120).
        assert all(abs(a - b) <= 1 for a, b in zip(midpoint, (86, 71, 194, 255))), midpoint
        # Fractional crop at 1:1 density still requires filtering.
        cropped = renderer.render(pixels, (2, 1), (1, 1), mode, crop=(0.5, 0, 1, 1))
        assert cropped == midpoint
        enlarged = renderer.render(pixels, (2, 1), (5, 1), mode)
        assert enlarged != renderer.render(pixels, (2, 1), (5, 1), mode, bilinear=False)
        assert enlarged[:4] == identity[:4] and enlarged[-4:] == identity[-4:]
        count += 6
    # Client 2x buffers resized to 100%, 125%, 150%, and 200% outputs.
    pattern = bytes(channel for y in range(48) for x in range(48)
                    for channel in ((255, 255, 255, 255) if x <= y else (0, 0, 0, 0)))
    for size in (24, 30, 36, 48):
        results = [renderer.render(pattern, (48, 48), (size, size), mode)
                   for mode in ("buffer", "texture", "texture-buffer")]
        assert results[0] == results[1] == results[2], size
        count += 3
    print(f"PASS: {count} Vulkan cursor draws; sampled image, direct-content and buffer fallback agree")


def xcursor(name, requested):
    data = (Path("/usr/share/icons/Adwaita/cursors") / name).read_bytes()
    header, _, count = struct.unpack_from("<3I", data, 4)
    toc = [struct.unpack_from("<3I", data, header + i * 12) for i in range(count)]
    _, nominal, offset = min((t for t in toc if t[0] == 0xfffd0002),
                             key=lambda t: (t[1] < requested, t[1] if t[1] >= requested else -t[1]))
    chunk, _, _, _, w, h, _, _, _ = struct.unpack_from("<9I", data, offset)
    return data[offset + chunk:offset + chunk + w * h * 4], (w, h), nominal


def capture(renderer, path):
    scales = (1, 1.25, 1.5, 2)
    sheet = Image.new("RGB", (850, 1380), "#18212b")
    draw = ImageDraw.Draw(sheet)
    draw.text((16, 10), "Ouro cursor rendering - actual Vulkan shader readback (3x pixel zoom)", fill="white")
    for col, scale in enumerate(scales):
        draw.text((220 + col * 150, 36), f"{scale * 100:g}%", fill="white")
    for row, (shape, client, after) in enumerate((s, c, a) for s in ("default", "text")
                                               for c in (False, True) for a in (False, True)):
        label = f"{shape} / {'client 2x' if client else 'theme'}\n{'after' if after else 'before'}"
        y = 66 + row * 160
        draw.text((16, y + 12), label, fill="white")
        for col, scale in enumerate(scales):
            requested = 48 if client else int(24 * scale) if after else 24
            pixels, (w, h), nominal = xcursor(shape, requested)
            logical = (round(w * 24 / nominal), round(h * 24 / nominal)) if after or client else (w, h)
            size = tuple(round(n * scale) for n in logical)
            result = renderer.render(pixels, (w, h), size, "texture", bilinear=after)
            im = Image.frombytes("RGBA", size, result, "raw", "BGRA").convert("RGB")
            # Zoom is nearest so the sheet exposes, rather than smooths, GPU pixels.
            sheet.paste(im.resize((size[0] * 3, size[1] * 3), Image.Resampling.NEAREST), (210 + col * 150, y))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)
    print("Capture:", path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path)
    args = parser.parse_args()
    renderer = Renderer()
    try:
        test(renderer)
        if args.capture:
            capture(renderer, args.capture)
    finally:
        renderer.close()
