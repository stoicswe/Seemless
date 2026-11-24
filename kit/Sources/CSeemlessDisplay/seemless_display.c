#include "seemless_display.h"

#include <mach/mach_time.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Wire layouts (protocol version 1). Natural alignment, little endian.

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t client;
    uint32_t version, flags;
} ConnectMsg;

typedef struct {
    mach_msg_header_t header;
    uint32_t head, generation, index, pad;
} AckMsg;

typedef struct {
    mach_msg_header_t header;
    uint32_t head, width, height, width_mm, height_mm, pad;
} SetSizeMsg;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface[SLD_RING];
    uint32_t version, head, generation, width, height, fourcc;
} SurfacesMsg;

typedef struct {
    mach_msg_header_t header;
    uint32_t head, generation, index, source;
    uint64_t serial;
    uint32_t x, y, w, h;
    uint64_t t_update, t_ready;
} FrameMsg;

typedef struct {
    mach_msg_header_t header;
    uint32_t head, pad;
} DisableMsg;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t pixels;
    uint32_t head, serial, width, height;
    int32_t hot_x, hot_y;
} CursorMsg;

typedef struct {
    mach_msg_header_t header;
    uint32_t head;
    int32_t x, y;
    uint32_t visible;
} MouseMsg;

typedef union {
    mach_msg_header_t header;
    ConnectMsg connect;
    AckMsg ack;
    SetSizeMsg size;
    SurfacesMsg surfaces;
    FrameMsg frame;
    DisableMsg disable;
    CursorMsg cursor;
    MouseMsg mouse;
    uint8_t raw[1024];
} AnyMsg;

// ---------------------------------------------------------------- client

mach_port_t sld_lookup(const char *name, kern_return_t *kr)
{
    mach_port_t port = MACH_PORT_NULL;
    *kr = bootstrap_look_up(bootstrap_port, name, &port);
    return *kr == KERN_SUCCESS ? port : MACH_PORT_NULL;
}

mach_port_t sld_make_receive_port(void)
{
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
        return MACH_PORT_NULL;
    }
    return port;
}

void sld_destroy_receive_port(mach_port_t port)
{
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
}

static kern_return_t send(mach_msg_header_t *h, mach_msg_size_t size, mach_port_t remote, mach_port_t local,
                          bool complex)
{
    h->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, local ? MACH_MSG_TYPE_MAKE_SEND : 0) |
                   (complex ? MACH_MSGH_BITS_COMPLEX : 0);
    h->msgh_size = size;
    h->msgh_remote_port = remote;
    h->msgh_local_port = local;
    return mach_msg(h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, size, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
}

kern_return_t sld_connect(mach_port_t server, mach_port_t client_rcv)
{
    ConnectMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_C_CONNECT;
    m.body.msgh_descriptor_count = 1;
    m.client.name = client_rcv;
    m.client.disposition = MACH_MSG_TYPE_MAKE_SEND;
    m.client.type = MACH_MSG_PORT_DESCRIPTOR;
    m.version = SLD_VERSION;
    return send(&m.header, sizeof(m), server, MACH_PORT_NULL, true);
}

kern_return_t sld_ack(mach_port_t server, mach_port_t client_rcv, uint32_t head, uint32_t generation, uint32_t index)
{
    AckMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_C_ACK;
    m.head = head;
    m.generation = generation;
    m.index = index;
    return send(&m.header, sizeof(m), server, client_rcv, false);
}

kern_return_t sld_set_size(mach_port_t server, mach_port_t client_rcv, uint32_t head, uint32_t width, uint32_t height,
                           uint32_t width_mm, uint32_t height_mm)
{
    SetSizeMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_C_SET_SIZE;
    m.head = head;
    m.width = width;
    m.height = height;
    m.width_mm = width_mm;
    m.height_mm = height_mm;
    return send(&m.header, sizeof(m), server, client_rcv, false);
}

static bool valid_fourcc(uint32_t f) { return f == SLD_FOURCC_BGRA || f == SLD_FOURCC_RGBA; }

