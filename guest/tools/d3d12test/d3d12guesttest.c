/*
 * Seemless WP7.5 guest test: the docs/04 D3D12 ladder inside Windows.
 *
 * A freestanding Windows ARM64 console program (no CRT, no Microsoft SDK):
 * D3D12 types come from vkd3d-proton's headers, imports from our own .def
 * files. Build on the Mac with guest/tools/d3d12test/build.sh.
 *
 *   rung 1  List DXGI adapters; D3D12CreateDevice on the first hardware
 *           adapter; report feature level and shader model.
 *   rung 2  Clear a 64x64 RGBA8 render target, copy to a readback buffer,
 *           check the texels. The fence wait uses a Win32 event, which
 *           Neptune turns into a host event signalled by vkd3d-proton.
 *   rung 3  Triangle (ladder_rung3.h, shared with the host test), once with
 *           DXBC and once with signed DXIL shaders from the same HLSL; each
 *           frame's fnv1a must equal the host reference.
 *
 * Prints one line per result and "PASSED"/"FAILED" last; the exit code is
 * the failure count. Run from cmd: d3d12guesttest.exe
 */
#define COBJMACROS
#define INITGUID
#define WIDL_C_INLINE_WRAPPERS
#include <vkd3d_windows.h>
#include <vkd3d_d3d12.h>
#include <vkd3d_dxgi1_4.h>

/* Windows ABI (LLP64) layouts the shadowed vkd3d_windows.h must produce. */
_Static_assert(sizeof(SIZE_T) == 8 && sizeof(LONG) == 4 && sizeof(UINT64) == 8, "LLP64 types");
_Static_assert(sizeof(GUID) == 16, "GUID");
_Static_assert(sizeof(D3D12_CPU_DESCRIPTOR_HANDLE) == 8, "CPU descriptor handle");
_Static_assert(sizeof(DXGI_ADAPTER_DESC) == 304, "DXGI_ADAPTER_DESC");
_Static_assert(sizeof(D3D12_RESOURCE_DESC) == 56, "D3D12_RESOURCE_DESC");
_Static_assert(sizeof(D3D12_PLACED_SUBRESOURCE_FOOTPRINT) == 32, "footprint");

/* Host reference for rung 3: d3d12hosttest's fnv1a on the same backend
 * (vkd3d-proton + MoltenVK, Apple M3), 2026-11-24; DXBC and DXIL agree. */
#ifndef RUNG3_HOST_FNV1A
#define RUNG3_HOST_FNV1A 0xaf00704du
#endif

/* ---- the few kernel32 calls we need (kernel32.def) ---- */
#define STD_OUTPUT_HANDLE ((unsigned int)-11)
#define INFINITE_WAIT 0xffffffffu
__declspec(dllimport) HANDLE __stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void *, unsigned int, unsigned int *, void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
__declspec(dllimport) HANDLE __stdcall CreateEventA(void *, int, int, const char *);
__declspec(dllimport) unsigned int __stdcall WaitForSingleObject(HANDLE, unsigned int);
__declspec(dllimport) int __stdcall CloseHandle(HANDLE);
/* D3D12CreateDevice and CreateDXGIFactory1 are declared by the headers; the
 * import libraries (d3d12.def, dxgi.def) provide their thunks. */

/* Compiler-emitted helpers (no CRT). */
void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }
int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = a, *q = b;
    for (; n; n--, p++, q++) if (*p != *q) return *p - *q;
    return 0;
}

/* ---- output ---- */
static HANDLE out;
static int failures;

static void puts_(const char *s)
{
    unsigned int n = 0, w;
    while (s[n]) n++;
    WriteFile(out, s, n, &w, NULL);
}

static void putu(unsigned long long v, unsigned int base)
{
    char buf[24];
    int i = sizeof(buf) - 1;
    buf[i] = 0;
    do { buf[--i] = "0123456789abcdef"[v % base]; v /= base; } while (v && i);
    if (base == 16) { buf[--i] = 'x'; buf[--i] = '0'; }
    puts_(buf + i);
}

static void putw(const WCHAR *s)
{
    char buf[130];
    int i;
    for (i = 0; i < 128 && s[i]; i++) buf[i] = s[i] < 128 ? (char)s[i] : '?';
    buf[i] = 0;
    puts_(buf);
}

