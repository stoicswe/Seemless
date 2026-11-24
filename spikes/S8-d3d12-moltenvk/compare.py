#!/usr/bin/env python3
"""S8 spike: which Vulkan device extensions vkd3d-proton knows about are
missing from a driver.

Usage: compare.py <vkd3d-proton/libs/vkd3d/device.c> <probe.txt> [<probe2.txt> ...]
The probe files come from vkprobe (one per driver). Prints a Markdown table:
extension | what vkd3d-proton uses it for (category) | one column per driver.
"""
import re
import sys

# Rough grouping for the findings note; anything not listed is "other".
CATEGORY = {
    "KHR_push_descriptor": "required (hard check)",
    "EXT_robustness2": "required (hard check)",
    "EXT_transform_feedback": "required (hard check)",
    "EXT_vertex_attribute_divisor": "required (hard check, core in 1.4)",
    "EXT_dynamic_rendering_unused_attachments": "needed for correct operation (warned)",
    "EXT_mutable_descriptor_type": "descriptor model (fast path)",
    "VALVE_mutable_descriptor_type": "descriptor model (fast path)",
    "EXT_descriptor_buffer": "descriptor model (fast path)",
    "EXT_descriptor_heap": "descriptor model (opt-in)",
    "EXT_custom_border_color": "D3D12 core feature (border colours)",
    "EXT_conservative_rasterization": "FL 12_1",
    "EXT_fragment_shader_interlock": "FL 12_1 (ROVs)",
    "EXT_depth_clip_enable": "D3D12 core feature (DepthClipEnable)",
    "EXT_conditional_rendering": "D3D12 core feature (predication)",
    "EXT_extended_dynamic_state2": "pipeline state",
    "EXT_extended_dynamic_state3": "pipeline state",
    "EXT_graphics_pipeline_library": "PSO compile stutter",
    "EXT_shader_module_identifier": "PSO caching",
    "EXT_mesh_shader": "FL 12_2 (mesh shaders)",
    "KHR_fragment_shading_rate": "FL 12_2 (VRS)",
    "KHR_ray_tracing_pipeline": "FL 12_2 (DXR)",
    "KHR_acceleration_structure": "FL 12_2 (DXR)",
    "KHR_ray_query": "FL 12_2 (DXR 1.1)",
    "KHR_ray_tracing_maintenance1": "DXR",
    "KHR_deferred_host_operations": "DXR",
    "KHR_pipeline_library": "DXR",
    "EXT_pipeline_library_group_handles": "DXR",
    "KHR_compute_shader_derivatives": "SM 6.6",
    "NV_compute_shader_derivatives": "SM 6.6",
    "KHR_shader_maximal_reconvergence": "SM 6.7",
    "KHR_shader_quad_control": "SM 6.7",
    "EXT_shader_image_atomic_int64": "SM 6.6 (64-bit image atomics)",
    "EXT_shader_stencil_export": "SV_StencilRef",
    "KHR_fragment_shader_barycentric": "SM 6.1 (SV_Barycentrics)",
    "EXT_device_generated_commands": "ExecuteIndirect fast path",
    "EXT_image_view_min_lod": "MinLODClamp",
    "EXT_memory_budget": "residency / budget",
    "EXT_memory_priority": "residency",
    "EXT_pageable_device_local_memory": "residency",
    "EXT_external_memory_host": "OpenExistingHeapFromAddress",
    "EXT_line_rasterization": "line modes",
    "EXT_depth_bias_control": "depth bias formats",
    "EXT_image_sliced_view_of_3d": "3D UAV slices",
    "EXT_hdr_metadata": "HDR swapchains",
    "KHR_present_id": "swapchain pacing",
    "KHR_present_wait": "swapchain pacing",
    "KHR_present_id2": "swapchain pacing",
    "KHR_present_wait2": "swapchain pacing",
    "KHR_maintenance5": "required (hard check, core in 1.4)",
    "KHR_maintenance6": "required (hard check, core in 1.4)",
    "KHR_maintenance7": "misc",
    "KHR_maintenance8": "SM 6.7 AdvancedTextureOps",
    "KHR_maintenance9": "SM 6.9",
    "KHR_cooperative_matrix": "WMMA / SM 6.9 extras",
    "EXT_zero_initialize_device_memory": "heap zeroing",
    "EXT_image_compression_control": "misc",
    "EXT_shader_float8": "SM 6.9 extras",
    "EXT_shader_long_vector": "SM 6.9",
    "EXT_shader_atomic_float": "float atomics",
    "KHR_shader_float_controls2": "SM 6.2 denorm control",
    "EXT_opacity_micromap": "SM 6.9 / DXR",
    "EXT_ray_tracing_invocation_reorder": "SM 6.9 SER",
}


def vkd3d_extensions(path):
    src = open(path).read()
    start = src.index("optional_device_extensions[] =")
    end = src.index("};", start)
    names = []
    for m in re.finditer(r"VK_EXTENSION\w*\(\s*\w+\s*,\s*(\w+)", src[start:end]):
        names.append(m.group(1))
    for m in re.finditer(r'\{"VK_(\w+)"', src[start:end]):
        names.append(m.group(1))
    return names


def probe(path):
    exts, info = set(), {}
    for line in open(path):
        if line.startswith("ext "):
            exts.add(line.split()[1][3:])  # strip VK_
        else:
            parts = line.split(None, 1)
            if len(parts) == 2:
                info[parts[0]] = parts[1].strip()
    return exts, info


def main():
    names = vkd3d_extensions(sys.argv[1])
    probes = [probe(p) for p in sys.argv[2:]]
    hdr = [p[1].get("driverName", "?") + " " + p[1].get("driverInfo", "") for p in probes]
    vendor = re.compile(r"^(AMD|NV|NVX|VALVE|MESA|AMDX)_")
    print("| Extension | Used for | " + " | ".join(hdr) + " |")
    print("|---|---|" + "---|" * len(probes))
    missing_any = 0
    for n in names:
        if vendor.match(n) and n not in CATEGORY:
            continue  # vendor-specific fast paths: not a MoltenVK gap
        have = []
        for exts, _ in probes:
            alt = {"KHR_vertex_attribute_divisor": "EXT_vertex_attribute_divisor"}
            ok = n in exts or ("KHR_" + n[4:]) in exts or ("EXT_" + n[4:]) in exts
            have.append("yes" if ok else "**no**")
        if all(h == "yes" for h in have):
            continue
        missing_any += 1
        print(f"| VK_{n} | {CATEGORY.get(n, 'other')} | " + " | ".join(have) + " |")
    print(f"\n{missing_any} non-vendor extensions known to vkd3d-proton are missing from at least one driver.")


if __name__ == "__main__":
    main()
