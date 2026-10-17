#ifndef IROH_SEND_RECORDER_H
#define IROH_SEND_RECORDER_H

#include <stddef.h>
#include <stdint.h>

// Test-only: records every connect, sendto, send and sendmsg that code in one
// loaded image (the test bundle, which statically links the iroh library) makes
// to a watched remote port, before the call reaches the system. It works by
// pointing that image's imported-symbol slots at recording wrappers that then
// call the real functions. It observes attempts even when a sandbox profile
// makes the system refuse them.

/// Rebinds connect, sendto, send and sendmsg in every loaded image whose path
/// contains `image_path_part`. Returns the number of slots rebound (0 if none).
/// Safe to call more than once; later calls only rebind slots not yet rebound.
int iroh_send_recorder_install(const char *image_path_part);

/// Sets the remote ports to record (at most 16). Other traffic is not recorded.
void iroh_send_recorder_watch_ports(const uint16_t *ports, int count);

/// Forgets what was recorded so far.
void iroh_send_recorder_reset(void);

/// Number of attempts recorded since the last reset (also counts ones not kept).
int iroh_send_recorder_count(void);

/// Writes attempt `index` (0-based, at most the first 64 are kept) as text such
/// as "sendto 239.255.255.250:1900" into `buffer`. Returns 0 if there is none.
int iroh_send_recorder_entry(int index, char *buffer, size_t capacity);

#endif
