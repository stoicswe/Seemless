/* S8 spike: headless replacement for vkd3d-proton's demos/demo_xcb.h.
 *
 * The upstream demos need XCB or Win32. This backend runs them with no window:
 * the "swapchain" is a ring of committed render targets, every present copies
 * the current back buffer to a readback buffer, and after S8_DEMO_FRAMES
 * frames (default 60) the last frame is written to S8_DEMO_OUT (binary PPM)
 * and the demo exits. It exercises device, PSO, DXBC shaders, draws and
 * copies; it does NOT exercise vkd3d-proton's DXGI/Vulkan swapchain path. */
#include <stdio.h>
#include <limits.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/eventfd.h>

struct demo
{
    struct demo_window *window;
    void *user_data;
    void (*idle_func)(struct demo *demo, void *user_data);
    bool destroy_request;
    unsigned int frames;
};

struct demo_window
{
    struct demo *demo;
    void *user_data;
    void (*expose_func)(struct demo_window *window, void *user_data);
    void (*key_press_func)(struct demo_window *window, demo_key key, void *user_data);
};

struct demo_swapchain
{
    ID3D12Device *device;
    ID3D12CommandQueue *queue;
    ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList *list;
    ID3D12Fence *fence;
    UINT64 fence_value;
    ID3D12Resource *buffers[8];
    ID3D12Resource *readback;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    unsigned int count, index, width, height;
    unsigned int presents;
    struct demo *demo;
};

static struct demo_swapchain *demo_headless_swapchain;

static inline struct demo_window *demo_window_create(struct demo *demo, const char *title,
        unsigned int width, unsigned int height, void *user_data)
{
    struct demo_window *window = calloc(1, sizeof(*window));
    window->demo = demo;
    window->user_data = user_data;
    demo->window = window;
    fprintf(stderr, "s8-demo: headless window \"%s\" %ux%u\n", title, width, height);
    return window;
}

static inline void demo_window_destroy(struct demo_window *window)
{
    window->demo->window = NULL;
    free(window);
}

static inline void demo_window_destroy_defer(struct demo_window *window)
{
    window->demo->destroy_request = true;
}

static inline void demo_window_set_key_press_func(struct demo_window *window,
        void (*key_press_func)(struct demo_window *window, demo_key key, void *user_data))
{
    window->key_press_func = key_press_func;
}

static inline void demo_window_set_expose_func(struct demo_window *window,
        void (*expose_func)(struct demo_window *window, void *user_data))
{
    window->expose_func = expose_func;
}

static inline bool demo_init(struct demo *demo, void *user_data)
{
    const char *f = getenv("S8_DEMO_FRAMES");
    memset(demo, 0, sizeof(*demo));
    demo->user_data = user_data;
    demo->frames = f ? (unsigned int)atoi(f) : 60;
    return true;
}

static inline void demo_cleanup(struct demo *demo)
{
    if (demo->window)
        demo_window_destroy(demo->window);
}

static inline void demo_set_idle_func(struct demo *demo,
        void (*idle_func)(struct demo *demo, void *user_data))
{
    demo->idle_func = idle_func;
}

static inline void demo_process_events(struct demo *demo)
{
    while (demo->window && !demo->destroy_request
            && (!demo_headless_swapchain || demo_headless_swapchain->presents < demo->frames))
    {
        if (demo->idle_func)
            demo->idle_func(demo, demo->user_data);
        else if (demo->window->expose_func)
            demo->window->expose_func(demo->window, demo->window->user_data);
        else
            break;
    }
}

static inline void demo_headless_wait(struct demo_swapchain *sc)
{
    ID3D12CommandQueue_Signal(sc->queue, sc->fence, ++sc->fence_value);
    ID3D12Fence_SetEventOnCompletion(sc->fence, sc->fence_value, NULL); /* NULL = block */
}

static inline struct demo_swapchain *demo_swapchain_create(ID3D12CommandQueue *command_queue,
        struct demo_window *window, const struct demo_swapchain_desc *desc)
{
    D3D12_HEAP_PROPERTIES heap = {0};
    D3D12_RESOURCE_DESC rd = {0};
    struct demo_swapchain *sc;
    UINT64 total = 0;
    unsigned int i;

    sc = calloc(1, sizeof(*sc));
    sc->queue = command_queue;
    sc->demo = window->demo;
    sc->count = desc->buffer_count > 8 ? 8 : desc->buffer_count;
    sc->width = desc->width;
    sc->height = desc->height;
    if (FAILED(ID3D12CommandQueue_GetDevice(command_queue, &IID_ID3D12Device, (void **)&sc->device)))
        goto fail;

    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = desc->width;
    rd.Height = desc->height;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = desc->format;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    for (i = 0; i < sc->count; i++)
        if (FAILED(ID3D12Device_CreateCommittedResource(sc->device, &heap, D3D12_HEAP_FLAG_NONE, &rd,
                D3D12_RESOURCE_STATE_PRESENT, NULL, &IID_ID3D12Resource, (void **)&sc->buffers[i])))
            goto fail;

