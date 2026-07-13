#include "include/cserial.h"

#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

int cserial_open(const char* path)
{
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        return -1;
    int bits = TIOCM_RTS | TIOCM_DTR;
    ioctl(fd, TIOCMBIC, &bits);
    return fd;
}

int cserial_set_rts(int fd, bool asserted)
{
    int bits = TIOCM_RTS;
    return ioctl(fd, asserted ? TIOCMBIS : TIOCMBIC, &bits);
}

void cserial_close(int fd)
{
    if (fd < 0)
        return;
    int bits = TIOCM_RTS | TIOCM_DTR;
    ioctl(fd, TIOCMBIC, &bits);
    close(fd);
}