// The other end is QEMU, which runs guest-influenced code: check every size,
// descriptor and the surfaces themselves before trusting a message.
SLDEvent sld_receive(mach_port_t rcv, uint32_t timeout_ms)
{
    struct {
        AnyMsg msg;
        mach_msg_max_trailer_t trailer;
    } buf;
    SLDEvent ev;
    memset(&ev, 0, sizeof(ev));

    mach_msg_option_t opt = MACH_RCV_MSG | (timeout_ms ? MACH_RCV_TIMEOUT : 0);
    kern_return_t kr = mach_msg(&buf.msg.header, opt, 0, sizeof(buf), rcv, timeout_ms, MACH_PORT_NULL);
    if (kr == MACH_RCV_TIMED_OUT) {
        return ev;
    }
    if (kr == MACH_RCV_TOO_LARGE) {   // kernel already destroyed it
        ev.kind = SLD_EV_INVALID;
        return ev;
    }
    if (kr != KERN_SUCCESS) {
        ev.kind = SLD_EV_ERROR;
        return ev;
    }
    ev.t_received = mach_absolute_time();
    mach_msg_header_t *h = &buf.msg.header;
    bool complex = (h->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;

    switch (h->msgh_id) {
    case SLD_Q_SURFACES: {
        SurfacesMsg *m = &buf.msg.surfaces;
        if (!complex || h->msgh_size < sizeof(*m) || m->body.msgh_descriptor_count != SLD_RING ||
            m->version != SLD_VERSION || m->head >= SLD_MAX_HEADS || !valid_fourcc(m->fourcc) ||
            m->width == 0 || m->height == 0 || m->width > SLD_MAX_SIZE || m->height > SLD_MAX_SIZE) {
            break;
        }
        bool ok = true;
        for (int i = 0; i < SLD_RING; i++) {
            ok = ok && m->surface[i].type == MACH_MSG_PORT_DESCRIPTOR;
        }
        if (!ok) {
            break;
        }
        for (int i = 0; i < SLD_RING; i++) {
            IOSurfaceRef s = IOSurfaceLookupFromMachPort(m->surface[i].name);
            mach_port_deallocate(mach_task_self(), m->surface[i].name);
            m->surface[i].name = MACH_PORT_NULL;
            if (!s || IOSurfaceGetWidth(s) != m->width || IOSurfaceGetHeight(s) != m->height ||
                IOSurfaceGetPixelFormat(s) != m->fourcc || IOSurfaceGetBytesPerElement(s) != 4 ||
                IOSurfaceGetBytesPerRow(s) < (size_t)m->width * 4) {
                ok = false;
            }
            ev.surfaces[i] = s;
        }
        if (!ok) {
            for (int i = 0; i < SLD_RING; i++) {
                if (ev.surfaces[i]) CFRelease(ev.surfaces[i]);
                ev.surfaces[i] = NULL;
            }
            ev.kind = SLD_EV_INVALID;
            return ev;
        }
        ev.kind = SLD_EV_SURFACES;
        ev.head = m->head;
        ev.generation = m->generation;
        ev.width = m->width;
        ev.height = m->height;
        ev.fourcc = m->fourcc;
        return ev;
    }
    case SLD_Q_FRAME: {
        FrameMsg *m = &buf.msg.frame;
        if (complex || h->msgh_size < sizeof(*m) || m->head >= SLD_MAX_HEADS || m->index >= SLD_RING) {
            break;
        }
        ev.kind = SLD_EV_FRAME;
        ev.head = m->head;
        ev.generation = m->generation;
        ev.index = m->index;
        ev.source = m->source;
        ev.serial = m->serial;
        ev.x = m->x; ev.y = m->y; ev.w = m->w; ev.h = m->h;
        ev.t_update = m->t_update;
        ev.t_ready = m->t_ready;
        return ev;
    }
    case SLD_Q_DISABLE: {
        DisableMsg *m = &buf.msg.disable;
        if (complex || h->msgh_size < sizeof(*m) || m->head >= SLD_MAX_HEADS) {
            break;
        }
        ev.kind = SLD_EV_DISABLE;
        ev.head = m->head;
        return ev;
    }
    case SLD_Q_CURSOR: {
        CursorMsg *m = &buf.msg.cursor;
        if (!complex || h->msgh_size < sizeof(*m) || m->body.msgh_descriptor_count != 1 ||
            m->pixels.type != MACH_MSG_OOL_DESCRIPTOR || m->head >= SLD_MAX_HEADS || m->width == 0 ||
            m->height == 0 || m->width > SLD_MAX_CURSOR || m->height > SLD_MAX_CURSOR ||
            m->pixels.size != m->width * m->height * 4) {
            break;
        }
        ev.pixels = malloc(m->pixels.size);
        if (!ev.pixels) {
            break;
        }
        memcpy(ev.pixels, m->pixels.address, m->pixels.size);
        vm_deallocate(mach_task_self(), (vm_address_t)m->pixels.address, m->pixels.size);
        ev.kind = SLD_EV_CURSOR;
        ev.head = m->head;
        ev.cursor_serial = m->serial;
        ev.width = m->width;
        ev.height = m->height;
        ev.hot_x = m->hot_x;
        ev.hot_y = m->hot_y;
        return ev;
    }
    case SLD_Q_MOUSE: {
        MouseMsg *m = &buf.msg.mouse;
        if (complex || h->msgh_size < sizeof(*m) || m->head >= SLD_MAX_HEADS) {
            break;
        }
        ev.kind = SLD_EV_MOUSE;
        ev.head = m->head;
        ev.mouse_x = m->x;
        ev.mouse_y = m->y;
        ev.visible = m->visible != 0;
        return ev;
    }
    }
    mach_msg_destroy(h);
    ev.kind = SLD_EV_INVALID;
    return ev;
}

// ---------------------------------------------------------------- server (tests)

mach_port_t sld_checkin(const char *name, kern_return_t *kr)
{
    mach_port_t port = MACH_PORT_NULL;
    *kr = bootstrap_check_in(bootstrap_port, name, &port);
    return *kr == KERN_SUCCESS ? port : MACH_PORT_NULL;
}

SLDRequest sld_server_receive(mach_port_t server, uint32_t timeout_ms)
{
    struct {
        AnyMsg msg;
        mach_msg_security_trailer_t trailer;
    } buf;
    SLDRequest r;
    memset(&r, 0, sizeof(r));
    mach_msg_option_t opt = MACH_RCV_MSG | (timeout_ms ? MACH_RCV_TIMEOUT : 0) |
                            MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                            MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_SENDER);
    kern_return_t kr = mach_msg(&buf.msg.header, opt, 0, sizeof(buf), server, timeout_ms, MACH_PORT_NULL);
    if (kr == MACH_RCV_TIMED_OUT) {
        return r;
    }
    if (kr != KERN_SUCCESS) {
        r.id = -1;
        return r;
    }
    mach_msg_header_t *h = &buf.msg.header;
    mach_msg_security_trailer_t *tr = (mach_msg_security_trailer_t *)((uint8_t *)h + round_msg(h->msgh_size));
    r.sender_uid = tr->msgh_sender.val[0];
    r.id = (int32_t)h->msgh_id;
    switch (h->msgh_id) {
    case SLD_C_CONNECT:
        r.client = buf.msg.connect.client.name;
        return r;
    case SLD_C_ACK:
        r.head = buf.msg.ack.head;
        r.generation = buf.msg.ack.generation;
        r.index = buf.msg.ack.index;
        break;
    case SLD_C_SET_SIZE:
        r.head = buf.msg.size.head;
        r.width = buf.msg.size.width;
        r.height = buf.msg.size.height;
        break;
    }
    mach_msg_destroy(h);
    return r;
}

