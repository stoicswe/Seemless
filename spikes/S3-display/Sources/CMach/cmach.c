#include "cmach.h"
#include <mach/mach_time.h>
#include <servers/bootstrap.h>
#include <string.h>

#define SL_MSG_SURFACES 0x5e3a0001
#define SL_MSG_FRAME    0x5e3a0002

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface[SL_RING];
    uint32_t generation, width, height, fourcc;
} SLSurfacesMsg;

typedef struct {
    mach_msg_header_t header;
    uint32_t generation, index;
    uint64_t serial;
    uint32_t x, y, w, h;
    uint64_t t_update, t_ready;
    uint32_t source, pad;
} SLFrameMsg;

mach_port_t sl_checkin(const char *name, kern_return_t *kr)
{
    mach_port_t port = MACH_PORT_NULL;
    *kr = bootstrap_check_in(bootstrap_port, name, &port);
    return *kr == KERN_SUCCESS ? port : MACH_PORT_NULL;
}

SLEvent sl_receive(mach_port_t port, uint32_t timeout_ms)
{
    union {
        mach_msg_header_t h;
        SLSurfacesMsg s;
        SLFrameMsg f;
        uint8_t raw[1024];
    } buf;
    SLEvent ev;
    memset(&ev, 0, sizeof(ev));

    mach_msg_option_t opt = MACH_RCV_MSG | (timeout_ms ? MACH_RCV_TIMEOUT : 0);
    kern_return_t kr = mach_msg(&buf.h, opt, 0, sizeof(buf), port, timeout_ms,
                                MACH_PORT_NULL);
    if (kr == MACH_RCV_TIMED_OUT) {
        return ev;
    }
    if (kr != KERN_SUCCESS) {
        ev.kind = -1;
        return ev;
    }
    ev.t_recv = mach_absolute_time();

    // The guest is untrusted and QEMU is a separate process: check sizes and
    // descriptor types before trusting anything in the message.
    if (buf.h.msgh_id == SL_MSG_SURFACES &&
        (buf.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
        buf.h.msgh_size >= sizeof(SLSurfacesMsg) &&
        buf.s.body.msgh_descriptor_count == SL_RING) {
        for (int i = 0; i < SL_RING; i++) {
            if (buf.s.surface[i].type != MACH_MSG_PORT_DESCRIPTOR) {
                mach_msg_destroy(&buf.h);
                ev.kind = -1;
                return ev;
            }
            ev.ports[i] = buf.s.surface[i].name;
        }
        ev.kind = 1;
        ev.generation = buf.s.generation;
        ev.width = buf.s.width;
        ev.height = buf.s.height;
        ev.fourcc = buf.s.fourcc;
        return ev;
    }
    if (buf.h.msgh_id == SL_MSG_FRAME &&
        !(buf.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
        buf.h.msgh_size >= sizeof(SLFrameMsg)) {
        ev.kind = 2;
        ev.generation = buf.f.generation;
        ev.index = buf.f.index;
        ev.serial = buf.f.serial;
        ev.x = buf.f.x; ev.y = buf.f.y; ev.w = buf.f.w; ev.h = buf.f.h;
        ev.t_update = buf.f.t_update;
        ev.t_ready = buf.f.t_ready;
        ev.source = buf.f.source;
        return ev;
    }
    mach_msg_destroy(&buf.h);
    ev.kind = -1;
    return ev;
}
