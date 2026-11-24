/*
 * Seemless WP7.5 host test for the D3D12 backend (docs/04 ladder, host side).
 *
 * Loads the D3D12 library the way Neptune does (dlopen + dlsym
 * "D3D12CreateDevice", plain calling convention on macOS arm64) and runs:
 *
 *   rung 1  D3D12CreateDevice; report feature level and shader model.
 *   rung 2  Clear a 64x64 RGBA8 render target, copy it to a readback buffer
 *           and check the texels. The fence completion is signalled into a
 *           directx-native event created by THIS binary's own copy of
 *           directx-native, as Neptune's events come from DXMT's copy.
 *   rung 3  Triangle with signed DXIL shaders, read back and hashed
 *           (guest/tools/d3d12test/ladder_rung3.h, shared with the guest
 *           test): the host reference for the guest's frame.
 *
 * Usage: d3d12hosttest [path/to/libvkd3d-proton-d3d12.dylib]
 *        (default: $NPT_D3D12_LIBRARY_PATH)
 * Exit status 0 when every rung passes. Build: scripts/d3d12-host/build.sh.
 */
#define COBJMACROS
#define INITGUID
#define WIDL_C_INLINE_WRAPPERS
#include <vkd3d_windows.h>
#include <vkd3d_d3d12.h>
#include <directx-native/dxn_event.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

typedef HRESULT (*PFN_create_device)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)

#include "ladder_rung3.h"

static int rung3_wait(ID3D12Fence *fence, UINT64 value)
{
    void *event = dxn_event_create(1, 0);
    int ok = event && SUCCEEDED(ID3D12Fence_SetEventOnCompletion(fence, value, event))
            && dxn_event_wait(event, 10ull * 1000000000ull) == DXN_WAIT_SIGNALED;
    if (event) dxn_event_close(event);
    return ok;
}

static void rung3_report(const struct rung3_result *r, const char *kind)
{
    if (FAILED(r->hr))
    {
        printf("FAIL: rung3 %s %s hr %#x\n", kind, r->failed_step, (unsigned)r->hr);
        failures++;
        return;
    }
    printf("rung3: triangle (%s VS+PS) covered %u px, centre (%u,%u,%u,%u), corner (%u,%u,%u,%u), fnv1a %08x\n",
            kind, r->covered, r->centre[0], r->centre[1], r->centre[2], r->centre[3],
            r->corner[0], r->corner[1], r->corner[2], r->corner[3], r->fnv1a);
    CHECK(r->covered > 1000 && r->covered < 3000, "rung3 coverage %u out of range", r->covered);
    CHECK(r->corner[0] == 0 && r->corner[1] == 0 && r->corner[2] == 0, "rung3 corner not clear colour");
}

static const char *fl_name(D3D_FEATURE_LEVEL fl)
{
    switch (fl)
    {
        case D3D_FEATURE_LEVEL_11_0: return "11_0";
        case D3D_FEATURE_LEVEL_11_1: return "11_1";
        case D3D_FEATURE_LEVEL_12_0: return "12_0";
        case D3D_FEATURE_LEVEL_12_1: return "12_1";
        case D3D_FEATURE_LEVEL_12_2: return "12_2";
        default: return "?";
    }
}

static void rung1_caps(ID3D12Device *device)
{
    static const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_12_0,
        D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2,
    };
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = { ARRAY_SIZE(levels), levels, 0 };
    D3D12_FEATURE_DATA_SHADER_MODEL sm = { D3D_SHADER_MODEL_6_7 };
    D3D12_FEATURE_DATA_D3D12_OPTIONS opts;
    HRESULT hr;
    LUID luid;

    hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
    CHECK(SUCCEEDED(hr), "CheckFeatureSupport(FEATURE_LEVELS) hr %#x", (unsigned)hr);
    hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm));
    CHECK(SUCCEEDED(hr), "CheckFeatureSupport(SHADER_MODEL) hr %#x", (unsigned)hr);
    memset(&opts, 0, sizeof(opts));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS, &opts, sizeof(opts));
    luid = ID3D12Device_GetAdapterLuid(device);

    printf("rung1: max feature level %s, highest shader model %u.%u, resource binding tier %u, "
            "tiled resources tier %u, adapter LUID %08x:%08x\n",
            fl_name(fl.MaxSupportedFeatureLevel), sm.HighestShaderModel >> 4, sm.HighestShaderModel & 0xf,
            opts.ResourceBindingTier, opts.TiledResourcesTier,
            (unsigned)luid.HighPart, (unsigned)luid.LowPart);
}