kern_return_t sld_send_surfaces(mach_port_t client, uint32_t head, uint32_t generation, uint32_t width, uint32_t height,
                                uint32_t fourcc, IOSurfaceRef s0, IOSurfaceRef s1, IOSurfaceRef s2)
{
    IOSurfaceRef surfaces[SLD_RING] = { s0, s1, s2 };
    SurfacesMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_Q_SURFACES;
    m.body.msgh_descriptor_count = SLD_RING;
    for (int i = 0; i < SLD_RING; i++) {
        m.surface[i].name = IOSurfaceCreateMachPort(surfaces[i]);
        m.surface[i].disposition = MACH_MSG_TYPE_MOVE_SEND;
        m.surface[i].type = MACH_MSG_PORT_DESCRIPTOR;
    }
    m.version = SLD_VERSION;
    m.head = head;
    m.generation = generation;
    m.width = width;
    m.height = height;
    m.fourcc = fourcc;
    kern_return_t kr = send(&m.header, sizeof(m), client, MACH_PORT_NULL, true);
    if (kr != KERN_SUCCESS) {
        for (int i = 0; i < SLD_RING; i++) mach_port_deallocate(mach_task_self(), m.surface[i].name);
    }
    return kr;
}

kern_return_t sld_send_frame(mach_port_t client, uint32_t head, uint32_t generation, uint32_t index, uint64_t serial)
{
    FrameMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_Q_FRAME;
    m.head = head;
    m.generation = generation;
    m.index = index;
    m.source = 1;
    m.serial = serial;
    m.t_update = m.t_ready = mach_absolute_time();
    return send(&m.header, sizeof(m), client, MACH_PORT_NULL, false);
}

kern_return_t sld_send_cursor(mach_port_t client, uint32_t head, uint32_t serial, uint32_t width, uint32_t height,
                              int32_t hot_x, int32_t hot_y, const uint32_t *pixels)
{
    CursorMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_Q_CURSOR;
    m.body.msgh_descriptor_count = 1;
    m.pixels.address = (void *)pixels;
    m.pixels.size = width * height * 4;
    m.pixels.copy = MACH_MSG_VIRTUAL_COPY;
    m.pixels.type = MACH_MSG_OOL_DESCRIPTOR;
    m.head = head;
    m.serial = serial;
    m.width = width;
    m.height = height;
    m.hot_x = hot_x;
    m.hot_y = hot_y;
    return send(&m.header, sizeof(m), client, MACH_PORT_NULL, true);
}

kern_return_t sld_send_mouse(mach_port_t client, uint32_t head, int32_t x, int32_t y, bool visible)
{
    MouseMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_Q_MOUSE;
    m.head = head;
    m.x = x;
    m.y = y;
    m.visible = visible;
    return send(&m.header, sizeof(m), client, MACH_PORT_NULL, false);
}

kern_return_t sld_send_disable(mach_port_t client, uint32_t head)
{
    DisableMsg m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_id = SLD_Q_DISABLE;
    m.head = head;
    return send(&m.header, sizeof(m), client, MACH_PORT_NULL, false);
}

kern_return_t sld_send_raw(mach_port_t client, uint32_t msgh_id, uint32_t size)
{
    AnyMsg m;
    memset(&m, 0xff, sizeof(m));
    if (size < sizeof(mach_msg_header_t)) size = sizeof(mach_msg_header_t);
    if (size > sizeof(m)) size = sizeof(m);
    size = (size + 3) & ~3u;
    m.header.msgh_id = msgh_id;
    return send(&m.header, size, client, MACH_PORT_NULL, false);
}
