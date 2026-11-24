/* S8 spike: print the Vulkan features/properties/extensions that vkd3d-proton
 * v3.1 checks (libs/vkd3d/device.c), for whatever ICD the loader picks.
 * Select the driver with VK_DRIVER_FILES=<icd.json>.
 *
 * Output: "key value" lines, one per item, then "ext <name> <specVersion>"
 * for every device extension. compare.py turns two of these plus the
 * vkd3d-proton source into the gap list. */
#define VK_ENABLE_BETA_EXTENSIONS
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static VkExtensionProperties *exts;
static uint32_t ext_count;

static int has_ext(const char *name)
{
    for (uint32_t i = 0; i < ext_count; i++)
        if (!strcmp(exts[i].extensionName, name))
            return 1;
    return 0;
}

#define CHAIN(s, ext) do { if (!(ext) || has_ext(ext)) { (s).pNext = next; next = &(s); } } while (0)
#define P(key, val) printf("%-60s %llu\n", key, (unsigned long long)(val))
#define PX(key, val) printf("%-60s 0x%llx\n", key, (unsigned long long)(val))

int main(void)
{
    const char *inst_exts[] = { VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
            VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME };
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    VkPhysicalDevice pd;
    uint32_t n = 1;
    VkInstance inst;
    VkResult vr;
    void *next;

    app.apiVersion = VK_API_VERSION_1_4;
    ici.pApplicationInfo = &app;
    ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = inst_exts;
    if ((vr = vkCreateInstance(&ici, NULL, &inst)) != VK_SUCCESS)
    {
        fprintf(stderr, "vkCreateInstance failed: %d\n", vr);
        return 1;
    }
    vr = vkEnumeratePhysicalDevices(inst, &n, &pd);
    if ((vr != VK_SUCCESS && vr != VK_INCOMPLETE) || !n)
    {
        fprintf(stderr, "no physical device: %d\n", vr);
        return 1;
    }
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ext_count, NULL);
    exts = calloc(ext_count, sizeof(*exts));
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ext_count, exts);

    /* ---- properties ---- */
    VkPhysicalDeviceVulkan11Properties p11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES };
    VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
    VkPhysicalDeviceVulkan13Properties p13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES };
    VkPhysicalDeviceTransformFeedbackPropertiesEXT pxfb = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT };
    VkPhysicalDeviceVertexAttributeDivisorPropertiesKHR pdiv = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_PROPERTIES_KHR };
    VkPhysicalDeviceConservativeRasterizationPropertiesEXT pcons = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CONSERVATIVE_RASTERIZATION_PROPERTIES_EXT };
    VkPhysicalDeviceDescriptorBufferPropertiesEXT pdb = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT };
    VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
    next = NULL;
    CHAIN(p11, NULL); CHAIN(p12, NULL); CHAIN(p13, NULL);
    CHAIN(pxfb, VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME);
    if (has_ext(VK_KHR_VERTEX_ATTRIBUTE_DIVISOR_EXTENSION_NAME) || has_ext(VK_EXT_VERTEX_ATTRIBUTE_DIVISOR_EXTENSION_NAME))
        CHAIN(pdiv, NULL);
    CHAIN(pcons, VK_EXT_CONSERVATIVE_RASTERIZATION_EXTENSION_NAME);
    CHAIN(pdb, VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME);
    p2.pNext = next;
    vkGetPhysicalDeviceProperties2(pd, &p2);
    const VkPhysicalDeviceLimits *l = &p2.properties.limits;

    printf("deviceName                                                   %s\n", p2.properties.deviceName);
    printf("driverName                                                   %s\n", p12.driverName);
    printf("driverInfo                                                   %s\n", p12.driverInfo);
    printf("apiVersion                                                   %u.%u.%u\n",
            VK_API_VERSION_MAJOR(p2.properties.apiVersion), VK_API_VERSION_MINOR(p2.properties.apiVersion),
            VK_API_VERSION_PATCH(p2.properties.apiVersion));
    printf("conformanceVersion                                           %u.%u.%u.%u\n",
            p12.conformanceVersion.major, p12.conformanceVersion.minor,
            p12.conformanceVersion.subminor, p12.conformanceVersion.patch);
    P("driverID", p12.driverID);
    P("prop.xfb.transformFeedbackQueries [hard]", pxfb.transformFeedbackQueries);
    P("prop.xfb.maxTransformFeedbackStreams", pxfb.maxTransformFeedbackStreams);
    P("prop.xfb.transformFeedbackRasterizationStreamSelect", pxfb.transformFeedbackRasterizationStreamSelect);
    P("prop.13.storageTexelBufferOffsetSingleTexelAlignment [hard]", p13.storageTexelBufferOffsetSingleTexelAlignment);
    P("prop.13.storageTexelBufferOffsetAlignmentBytes", p13.storageTexelBufferOffsetAlignmentBytes);
    P("prop.13.uniformTexelBufferOffsetSingleTexelAlignment [hard]", p13.uniformTexelBufferOffsetSingleTexelAlignment);
    P("prop.13.uniformTexelBufferOffsetAlignmentBytes", p13.uniformTexelBufferOffsetAlignmentBytes);
    P("prop.13.minSubgroupSize", p13.minSubgroupSize);
    P("prop.13.maxSubgroupSize", p13.maxSubgroupSize);
    PX("prop.13.requiredSubgroupSizeStages", p13.requiredSubgroupSizeStages);
    P("prop.11.subgroupSize [SM6.0 >=4]", p11.subgroupSize);
    PX("prop.11.subgroupSupportedOperations [SM6.0 needs 0x4f]", p11.subgroupSupportedOperations);
    PX("prop.11.subgroupSupportedStages [SM6.0 needs CS|FS 0x30]", p11.subgroupSupportedStages);
    P("prop.12.denormBehaviorIndependence [SM6.2 !=NONE(2)]", p12.denormBehaviorIndependence);
    P("prop.12.shaderDenormFlushToZeroFloat32 [SM6.2]", p12.shaderDenormFlushToZeroFloat32);
    P("prop.12.shaderDenormPreserveFloat32 [SM6.2]", p12.shaderDenormPreserveFloat32);
    P("prop.12.robustBufferAccessUpdateAfterBind", p12.robustBufferAccessUpdateAfterBind);
    P("prop.12.maxPerStageDescriptorUpdateAfterBindSamplers", p12.maxPerStageDescriptorUpdateAfterBindSamplers);
    P("prop.12.maxPerStageDescriptorUpdateAfterBindSampledImages", p12.maxPerStageDescriptorUpdateAfterBindSampledImages);
    P("prop.12.maxPerStageDescriptorUpdateAfterBindStorageImages", p12.maxPerStageDescriptorUpdateAfterBindStorageImages);
    P("prop.12.maxPerStageDescriptorUpdateAfterBindStorageBuffers", p12.maxPerStageDescriptorUpdateAfterBindStorageBuffers);
    P("prop.12.maxPerStageDescriptorUpdateAfterBindUniformBuffers", p12.maxPerStageDescriptorUpdateAfterBindUniformBuffers);
    P("prop.12.maxUpdateAfterBindDescriptorsInAllPools", p12.maxUpdateAfterBindDescriptorsInAllPools);
    P("prop.div.maxVertexAttribDivisor", pdiv.maxVertexAttribDivisor);
    P("prop.cons.primitiveUnderestimation", pcons.primitiveUnderestimation);
    P("prop.cons.fullyCoveredFragmentShaderInputVariable", pcons.fullyCoveredFragmentShaderInputVariable);
    P("prop.cons.degenerateTrianglesRasterized", pcons.degenerateTrianglesRasterized);
    P("limit.maxBoundDescriptorSets", l->maxBoundDescriptorSets);
    P("limit.maxPerStageDescriptorStorageBuffers [FL11.1 >=64]", l->maxPerStageDescriptorStorageBuffers);
    P("limit.maxPerStageDescriptorStorageImages [FL11.1 >=64]", l->maxPerStageDescriptorStorageImages);
    P("limit.maxPushConstantsSize", l->maxPushConstantsSize);
    P("limit.maxViewports", l->maxViewports);
    P("limit.maxColorAttachments", l->maxColorAttachments);
    P("limit.bufferImageGranularity", l->bufferImageGranularity);
    P("limit.minStorageBufferOffsetAlignment", l->minStorageBufferOffsetAlignment);
    P("limit.minTexelBufferOffsetAlignment", l->minTexelBufferOffsetAlignment);
    P("limit.maxTexelBufferElements", l->maxTexelBufferElements);
    P("limit.maxComputeSharedMemorySize", l->maxComputeSharedMemorySize);
    P("limit.maxGeometryOutputVertices", l->maxGeometryOutputVertices);
    P("limit.maxTessellationGenerationLevel", l->maxTessellationGenerationLevel);
    P("limit.timestampComputeAndGraphics", l->timestampComputeAndGraphics);
    P("sparse.residencyNonResidentStrict", p2.properties.sparseProperties.residencyNonResidentStrict);
    P("prop.db.descriptorBufferOffsetAlignment", pdb.descriptorBufferOffsetAlignment);

    /* ---- features ---- */
    VkPhysicalDeviceVulkan11Features f11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES };
    VkPhysicalDeviceVulkan12Features f12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    VkPhysicalDeviceVulkan14Features f14 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES };
    VkPhysicalDeviceTransformFeedbackFeaturesEXT fxfb = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT };
    VkPhysicalDeviceRobustness2FeaturesEXT frob2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
    VkPhysicalDeviceVertexAttributeDivisorFeaturesKHR fdiv = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_KHR };
    VkPhysicalDeviceMaintenance5FeaturesKHR fm5 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR };
    VkPhysicalDeviceMaintenance6FeaturesKHR fm6 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES_KHR };
    VkPhysicalDeviceDynamicRenderingUnusedAttachmentsFeaturesEXT fdrua = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_UNUSED_ATTACHMENTS_FEATURES_EXT };
    VkPhysicalDeviceMutableDescriptorTypeFeaturesEXT fmut = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MUTABLE_DESCRIPTOR_TYPE_FEATURES_EXT };
    VkPhysicalDeviceDescriptorBufferFeaturesEXT fdb = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT };
    VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT frov = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT };
    VkPhysicalDeviceComputeShaderDerivativesFeaturesKHR fcsd = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_COMPUTE_SHADER_DERIVATIVES_FEATURES_KHR };
    VkPhysicalDeviceShaderMaximalReconvergenceFeaturesKHR fmr = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_MAXIMAL_RECONVERGENCE_FEATURES_KHR };
    VkPhysicalDeviceShaderQuadControlFeaturesKHR fqc = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_QUAD_CONTROL_FEATURES_KHR };
    VkPhysicalDeviceDepthClipEnableFeaturesEXT fdce = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT };
    VkPhysicalDeviceExtendedDynamicState2FeaturesEXT feds2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT };
    VkPhysicalDeviceExtendedDynamicState3FeaturesEXT feds3 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT };
    VkPhysicalDeviceCustomBorderColorFeaturesEXT fcbc = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT };
    VkPhysicalDeviceMeshShaderFeaturesEXT fmesh = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT };
    VkPhysicalDeviceFragmentShadingRateFeaturesKHR fvrs = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR };
    VkPhysicalDeviceAccelerationStructureFeaturesKHR fas = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR };
    VkPhysicalDeviceRayTracingPipelineFeaturesKHR frt = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_FEATURES_KHR };
    VkPhysicalDeviceRayQueryFeaturesKHR frq = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR };
    VkPhysicalDeviceGraphicsPipelineLibraryFeaturesEXT fgpl = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GRAPHICS_PIPELINE_LIBRARY_FEATURES_EXT };
    VkPhysicalDeviceConditionalRenderingFeaturesEXT fcr = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CONDITIONAL_RENDERING_FEATURES_EXT };
    VkPhysicalDeviceShaderImageAtomicInt64FeaturesEXT fia64 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_IMAGE_ATOMIC_INT64_FEATURES_EXT };
    VkPhysicalDeviceLineRasterizationFeaturesKHR flr = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LINE_RASTERIZATION_FEATURES_KHR };
    VkPhysicalDeviceDepthBiasControlFeaturesEXT fdbc = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_BIAS_CONTROL_FEATURES_EXT };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    next = NULL;
    CHAIN(f11, NULL); CHAIN(f12, NULL); CHAIN(f13, NULL);
    if (VK_API_VERSION_MINOR(p2.properties.apiVersion) >= 4)
        CHAIN(f14, NULL);
    CHAIN(fxfb, VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME);
    if (has_ext(VK_EXT_ROBUSTNESS_2_EXTENSION_NAME) || has_ext("VK_KHR_robustness2"))
        CHAIN(frob2, NULL);
    if (has_ext(VK_KHR_VERTEX_ATTRIBUTE_DIVISOR_EXTENSION_NAME) || has_ext(VK_EXT_VERTEX_ATTRIBUTE_DIVISOR_EXTENSION_NAME))
        CHAIN(fdiv, NULL);
    CHAIN(fm5, VK_KHR_MAINTENANCE_5_EXTENSION_NAME);
    CHAIN(fm6, VK_KHR_MAINTENANCE_6_EXTENSION_NAME);
    CHAIN(fdrua, VK_EXT_DYNAMIC_RENDERING_UNUSED_ATTACHMENTS_EXTENSION_NAME);
    CHAIN(fmut, VK_EXT_MUTABLE_DESCRIPTOR_TYPE_EXTENSION_NAME);
    CHAIN(fdb, VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME);
    CHAIN(frov, VK_EXT_FRAGMENT_SHADER_INTERLOCK_EXTENSION_NAME);
    if (has_ext(VK_KHR_COMPUTE_SHADER_DERIVATIVES_EXTENSION_NAME) || has_ext("VK_NV_compute_shader_derivatives"))
        CHAIN(fcsd, NULL);
    CHAIN(fmr, VK_KHR_SHADER_MAXIMAL_RECONVERGENCE_EXTENSION_NAME);
    CHAIN(fqc, VK_KHR_SHADER_QUAD_CONTROL_EXTENSION_NAME);
    CHAIN(fdce, VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME);
    CHAIN(feds2, VK_EXT_EXTENDED_DYNAMIC_STATE_2_EXTENSION_NAME);
    CHAIN(feds3, VK_EXT_EXTENDED_DYNAMIC_STATE_3_EXTENSION_NAME);
    CHAIN(fcbc, VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME);
    CHAIN(fmesh, VK_EXT_MESH_SHADER_EXTENSION_NAME);
    CHAIN(fvrs, VK_KHR_FRAGMENT_SHADING_RATE_EXTENSION_NAME);
    CHAIN(fas, VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME);
    CHAIN(frt, VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME);
    CHAIN(frq, VK_KHR_RAY_QUERY_EXTENSION_NAME);
    CHAIN(fgpl, VK_EXT_GRAPHICS_PIPELINE_LIBRARY_EXTENSION_NAME);
    CHAIN(fcr, VK_EXT_CONDITIONAL_RENDERING_EXTENSION_NAME);
    CHAIN(fia64, VK_EXT_SHADER_IMAGE_ATOMIC_INT64_EXTENSION_NAME);
    if (has_ext(VK_KHR_LINE_RASTERIZATION_EXTENSION_NAME) || has_ext(VK_EXT_LINE_RASTERIZATION_EXTENSION_NAME))
        CHAIN(flr, NULL);
    CHAIN(fdbc, VK_EXT_DEPTH_BIAS_CONTROL_EXTENSION_NAME);
    f2.pNext = next;
    vkGetPhysicalDeviceFeatures2(pd, &f2);
    const VkPhysicalDeviceFeatures *f = &f2.features;

    P("feat.div.vertexAttributeInstanceRateDivisor [hard]", fdiv.vertexAttributeInstanceRateDivisor);
    P("feat.div.vertexAttributeInstanceRateZeroDivisor [hard]", fdiv.vertexAttributeInstanceRateZeroDivisor);
    P("feat.12.samplerMirrorClampToEdge [hard]", f12.samplerMirrorClampToEdge);
    P("feat.rob2.robustBufferAccess2 [hard]", frob2.robustBufferAccess2);
    P("feat.rob2.robustImageAccess2 [hard]", frob2.robustImageAccess2);
    P("feat.rob2.nullDescriptor [hard]", frob2.nullDescriptor);
    P("feat.11.shaderDrawParameters [hard]", f11.shaderDrawParameters);
    P("feat.14.pushDescriptor (or KHR_push_descriptor) [hard]", f14.pushDescriptor || has_ext(VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME));
    P("feat.m5.maintenance5 [hard]", fm5.maintenance5 || f14.maintenance5);
    P("feat.m6.maintenance6 [hard]", fm6.maintenance6 || f14.maintenance6);
    P("feat.drua.dynamicRenderingUnusedAttachments [warn: required for correctness]", fdrua.dynamicRenderingUnusedAttachments);
    P("feat.xfb.transformFeedback", fxfb.transformFeedback);
    P("feat.xfb.geometryStreams", fxfb.geometryStreams);
    P("feat.13.dynamicRendering", f13.dynamicRendering);
    P("feat.13.synchronization2", f13.synchronization2);
    P("feat.12.timelineSemaphore", f12.timelineSemaphore);
    P("feat.12.bufferDeviceAddress", f12.bufferDeviceAddress);
    P("feat.12.descriptorIndexing", f12.descriptorIndexing);
    P("feat.12.runtimeDescriptorArray", f12.runtimeDescriptorArray);
    P("feat.12.descriptorBindingPartiallyBound", f12.descriptorBindingPartiallyBound);
    P("feat.12.descriptorBindingVariableDescriptorCount", f12.descriptorBindingVariableDescriptorCount);
    P("feat.12.descriptorBindingUpdateUnusedWhilePending", f12.descriptorBindingUpdateUnusedWhilePending);
    P("feat.12.descriptorBindingSampledImageUpdateAfterBind", f12.descriptorBindingSampledImageUpdateAfterBind);
    P("feat.12.descriptorBindingStorageImageUpdateAfterBind", f12.descriptorBindingStorageImageUpdateAfterBind);
    P("feat.12.descriptorBindingStorageBufferUpdateAfterBind", f12.descriptorBindingStorageBufferUpdateAfterBind);
    P("feat.12.descriptorBindingUniformTexelBufferUpdateAfterBind", f12.descriptorBindingUniformTexelBufferUpdateAfterBind);
    P("feat.12.descriptorBindingStorageTexelBufferUpdateAfterBind", f12.descriptorBindingStorageTexelBufferUpdateAfterBind);
    P("feat.12.shaderSampledImageArrayNonUniformIndexing", f12.shaderSampledImageArrayNonUniformIndexing);
    P("feat.12.shaderStorageBufferArrayNonUniformIndexing", f12.shaderStorageBufferArrayNonUniformIndexing);
    P("feat.12.shaderStorageImageArrayNonUniformIndexing", f12.shaderStorageImageArrayNonUniformIndexing);
    P("feat.12.scalarBlockLayout [SM6.0]", f12.scalarBlockLayout);
    P("feat.12.uniformBufferStandardLayout [SM6.0 alt]", f12.uniformBufferStandardLayout);
    P("feat.12.shaderFloat16", f12.shaderFloat16);
    P("feat.12.shaderInt8 [SM6.6]", f12.shaderInt8);
    P("feat.12.shaderBufferInt64Atomics [SM6.6]", f12.shaderBufferInt64Atomics);
    P("feat.12.vulkanMemoryModel", f12.vulkanMemoryModel);
    P("feat.12.hostQueryReset", f12.hostQueryReset);
    P("feat.12.samplerFilterMinmax", f12.samplerFilterMinmax);
    P("feat.12.separateDepthStencilLayouts", f12.separateDepthStencilLayouts);
    P("feat.12.storageBuffer8BitAccess", f12.storageBuffer8BitAccess);
    P("feat.11.storageBuffer16BitAccess", f11.storageBuffer16BitAccess);
    P("feat.11.multiview", f11.multiview);
    P("feat.13.subgroupSizeControl", f13.subgroupSizeControl);
    P("feat.13.computeFullSubgroups", f13.computeFullSubgroups);
    P("feat.13.shaderDemoteToHelperInvocation", f13.shaderDemoteToHelperInvocation);
    P("feat.13.shaderIntegerDotProduct", f13.shaderIntegerDotProduct);
    P("feat.13.maintenance4", f13.maintenance4);
    P("feat.robustBufferAccess", f->robustBufferAccess);
    P("feat.geometryShader", f->geometryShader);
    P("feat.tessellationShader", f->tessellationShader);
    P("feat.dualSrcBlend", f->dualSrcBlend);
    P("feat.logicOp [FL11.1]", f->logicOp);
    P("feat.multiDrawIndirect", f->multiDrawIndirect);
    P("feat.drawIndirectFirstInstance", f->drawIndirectFirstInstance);
    P("feat.depthClamp", f->depthClamp);
    P("feat.depthBiasClamp", f->depthBiasClamp);
    P("feat.fillModeNonSolid", f->fillModeNonSolid);
    P("feat.depthBounds [FL12.2]", f->depthBounds);
    P("feat.multiViewport", f->multiViewport);
    P("feat.samplerAnisotropy", f->samplerAnisotropy);
    P("feat.textureCompressionBC", f->textureCompressionBC);
    P("feat.occlusionQueryPrecise", f->occlusionQueryPrecise);
    P("feat.pipelineStatisticsQuery", f->pipelineStatisticsQuery);
    P("feat.vertexPipelineStoresAndAtomics [FL11.1]", f->vertexPipelineStoresAndAtomics);
    P("feat.fragmentStoresAndAtomics", f->fragmentStoresAndAtomics);
    P("feat.shaderImageGatherExtended", f->shaderImageGatherExtended);
    P("feat.shaderStorageImageExtendedFormats", f->shaderStorageImageExtendedFormats);
    P("feat.shaderStorageImageReadWithoutFormat [typed UAV loads]", f->shaderStorageImageReadWithoutFormat);
    P("feat.shaderStorageImageWriteWithoutFormat", f->shaderStorageImageWriteWithoutFormat);
    P("feat.shaderClipDistance", f->shaderClipDistance);
    P("feat.shaderCullDistance", f->shaderCullDistance);
    P("feat.shaderFloat64", f->shaderFloat64);
    P("feat.shaderInt64", f->shaderInt64);
    P("feat.shaderInt16 [SM6.0]", f->shaderInt16);
    P("feat.shaderResourceMinLod", f->shaderResourceMinLod);
    P("feat.sparseBinding", f->sparseBinding);
    P("feat.sparseResidencyBuffer [tiled resources]", f->sparseResidencyBuffer);
    P("feat.sparseResidencyImage2D [tiled resources]", f->sparseResidencyImage2D);
    P("feat.sparseResidencyImage3D", f->sparseResidencyImage3D);
    P("feat.sparseResidencyAliased", f->sparseResidencyAliased);
    P("feat.variableMultisampleRate", f->variableMultisampleRate);
    P("feat.independentBlend", f->independentBlend);
    P("feat.sampleRateShading", f->sampleRateShading);
    P("feat.mut.mutableDescriptorType", fmut.mutableDescriptorType);
    P("feat.db.descriptorBuffer", fdb.descriptorBuffer);
    P("feat.db.descriptorBufferPushDescriptors", fdb.descriptorBufferPushDescriptors);
    P("feat.rov.fragmentShaderPixelInterlock [ROV, FL12.1]", frov.fragmentShaderPixelInterlock);
    P("feat.rov.fragmentShaderSampleInterlock", frov.fragmentShaderSampleInterlock);
    P("feat.csd.computeDerivativeGroupLinear [SM6.6]", fcsd.computeDerivativeGroupLinear);
    P("feat.csd.computeDerivativeGroupQuads", fcsd.computeDerivativeGroupQuads);
    P("feat.mr.shaderMaximalReconvergence [SM6.7]", fmr.shaderMaximalReconvergence);
    P("feat.qc.shaderQuadControl [SM6.7]", fqc.shaderQuadControl);
    P("feat.dce.depthClipEnable", fdce.depthClipEnable);
    P("feat.eds2.extendedDynamicState2", feds2.extendedDynamicState2);
    P("feat.eds2.extendedDynamicState2PatchControlPoints", feds2.extendedDynamicState2PatchControlPoints);
    P("feat.eds3.extendedDynamicState3RasterizationSamples", feds3.extendedDynamicState3RasterizationSamples);
    P("feat.eds3.extendedDynamicState3AlphaToCoverageEnable", feds3.extendedDynamicState3AlphaToCoverageEnable);
    P("feat.eds3.extendedDynamicState3SampleMask", feds3.extendedDynamicState3SampleMask);
    P("feat.eds3.extendedDynamicState3DepthClipEnable", feds3.extendedDynamicState3DepthClipEnable);
    P("feat.cbc.customBorderColors", fcbc.customBorderColors);
    P("feat.cbc.customBorderColorWithoutFormat", fcbc.customBorderColorWithoutFormat);
    P("feat.mesh.meshShader", fmesh.meshShader);
    P("feat.mesh.taskShader", fmesh.taskShader);
    P("feat.vrs.pipelineFragmentShadingRate", fvrs.pipelineFragmentShadingRate);
    P("feat.vrs.attachmentFragmentShadingRate", fvrs.attachmentFragmentShadingRate);
    P("feat.as.accelerationStructure", fas.accelerationStructure);
    P("feat.rt.rayTracingPipeline", frt.rayTracingPipeline);
    P("feat.rq.rayQuery", frq.rayQuery);
    P("feat.gpl.graphicsPipelineLibrary", fgpl.graphicsPipelineLibrary);
    P("feat.cr.conditionalRendering", fcr.conditionalRendering);
    P("feat.ia64.shaderImageInt64Atomics", fia64.shaderImageInt64Atomics);
    P("feat.lr.rectangularLines", flr.rectangularLines);
    P("feat.lr.smoothLines", flr.smoothLines);
    P("feat.dbc.depthBiasControl", fdbc.depthBiasControl);

    for (uint32_t i = 0; i < ext_count; i++)
        printf("ext %s %u\n", exts[i].extensionName, exts[i].specVersion);

    vkDestroyInstance(inst, NULL);
    return 0;
}