    ID3D12Device_GetCopyableFootprints(sc->device, &rd, 0, 1, 0, &sc->footprint, NULL, NULL, &total);
    heap.Type = D3D12_HEAP_TYPE_READBACK;
    memset(&rd, 0, sizeof(rd));
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = total;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (FAILED(ID3D12Device_CreateCommittedResource(sc->device, &heap, D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&sc->readback)))
        goto fail;
    if (FAILED(ID3D12Device_CreateCommandAllocator(sc->device, D3D12_COMMAND_LIST_TYPE_DIRECT,
            &IID_ID3D12CommandAllocator, (void **)&sc->allocator)))
        goto fail;
    if (FAILED(ID3D12Device_CreateCommandList(sc->device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, sc->allocator, NULL,
            &IID_ID3D12GraphicsCommandList, (void **)&sc->list)))
        goto fail;
    ID3D12GraphicsCommandList_Close(sc->list);
    if (FAILED(ID3D12Device_CreateFence(sc->device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&sc->fence)))
        goto fail;
    demo_headless_swapchain = sc;
    return sc;

fail:
    fprintf(stderr, "s8-demo: failed to create headless swapchain\n");
    exit(2);
}

static inline void demo_swapchain_destroy(struct demo_swapchain *sc)
{
    unsigned int i;
    demo_headless_wait(sc);
    for (i = 0; i < sc->count; i++)
        ID3D12Resource_Release(sc->buffers[i]);
    ID3D12Resource_Release(sc->readback);
    ID3D12GraphicsCommandList_Release(sc->list);
    ID3D12CommandAllocator_Release(sc->allocator);
    ID3D12Fence_Release(sc->fence);
    ID3D12Device_Release(sc->device);
    demo_headless_swapchain = NULL;
    free(sc);
}

static inline unsigned int demo_swapchain_get_current_back_buffer_index(struct demo_swapchain *sc)
{
    return sc->index;
}

static inline ID3D12Resource *demo_swapchain_get_back_buffer(struct demo_swapchain *sc, unsigned int index)
{
    ID3D12Resource_AddRef(sc->buffers[index]);
    return sc->buffers[index];
}

static inline void demo_headless_dump(struct demo_swapchain *sc)
{
    const char *path = getenv("S8_DEMO_OUT");
    D3D12_RANGE range = {0, 0};
    unsigned int x, y;
    uint8_t *data;
    FILE *f;

    if (!path || FAILED(ID3D12Resource_Map(sc->readback, 0, NULL, (void **)&data)))
        return;
    if ((f = fopen(path, "wb")))
    {
        fprintf(f, "P6\n%u %u\n255\n", sc->width, sc->height);
        for (y = 0; y < sc->height; y++)
            for (x = 0; x < sc->width; x++)
            {
                const uint8_t *p = data + sc->footprint.Offset + y * sc->footprint.Footprint.RowPitch + x * 4;
                uint8_t rgb[3] = { p[2], p[1], p[0] }; /* B8G8R8A8 */
                fwrite(rgb, 1, 3, f);
            }
        fclose(f);
        fprintf(stderr, "s8-demo: wrote %s after %u presents\n", path, sc->presents);
    }
    ID3D12Resource_Unmap(sc->readback, 0, &range);
}

static inline void demo_swapchain_present(struct demo_swapchain *sc)
{
    D3D12_TEXTURE_COPY_LOCATION dst, src;
    D3D12_RESOURCE_BARRIER b;

    ID3D12CommandAllocator_Reset(sc->allocator);
    ID3D12GraphicsCommandList_Reset(sc->list, sc->allocator, NULL);
    memset(&b, 0, sizeof(b));
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = sc->buffers[sc->index];
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(sc->list, 1, &b);
    dst.pResource = sc->readback;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint = sc->footprint;
    src.pResource = sc->buffers[sc->index];
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.SubresourceIndex = 0;
    ID3D12GraphicsCommandList_CopyTextureRegion(sc->list, &dst, 0, 0, 0, &src, NULL);
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
    ID3D12GraphicsCommandList_ResourceBarrier(sc->list, 1, &b);
    ID3D12GraphicsCommandList_Close(sc->list);
    ID3D12CommandQueue_ExecuteCommandLists(sc->queue, 1, (ID3D12CommandList **)&sc->list);
    demo_headless_wait(sc);

    sc->presents++;
    if (sc->presents == sc->demo->frames)
        demo_headless_dump(sc);
    sc->index = (sc->index + 1) % sc->count;
}

static inline HANDLE demo_create_event(void)
{
    return (HANDLE)(intptr_t)eventfd(0, EFD_CLOEXEC);
}

static inline unsigned int demo_wait_event(HANDLE event)
{
    uint64_t v;
    read((int)(intptr_t)event, &v, sizeof(v));
    return 0;
}

static inline void demo_destroy_event(HANDLE event)
{
    close((int)(intptr_t)event);
}