static void check(int ok, const char *what, HRESULT hr)
{
    if (ok) return;
    failures++;
    puts_("FAIL: "); puts_(what); puts_(" hr "); putu((unsigned int)hr, 16); puts_("\r\n");
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

/* ---- rung 3 (shared code) ---- */
#include "ladder_rung3.h"

static int rung3_wait(ID3D12Fence *fence, UINT64 value)
{
    HANDLE event = CreateEventA(NULL, FALSE, FALSE, NULL);
    int ok = event && SUCCEEDED(ID3D12Fence_SetEventOnCompletion(fence, value, event))
            && WaitForSingleObject(event, 10000) == 0;
    if (event) CloseHandle(event);
    return ok;
}

static void rung3(ID3D12Device *device, int use_dxil)
{
    struct rung3_result r;
    const char *kind = use_dxil ? "DXIL" : "DXBC";

    r.pixels = NULL;
    rung3_triangle(device, (PFN_rung3_serialize)D3D12SerializeRootSignature, use_dxil, &r);
    if (FAILED(r.hr))
    {
        puts_("rung3: "); puts_(kind); puts_(" failed at "); puts_(r.failed_step); puts_("\r\n");
        check(0, use_dxil ? "rung3 DXIL" : "rung3 DXBC", r.hr);
        return;
    }
    puts_("rung3: triangle ("); puts_(kind); puts_(" VS+PS) covered "); putu(r.covered, 10);
    puts_(" px, centre ("); putu(r.centre[0], 10); puts_(","); putu(r.centre[1], 10); puts_(",");
    putu(r.centre[2], 10); puts_(","); putu(r.centre[3], 10); puts_("), corner (");
    putu(r.corner[0], 10); puts_(","); putu(r.corner[1], 10); puts_(","); putu(r.corner[2], 10); puts_(",");
    putu(r.corner[3], 10); puts_("), fnv1a "); putu(r.fnv1a, 16);
    puts_(r.fnv1a == RUNG3_HOST_FNV1A ? " = host reference\r\n" : " DIFFERS from host reference\r\n");
    check(r.fnv1a == RUNG3_HOST_FNV1A, "rung3 image differs from the host reference", 0);
}

/* ---- rung 1 ---- */
/* First adapter that is not Microsoft's software one (vendor 0x1414,
 * device 0x8c: Basic Render Driver / WARP). */
static IDXGIAdapter *pick_adapter(void)
{
    IDXGIAdapter *adapter, *chosen = NULL;
    IDXGIFactory1 *factory;
    DXGI_ADAPTER_DESC desc;
    unsigned int i;
    HRESULT hr;

    hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    check(SUCCEEDED(hr), "CreateDXGIFactory1", hr);
    if (FAILED(hr)) return NULL;
    for (i = 0; IDXGIFactory1_EnumAdapters(factory, i, &adapter) == S_OK; i++)
    {
        IDXGIAdapter_GetDesc(adapter, &desc);
        puts_("adapter "); putu(i, 10); puts_(": "); putw(desc.Description);
        puts_(" vendor "); putu(desc.VendorId, 16); puts_(" device "); putu(desc.DeviceId, 16);
        puts_(" vram "); putu(desc.DedicatedVideoMemory >> 20, 10); puts_(" MiB\r\n");
        if (!chosen && !(desc.VendorId == 0x1414 && desc.DeviceId == 0x8c))
            chosen = adapter;
        else
            IDXGIAdapter_Release(adapter);
    }
    IDXGIFactory1_Release(factory);
    return chosen;
}

static void rung1_caps(ID3D12Device *device)
{
    static const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_12_0,
        D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2,
    };
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl;
    D3D12_FEATURE_DATA_SHADER_MODEL sm;
    D3D12_FEATURE_DATA_D3D12_OPTIONS opts;
    HRESULT hr;

    fl.NumFeatureLevels = sizeof(levels) / sizeof(levels[0]);
    fl.pFeatureLevelsRequested = levels;
    fl.MaxSupportedFeatureLevel = 0;
    hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
    check(SUCCEEDED(hr), "CheckFeatureSupport(FEATURE_LEVELS)", hr);
    sm.HighestShaderModel = D3D_SHADER_MODEL_6_7;
    hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm));
    check(SUCCEEDED(hr), "CheckFeatureSupport(SHADER_MODEL)", hr);
    memset(&opts, 0, sizeof(opts));
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS, &opts, sizeof(opts));

    puts_("rung1: max feature level "); puts_(fl_name(fl.MaxSupportedFeatureLevel));
    puts_(", highest shader model "); putu(sm.HighestShaderModel >> 4, 10); puts_(".");
    putu(sm.HighestShaderModel & 0xf, 10);
    puts_(", resource binding tier "); putu(opts.ResourceBindingTier, 10);
    puts_(", tiled resources tier "); putu(opts.TiledResourcesTier, 10); puts_("\r\n");
}

