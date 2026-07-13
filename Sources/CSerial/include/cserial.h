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

#ifdef __cplusplus
}
#endif

#endif // CSERIAL_H
