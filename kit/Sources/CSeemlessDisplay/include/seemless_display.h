// Mach side of the Seemless display protocol (version 1), client end plus the
// server half used by tests. This is our own implementation of the protocol
// documented in patches/qemu/0001-ui-seemless-display-backend.patch; no QEMU
// code. Swift wraps it in DisplayClient.
#pragma once
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>

#define SLD_VERSION 1
#define SLD_RING 3
#define SLD_MAX_HEADS 4
#define SLD_MAX_CURSOR 256
#define SLD_MAX_SIZE 16384

// client -> QEMU
#define SLD_C_CONNECT 0x53450001
#define SLD_C_ACK 0x53450002
#define SLD_C_SET_SIZE 0x53450003
// QEMU -> client
#define SLD_Q_SURFACES 0x53451001
#define SLD_Q_FRAME 0x53451002
#define SLD_Q_DISABLE 0x53451003
#define SLD_Q_CURSOR 0x53451004
#define SLD_Q_MOUSE 0x53451005

#define SLD_FOURCC_BGRA 0x42475241u
#define SLD_FOURCC_RGBA 0x52474241u

typedef enum {
    SLD_EV_NONE = 0,       // timeout
    SLD_EV_SURFACES = 1,
    SLD_EV_FRAME = 2,
    SLD_EV_DISABLE = 3,
    SLD_EV_CURSOR = 4,
    SLD_EV_MOUSE = 5,
    SLD_EV_INVALID = -1,   // dropped: failed validation
    SLD_EV_ERROR = -2,     // receive failed (port gone)
} SLDEventKind;

typedef struct {
    SLDEventKind kind;
    uint32_t head, generation;
    // SURFACES: validated surfaces (retained; caller releases with CFRelease)
    IOSurfaceRef surfaces[SLD_RING];
    uint32_t width, height, fourcc;
    // FRAME
    uint32_t index, source;
    uint64_t serial;
    uint32_t x, y, w, h;
    uint64_t t_update, t_ready, t_received;
    // CURSOR: malloc'd width*height*4 bytes (caller frees with free())
    uint8_t *pixels;
    uint32_t cursor_serial;
    int32_t hot_x, hot_y;
    // MOUSE
    int32_t mouse_x, mouse_y;
    bool visible;
} SLDEvent;

// Client
mach_port_t sld_lookup(const char *name, kern_return_t *kr);
mach_port_t sld_make_receive_port(void);
void sld_destroy_receive_port(mach_port_t port);
kern_return_t sld_connect(mach_port_t server, mach_port_t client_rcv);
kern_return_t sld_ack(mach_port_t server, mach_port_t client_rcv, uint32_t head, uint32_t generation, uint32_t index);
kern_return_t sld_set_size(mach_port_t server, mach_port_t client_rcv, uint32_t head, uint32_t width, uint32_t height,
                           uint32_t width_mm, uint32_t height_mm);
// Receives and validates one message. timeout_ms 0 waits forever.
SLDEvent sld_receive(mach_port_t client_rcv, uint32_t timeout_ms);

// Server half (tests and fakes)
typedef struct {
    int32_t id;                // 0 = timeout, -1 = invalid
    mach_port_t client;        // CONNECT: send right to the client's port
    uint32_t sender_uid;
    uint32_t head, generation, index, width, height;
} SLDRequest;

mach_port_t sld_checkin(const char *name, kern_return_t *kr);
SLDRequest sld_server_receive(mach_port_t server, uint32_t timeout_ms);
kern_return_t sld_send_surfaces(mach_port_t client, uint32_t head, uint32_t generation, uint32_t width, uint32_t height,
                                uint32_t fourcc, IOSurfaceRef s0, IOSurfaceRef s1, IOSurfaceRef s2);
kern_return_t sld_send_frame(mach_port_t client, uint32_t head, uint32_t generation, uint32_t index, uint64_t serial);
kern_return_t sld_send_cursor(mach_port_t client, uint32_t head, uint32_t serial, uint32_t width, uint32_t height,
                              int32_t hot_x, int32_t hot_y, const uint32_t *pixels);
kern_return_t sld_send_mouse(mach_port_t client, uint32_t head, int32_t x, int32_t y, bool visible);
kern_return_t sld_send_disable(mach_port_t client, uint32_t head);
// Raw inline message of `size` bytes (>= header) with id, for malformed-input tests.
kern_return_t sld_send_raw(mach_port_t client, uint32_t msgh_id, uint32_t size);
