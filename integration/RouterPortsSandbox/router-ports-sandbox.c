// The router-ports profile (shared/AgentLandIroh/Tests/router-ports-denied.sb) for a process in the
// iOS simulator, which sandbox-exec cannot reach: simulator apps are started by the simulator's launchd,
// never as children of the harness. integration/check-ios-product.py compiles the profile on the Mac
// (libsandbox's compiler, which the simulator runtime does not have) and builds this file into a
// simulator dylib that the UI test inserts into the app (DYLD_INSERT_LIBRARIES) with
// AGENTLAND_ROUTER_PORTS_BYTECODE naming the compiled profile.
//
// Before the app's own code runs, the constructor applies the profile to the process
// (sandbox_apply_bytecode, the simulator's libsystem_sandbox; the Mac's kernel enforces it) and checks
// that a UDP datagram to 127.0.0.1 on 1900, 5350 and 5351 is refused with EPERM. If anything fails it
// ends the process, so the app never runs unsandboxed with the dylib asked for. A process that passes
// appends one line to AGENTLAND_ROUTER_PORTS_REPORT, which the harness reads.
//
// Nothing here is part of the app: it exists only in the harness's temporary folder.
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

// libsystem_sandbox (not in the SDK's headers): applies compiled profile bytecode to this process.
extern int sandbox_apply_bytecode(const void *bytecode, size_t length, const char *name);

static void fail(const char *what) {
    fprintf(stderr, "router-ports-sandbox: %s (errno %d); ending the process\n", what, errno);
    abort();
}

/// errno of a one-byte UDP datagram to 127.0.0.1:`port`, 0 when it was sent.
static int send_error(uint16_t port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) fail("socket");
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ssize_t sent = sendto(fd, "x", 1, 0, (struct sockaddr *)&address, sizeof address);
    int error = sent < 0 ? errno : 0;
    close(fd);
    return error;
}

__attribute__((constructor)) static void apply_router_ports_profile(void) {
    const char *path = getenv("AGENTLAND_ROUTER_PORTS_BYTECODE");
    if (path == NULL || *path == 0) fail("AGENTLAND_ROUTER_PORTS_BYTECODE is not set");
    int fd = open(path, O_RDONLY);
    if (fd < 0) fail("cannot open the compiled profile");
    struct stat info;
    if (fstat(fd, &info) != 0 || info.st_size <= 0 || info.st_size > (1 << 20)) fail("the compiled profile has no usable size");
    void *bytecode = malloc((size_t)info.st_size);
    if (bytecode == NULL || read(fd, bytecode, (size_t)info.st_size) != info.st_size) fail("cannot read the compiled profile");
    close(fd);
    if (sandbox_apply_bytecode(bytecode, (size_t)info.st_size, NULL) != 0) fail("sandbox_apply_bytecode refused the profile");
    free(bytecode);
    const uint16_t ports[] = {1900, 5350, 5351};
    for (size_t index = 0; index < sizeof ports / sizeof ports[0]; index++) {
        if (send_error(ports[index]) != EPERM) fail("the profile does not refuse a router port");
    }
    const char *report = getenv("AGENTLAND_ROUTER_PORTS_REPORT");
    if (report != NULL && *report != 0) {
        FILE *file = fopen(report, "a");
        if (file == NULL) fail("cannot open the report");
        fprintf(file, "applied pid=%d 1900,5350,5351=EPERM\n", getpid());
        fclose(file);
    }
}