/* ---- rung 2 ---- */
static void rung2_clear_readback(ID3D12Device *device)
{
    enum { W = 64, H = 64 };
    static const float color[4] = { 0.25f, 0.5f, 0.75f, 1.0f };
    static const unsigned char expect[4] = { 64, 128, 191, 255 };
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    D3D12_TEXTURE_COPY_LOCATION dst_loc, src_loc;
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    D3D12_COMMAND_QUEUE_DESC queue_desc;
    D3D12_HEAP_PROPERTIES heap_props;
    D3D12_RESOURCE_BARRIER barrier;
    D3D12_RESOURCE_DESC desc;
    ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    ID3D12DescriptorHeap *rtv_heap = NULL;
    ID3D12Resource *rt = NULL, *readback = NULL;
    ID3D12CommandQueue *queue = NULL;
    ID3D12Fence *fence = NULL;
    unsigned int bad = 0, x, y, c, wait;
    unsigned char *data;
    UINT64 total;
    HANDLE event;
    HRESULT hr;
    int before = failures;

    memset(&queue_desc, 0, sizeof(queue_desc));
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    hr = ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue);
    check(SUCCEEDED(hr), "CreateCommandQueue", hr);
    hr = ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
            &IID_ID3D12CommandAllocator, (void **)&allocator);
    check(SUCCEEDED(hr), "CreateCommandAllocator", hr);
    if (failures != before) return;
    hr = ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
            &IID_ID3D12GraphicsCommandList, (void **)&list);
    check(SUCCEEDED(hr), "CreateCommandList", hr);

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
    check(SUCCEEDED(hr), "CreateCommittedResource(rt)", hr);

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
    check(SUCCEEDED(hr), "CreateCommittedResource(readback)", hr);

    memset(&heap_desc, 0, sizeof(heap_desc));
    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap_desc.NumDescriptors = 1;
    hr = ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap);
    check(SUCCEEDED(hr), "CreateDescriptorHeap", hr);
    if (failures != before) return;
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
    check(SUCCEEDED(hr), "Close", hr);
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);

    hr = ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    check(SUCCEEDED(hr), "CreateFence", hr);
    if (failures != before) return;
    hr = ID3D12CommandQueue_Signal(queue, fence, 1);
    check(SUCCEEDED(hr), "Signal", hr);
    event = CreateEventA(NULL, FALSE, FALSE, NULL);
    hr = ID3D12Fence_SetEventOnCompletion(fence, 1, event);
    check(SUCCEEDED(hr), "SetEventOnCompletion", hr);
    wait = WaitForSingleObject(event, 10000);
    puts_("rung2: fence event wait "); puts_(wait == 0 ? "signalled" : "TIMED OUT");
    puts_(", completed value "); putu(ID3D12Fence_GetCompletedValue(fence), 10); puts_("\r\n");
    check(wait == 0, "fence event not signalled within 10 s", 0);
    CloseHandle(event);

    hr = ID3D12Resource_Map(readback, 0, NULL, (void **)&data);
    check(SUCCEEDED(hr), "Map", hr);
    if (SUCCEEDED(hr))
    {
        for (y = 0; y < H; y++)
            for (x = 0; x < W; x++)
                for (c = 0; c < 4; c++)
                {
                    int v = data[footprint.Offset + y * footprint.Footprint.RowPitch + x * 4 + c] - expect[c];
                    if (v < -1 || v > 1) bad++;
                }
        data += footprint.Offset;
        puts_("rung2: clear 64x64 to (0.25,0.50,0.75,1.00), read back texel (0,0) = (");
        putu(data[0], 10); puts_(","); putu(data[1], 10); puts_(","); putu(data[2], 10); puts_(",");
        putu(data[3], 10); puts_("), "); putu(bad, 10); puts_(" bad channels\r\n");
        check(bad == 0, "clear readback mismatch", 0);
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

void start(void)
{
    ID3D12Device *device = NULL;
    IDXGIAdapter *adapter;
    HRESULT hr;

    out = GetStdHandle(STD_OUTPUT_HANDLE);
    puts_("Seemless d3d12guesttest (WP7.5)\r\n");
    adapter = pick_adapter();
    hr = D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device);
    puts_("rung1: D3D12CreateDevice(adapter, 11_0) hr "); putu((unsigned int)hr, 16); puts_("\r\n");
    check(SUCCEEDED(hr) && device, "D3D12CreateDevice", hr);
    if (device)
    {
        rung1_caps(device);
        rung2_clear_readback(device);
        rung3(device, 0);
        rung3(device, 1);
        ID3D12Device_Release(device);
    }
    if (adapter) IDXGIAdapter_Release(adapter);
    puts_(failures ? "FAILED (" : "PASSED (");
    putu(failures, 10);
    puts_(" failures)\r\n");
    ExitProcess(failures);
}
