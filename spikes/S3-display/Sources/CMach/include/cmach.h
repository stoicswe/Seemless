// Spike S3: Mach side of the display hand-off (app end).
// The message layout must match build/s3 ui/seemless.m (patches/qemu/spike-S3-ui-seemless.patch).
#pragma once
#include <mach/mach.h>
#include <stdint.h>

#define SL_RING 3

typedef struct {
    int kind;                 // 0 = timeout, 1 = surfaces, 2 = frame, -1 = error
    mach_port_t ports[SL_RING];
    uint32_t generation, width, height, fourcc;
    uint32_t index, x, y, w, h, source;
    uint64_t serial, t_update, t_ready, t_recv;
} SLEvent;

// Check in a receive right under `name` in the per-user bootstrap namespace.
// Returns MACH_PORT_NULL on failure; *kr gets the kernel/bootstrap result.
mach_port_t sl_checkin(const char *name, kern_return_t *kr);

// Receive one message (blocking up to timeout_ms; 0 = forever).
SLEvent sl_receive(mach_port_t port, uint32_t timeout_ms);
