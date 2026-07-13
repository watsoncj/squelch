// Minimal serial-port control-line shim for PTT keying (Digirig keys PTT
// via RTS). Exists as C because the TIOCM* ioctl request macros don't
// import into Swift.
#ifndef CSERIAL_H
#define CSERIAL_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Open a serial port for control-line use only. Deasserts RTS and DTR
// immediately (opening a port can assert them, which would key the radio).
// Returns a file descriptor, or -1 on failure (check errno).
int cserial_open(const char* path);

// Assert (key) or deassert (unkey) RTS. Returns 0 on success.
int cserial_set_rts(int fd, bool asserted);

// Deassert control lines and close.
void cserial_close(int fd);

// Open a serial port configured for CAT data: raw mode, 8 data bits,
// no parity, 2 stop bits (Yaesu convention), given baud rate.
// Returns a file descriptor or -1 (check errno).
int cserial_open_cat(const char* path, int baud);

// Write exactly len bytes. Returns bytes written or -1.
int cserial_write(int fd, const char* data, int len);

// Read up to max_len bytes, waiting up to timeout_ms for the first byte.
// Returns bytes read (0 on timeout) or -1 on error.
int cserial_read(int fd, char* data, int max_len, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif // CSERIAL_H
