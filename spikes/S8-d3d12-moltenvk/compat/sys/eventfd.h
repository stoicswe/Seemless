/* S8 spike only: minimal eventfd(2) emulation for macOS.
 *
 * vkd3d-proton uses eventfd as a single fd that is written (signal) and
 * read/polled (wait). macOS has no eventfd, so emulate it with a Unix-domain
 * datagram socket connected to itself (bind to a temp path, connect to it,
 * unlink the path): write() queues an 8-byte datagram on the same fd
 * synchronously, read() consumes one, poll(POLLIN) works. (A UDP loopback
 * socket also works but delivers asynchronously, which breaks zero-timeout
 * waits right after a signal.)
 *
 * Each read consumes exactly one datagram (EFD_SEMAPHORE semantics with
 * count 1). For plain eventfds, which vkd3d-proton uses as Win32 auto-reset
 * events, write() is wrapped so a signal is dropped while one is already
 * pending: repeated signals coalesce like an event. The mode is encoded in
 * the socket's bound name, so the wrapper works across images
 * (libvkd3d-proton writes to fds the test binary created).
 *
 * Spike only; product code (WP7.5) must use kqueue/MTLSharedEvent instead. */
#ifndef S8_COMPAT_SYS_EVENTFD_H
#define S8_COMPAT_SYS_EVENTFD_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>

#define EFD_SEMAPHORE 0x1
#define EFD_CLOEXEC   0x2
#define EFD_NONBLOCK  0x4

#define S8_EVENTFD_EVENT_TAG "s8efd-e-"

static inline ssize_t s8_eventfd_write(int fd, const void *buf, size_t n)
{
    struct sockaddr_un addr;
    socklen_t len = sizeof(addr);
    int err = errno;
    char peek;

    if (getsockname(fd, (struct sockaddr *)&addr, &len) == 0 && addr.sun_family == AF_UNIX
            && strstr(addr.sun_path, S8_EVENTFD_EVENT_TAG)
            && recv(fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT) >= 0)
        return (ssize_t)n; /* already signalled: coalesce */
    errno = err;
    return (write)(fd, buf, n);
}

static inline int eventfd(unsigned int initval, int flags)
{
    static unsigned int counter;
    struct sockaddr_un addr;
    const char *tmp = getenv("TMPDIR");
    uint64_t one = 1;
    unsigned int i;
    int fd;

    if (!tmp || strlen(tmp) > 60)
        tmp = "/tmp/";
    if ((fd = socket(AF_UNIX, SOCK_DGRAM, 0)) < 0)
        return -1;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s%s%s%d-%u-%x", tmp,
            tmp[strlen(tmp) - 1] == '/' ? "" : "/",
            (flags & EFD_SEMAPHORE) ? "s8efd-s-" : S8_EVENTFD_EVENT_TAG,
            (int)getpid(), __atomic_fetch_add(&counter, 1, __ATOMIC_RELAXED), (unsigned int)arc4random());
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0
            || connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
        unlink(addr.sun_path);
        close(fd);
        return -1;
    }
    unlink(addr.sun_path);
    if (flags & EFD_CLOEXEC)
        fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (flags & EFD_NONBLOCK)
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    for (i = 0; i < initval; i++)
        (void)(write)(fd, &one, sizeof(one));
    return fd;
}

/* Route write() in files that include this header through the wrapper. */
#define write(fd, buf, n) s8_eventfd_write(fd, buf, n)

#endif