static void rung2_clear_readback(ID3D12Device *device)
{
    enum { W = 64, H = 64 };
    static const float color[4] = { 0.25f, 0.5f, 0.75f, 1.0f };
    const uint8_t expect[4] = { 64, 128, 191, 255 };
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    D3D12_TEXTURE_COPY_LOCATION dst_loc, src_loc;
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    D3D12_COMMAND_QUEUE_DESC queue_desc;
    D3D12_HEAP_PROPERTIES heap_props;
    D3D12_RESOURCE_BARRIER barrier;
    D3D12_RESOURCE_DESC desc;
    ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList *list;
    ID3D12DescriptorHeap *rtv_heap;
    ID3D12Resource *rt, *readback;
    ID3D12CommandQueue *queue;
    ID3D12Fence *fence;
    unsigned int bad = 0, x, y, c;
    UINT64 total;
    void *event;
    uint8_t *data;
    HRESULT hr;

    memset(&queue_desc, 0, sizeof(queue_desc));
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    hr = ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue);
    CHECK(SUCCEEDED(hr), "CreateCommandQueue hr %#x", (unsigned)hr);
    if (FAILED(hr)) return;
    hr = ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
            &IID_ID3D12CommandAllocator, (void **)&allocator);
    CHECK(SUCCEEDED(hr), "CreateCommandAllocator hr %#x", (unsigned)hr);
    hr = ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
            &IID_ID3D12GraphicsCommandList, (void **)&list);
    CHECK(SUCCEEDED(hr), "CreateCommandList hr %#x", (unsigned)hr);

    memset(&heap_props, 0, sizeof(heap_props));
    heap_props.Type = D3D12_HEAP_TYPE_DEFAULT;
    memset(&desc, 0, sizeof(desc));
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = W;
    desc.Height = H;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    hr = ID3D12Device_CreateCommittedResource(device, &heap_props, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_RENDER_TARGET, NULL, &IID_ID3D12Resource, (void **)&rt);
    CHECK(SUCCEEDED(hr), "CreateCommittedResource(rt) hr %#x", (unsigned)hr);

    ID3D12Device_GetCopyableFootprints(device, &desc, 0, 1, 0, &footprint, NULL, NULL, &total);
    heap_props.Type = D3D12_HEAP_TYPE_READBACK;
    memset(&desc, 0, sizeof(desc));
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = total;
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    hr = ID3D12Device_CreateCommittedResource(device, &heap_props, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback);
    CHECK(SUCCEEDED(hr), "CreateCommittedResource(readback) hr %#x", (unsigned)hr);

    memset(&heap_desc, 0, sizeof(heap_desc));
    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap_desc.NumDescriptors = 1;
    hr = ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap);
    CHECK(SUCCEEDED(hr), "CreateDescriptorHeap hr %#x", (unsigned)hr);
    if (failures) return;
    rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap);
    ID3D12Device_CreateRenderTargetView(device, rt, NULL, rtv);

    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, color, 0, NULL);
    memset(&barrier, 0, sizeof(barrier));
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = rt;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
    dst_loc.pResource = readback;
    dst_loc.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst_loc.PlacedFootprint = footprint;
    src_loc.pResource = rt;
    src_loc.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src_loc.SubresourceIndex = 0;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst_loc, 0, 0, 0, &src_loc, NULL);
    hr = ID3D12GraphicsCommandList_Close(list);
    CHECK(SUCCEEDED(hr), "Close hr %#x", (unsigned)hr);
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);

    hr = ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    CHECK(SUCCEEDED(hr), "CreateFence hr %#x", (unsigned)hr);
    hr = ID3D12CommandQueue_Signal(queue, fence, 1);
    CHECK(SUCCEEDED(hr), "Signal hr %#x", (unsigned)hr);
    /* Manual-reset, like Neptune's guest-HANDLE proxies (npt_event.c). */
    event = dxn_event_create(1, 0);
    CHECK(event != NULL, "dxn_event_create");
    hr = ID3D12Fence_SetEventOnCompletion(fence, 1, event);
    CHECK(SUCCEEDED(hr), "SetEventOnCompletion hr %#x", (unsigned)hr);
    CHECK(dxn_event_wait(event, 10ull * 1000000000ull) == DXN_WAIT_SIGNALED,
            "fence event not signalled within 10 s (completed value %llu)",
            (unsigned long long)ID3D12Fence_GetCompletedValue(fence));
    dxn_event_close(event);

    hr = ID3D12Resource_Map(readback, 0, NULL, (void **)&data);
    CHECK(SUCCEEDED(hr), "Map hr %#x", (unsigned)hr);
    if (SUCCEEDED(hr))
    {
        for (y = 0; y < H; y++)
            for (x = 0; x < W; x++)
                for (c = 0; c < 4; c++)
                {
                    uint8_t v = data[footprint.Offset + y * footprint.Footprint.RowPitch + x * 4 + c];
                    if (abs((int)v - (int)expect[c]) > 1 && bad++ < 4)
                        printf("  texel (%u,%u)[%u] = %u, expected %u\n", x, y, c, v, expect[c]);
                }
        printf("rung2: clear %ux%u to (%.2f,%.2f,%.2f,%.2f), read back texel (0,0) = (%u,%u,%u,%u), %u bad channels\n",
                W, H, color[0], color[1], color[2], color[3],
                data[footprint.Offset], data[footprint.Offset + 1], data[footprint.Offset + 2],
                data[footprint.Offset + 3], bad);
        CHECK(bad == 0, "%u channels differ", bad);
        ID3D12Resource_Unmap(readback, 0, NULL);
    }

    ID3D12Fence_Release(fence);
    ID3D12DescriptorHeap_Release(rtv_heap);
    ID3D12Resource_Release(readback);
    ID3D12Resource_Release(rt);
    ID3D12GraphicsCommandList_Release(list);
    ID3D12CommandAllocator_Release(allocator);
    ID3D12CommandQueue_Release(queue);
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : getenv("NPT_D3D12_LIBRARY_PATH");
    PFN_create_device create_device;
    ID3D12Device *device = NULL;
    void *module;
    HRESULT hr;

    if (!path)
    {
        fprintf(stderr, "usage: %s <libvkd3d-proton-d3d12.dylib> (or set NPT_D3D12_LIBRARY_PATH)\n", argv[0]);
        return 2;
    }
    if (!(module = dlopen(path, RTLD_NOW | RTLD_LOCAL)))
    {
        printf("FAIL: dlopen %s: %s\n", path, dlerror());
        return 1;
    }
    if (!(create_device = (PFN_create_device)dlsym(module, "D3D12CreateDevice")))
    {
        printf("FAIL: D3D12CreateDevice not exported by %s\n", path);
        return 1;
    }
    printf("loaded %s\n", path);

    hr = create_device(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device);
    printf("rung1: D3D12CreateDevice(NULL, 11_0) hr %#x, device %p\n", (unsigned)hr, (void *)device);
    if (FAILED(hr) || !device)
    {
        printf("FAIL: no device\n");
        return 1;
    }
    rung1_caps(device);
    rung2_clear_readback(device);
    {
        static unsigned char pixels[64 * 64 * 4];
        const char *ppm = getenv("RUNG3_PPM");
        struct rung3_result r3;
        PFN_rung3_serialize serialize = (PFN_rung3_serialize)dlsym(module, "D3D12SerializeRootSignature");
        CHECK(serialize != NULL, "D3D12SerializeRootSignature not exported");
        if (serialize)
        {
            unsigned int dxbc_hash;

            r3.pixels = NULL;
            rung3_triangle(device, serialize, 0, &r3);
            rung3_report(&r3, "DXBC");
            dxbc_hash = r3.fnv1a;
            r3.pixels = pixels;
            rung3_triangle(device, serialize, 1, &r3);
            rung3_report(&r3, "DXIL");
            CHECK(r3.fnv1a == dxbc_hash, "rung3 DXIL and DXBC frames differ");
            if (ppm && SUCCEEDED(r3.hr))
            {
                /* RUNG3_PPM=<file>: the frame as a binary PPM, for looking at. */
                FILE *f = fopen(ppm, "wb");
                unsigned int i;
                if (f)
                {
                    fprintf(f, "P6 64 64 255\n");
                    for (i = 0; i < 64 * 64; i++) fwrite(pixels + i * 4, 1, 3, f);
                    fclose(f);
                }
            }
        }
    }
    printf("device refcount after release: %u\n", (unsigned)ID3D12Device_Release(device));

    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
