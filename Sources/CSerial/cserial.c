#include "include/cserial.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
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

int cserial_open_cat(const char* path, int baud)
{
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        return -1;

    struct termios tio;
    if (tcgetattr(fd, &tio) != 0)
    {
        close(fd);
        return -1;
    }
    cfmakeraw(&tio);
    tio.c_cflag |= CLOCAL | CREAD;
    tio.c_cflag |= CSTOPB; // Yaesu CAT: 8N2
    tio.c_cflag &= ~(PARENB | CRTSCTS);
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 0;
    cfsetspeed(&tio, (speed_t)baud);
    if (tcsetattr(fd, TCSANOW, &tio) != 0)
    {
        close(fd);
        return -1;
    }
    // Assert RTS/DTR: the FT-891's CAT RTS menu (factory ENABLE) treats RTS
    // as flow control and the radio stays silent without it. Safe here —
    // PTT lives on the other CP2105 port.
    int bits = TIOCM_RTS | TIOCM_DTR;
    ioctl(fd, TIOCMBIS, &bits);
    tcflush(fd, TCIOFLUSH);
    return fd;
}

int cserial_write(int fd, const char* data, int len)
{
    int total = 0;
    while (total < len)
    {
        ssize_t n = write(fd, data + total, len - total);
        if (n < 0)
            return -1;
        total += (int)n;
    }
    return total;
}

int cserial_read(int fd, char* data, int max_len, int timeout_ms)
{
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int rc = poll(&pfd, 1, timeout_ms);
    if (rc <= 0)
        return rc; // 0 = timeout, -1 = error
    ssize_t n = read(fd, data, max_len);
    return n < 0 ? -1 : (int)n;
}
