/* S8 spike: print the D3D12 caps vkd3d-proton reports on the current Vulkan
 * driver (feature level, shader model, tiers). */
#define INITGUID
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <vkd3d_windows.h>
#include <vkd3d_d3d12.h>
#include <stdio.h>
#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof(*(x)))
#endif

int main(void)
{
    static const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2 };
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = { ARRAY_SIZE(levels), levels, 0 };
    D3D12_FEATURE_DATA_SHADER_MODEL sm = { D3D_SHADER_MODEL_6_9 };
    D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS1 o1 = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS6 o6 = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS7 o7 = {0};
    ID3D12Device *device;
    HRESULT hr;

    if (FAILED(hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device)))
    {
        printf("D3D12CreateDevice failed: hr %#x\n", (unsigned int)hr);
        return 1;
    }
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof(o));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS1, &o1, sizeof(o1));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS6, &o6, sizeof(o6));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS7, &o7, sizeof(o7));
    printf("MaxSupportedFeatureLevel        %#x\n", fl.MaxSupportedFeatureLevel);
    printf("HighestShaderModel              %#x\n", sm.HighestShaderModel);
    printf("ResourceBindingTier             %d\n", o.ResourceBindingTier);
    printf("TiledResourcesTier              %d\n", o.TiledResourcesTier);
    printf("ConservativeRasterizationTier   %d\n", o.ConservativeRasterizationTier);
    printf("ROVsSupported                   %d\n", o.ROVsSupported);
    printf("OutputMergerLogicOp             %d\n", o.OutputMergerLogicOp);
    printf("TypedUAVLoadAdditionalFormats   %d\n", o.TypedUAVLoadAdditionalFormats);
    printf("DoublePrecisionFloatShaderOps   %d\n", o.DoublePrecisionFloatShaderOps);
    printf("VPAndRTArrayIndexWithoutGS      %d\n", o.VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation);
    printf("WaveOps                         %d\n", o1.WaveOps);
    printf("Int64ShaderOps                  %d\n", o1.Int64ShaderOps);
    printf("RaytracingTier                  %d\n", o5.RaytracingTier);
    printf("VariableShadingRateTier         %d\n", o6.VariableShadingRateTier);
    printf("MeshShaderTier                  %d\n", o7.MeshShaderTier);
    printf("SamplerFeedbackTier             %d\n", o7.SamplerFeedbackTier);
    ID3D12Device_Release(device);
    return 0;
}
