#include "IrohSendRecorder.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef int (*connect_fn)(int, const struct sockaddr *, socklen_t);
typedef ssize_t (*sendto_fn)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
typedef ssize_t (*send_fn)(int, const void *, size_t, int);
typedef ssize_t (*sendmsg_fn)(int, const struct msghdr *, int);

static connect_fn real_connect;
static sendto_fn real_sendto;
static send_fn real_send;
static sendmsg_fn real_sendmsg;

enum { MAX_PORTS = 16, MAX_ENTRIES = 64, ENTRY_SIZE = 96 };

static pthread_mutex_t recorder_lock = PTHREAD_MUTEX_INITIALIZER;
static uint16_t watched_ports[MAX_PORTS];
static int watched_count;
static char entries[MAX_ENTRIES][ENTRY_SIZE];
static int entry_count;

static int describe(const struct sockaddr *addr, socklen_t length, char *host, size_t host_capacity)
{
    if (addr == NULL) {
        return -1;
    }
    if (addr->sa_family == AF_INET && length >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)addr;
        inet_ntop(AF_INET, &v4->sin_addr, host, (socklen_t)host_capacity);
        return ntohs(v4->sin_port);
    }
    if (addr->sa_family == AF_INET6 && length >= (socklen_t)sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)addr;
        inet_ntop(AF_INET6, &v6->sin6_addr, host, (socklen_t)host_capacity);
        return ntohs(v6->sin6_port);
    }
    return -1;
}

static void note(const char *kind, const struct sockaddr *addr, socklen_t length)
{
    char host[INET6_ADDRSTRLEN] = "";
    int port = describe(addr, length, host, sizeof host);
    if (port < 0) {
        return;
    }
    pthread_mutex_lock(&recorder_lock);
    for (int i = 0; i < watched_count; i++) {
        if (watched_ports[i] == port) {
            if (entry_count < MAX_ENTRIES) {
                const char *format = addr->sa_family == AF_INET6 ? "%s [%s]:%d" : "%s %s:%d";
                snprintf(entries[entry_count], ENTRY_SIZE, format, kind, host, port);
            }
            entry_count++;
            break;
        }
    }
    pthread_mutex_unlock(&recorder_lock);
}

static void note_peer(const char *kind, int fd)
{
    struct sockaddr_storage peer;
    socklen_t length = sizeof peer;
    if (getpeername(fd, (struct sockaddr *)&peer, &length) == 0) {
        note(kind, (const struct sockaddr *)&peer, length);
    }
}

static int recording_connect(int fd, const struct sockaddr *addr, socklen_t length)
{
    note("connect", addr, length);
    return real_connect(fd, addr, length);
}

static ssize_t recording_sendto(int fd, const void *buffer, size_t size, int flags,
                                const struct sockaddr *addr, socklen_t length)
{
    if (addr != NULL) {
        note("sendto", addr, length);
    } else {
        note_peer("sendto", fd);
    }
    return real_sendto(fd, buffer, size, flags, addr, length);
}

static ssize_t recording_send(int fd, const void *buffer, size_t size, int flags)
{
    note_peer("send", fd);
    return real_send(fd, buffer, size, flags);
}

static ssize_t recording_sendmsg(int fd, const struct msghdr *message, int flags)
{
    if (message != NULL && message->msg_name != NULL) {
        note("sendmsg", (const struct sockaddr *)message->msg_name, message->msg_namelen);
    } else {
        note_peer("sendmsg", fd);
    }
    return real_sendmsg(fd, message, flags);
}

static void *replacement_for(const char *symbol)
{
    if (strcmp(symbol, "_connect") == 0) return (void *)recording_connect;
    if (strcmp(symbol, "_sendto") == 0) return (void *)recording_sendto;
    if (strcmp(symbol, "_send") == 0) return (void *)recording_send;
    if (strcmp(symbol, "_sendmsg") == 0) return (void *)recording_sendmsg;
    return NULL;
}

static int write_slot(void **slot, void *value, int read_only_segment)
{
    vm_size_t page = (vm_size_t)getpagesize();
    vm_address_t start = (vm_address_t)slot & ~(page - 1);
    if (vm_protect(mach_task_self(), start, page, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        return 0;
    }
    *slot = value;
    if (read_only_segment) {
        vm_protect(mach_task_self(), start, page, 0, VM_PROT_READ);
    }
    return 1;
}

// Walks the image's symbol-pointer sections (__got, __la_symbol_ptr, ...) and
// uses the indirect symbol table to find the slots of the four functions.
static int rebind_image(const struct mach_header_64 *header, intptr_t slide)
{
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64 &&
            strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (const struct segment_command_64 *)command;
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)command;
        }
        cursor += command->cmdsize;
    }
    if (linkedit == NULL || symtab == NULL || dysymtab == NULL || dysymtab->nindirectsyms == 0) {
        return 0;
    }
    uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkedit_base + symtab->symoff);
    const char *strings = (const char *)(linkedit_base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkedit_base + dysymtab->indirectsymoff);

    int installed = 0;
    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        cursor += command->cmdsize;
        if (command->cmd != LC_SEGMENT_64) {
            continue;
        }
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        int read_only = strcmp(segment->segname, "__DATA_CONST") == 0 || strcmp(segment->segname, "__AUTH_CONST") == 0;
        const struct section_64 *sections = (const struct section_64 *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++) {
            const struct section_64 *section = &sections[s];
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) {
                continue;
            }
            void **slots = (void **)((uintptr_t)slide + section->addr);
            uint64_t count = section->size / sizeof(void *);
            for (uint64_t k = 0; k < count; k++) {
                if (section->reserved1 + k >= dysymtab->nindirectsyms) {
                    break;
                }
                uint32_t index = indirect[section->reserved1 + k];
                if ((index & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) != 0 || index >= symtab->nsyms) {
                    continue;
                }
                void *replacement = replacement_for(strings + symbols[index].n_un.n_strx);
                if (replacement == NULL) {
                    continue;
                }
                if (slots[k] == replacement || write_slot(&slots[k], replacement, read_only)) {
                    installed++;
                }
            }
        }
    }
    return installed;
}

int iroh_send_recorder_install(const char *image_path_part)
{
    if (real_connect == NULL) {
        real_connect = (connect_fn)dlsym(RTLD_DEFAULT, "connect");
        real_sendto = (sendto_fn)dlsym(RTLD_DEFAULT, "sendto");
        real_send = (send_fn)dlsym(RTLD_DEFAULT, "send");
        real_sendmsg = (sendmsg_fn)dlsym(RTLD_DEFAULT, "sendmsg");
    }
    if (real_connect == NULL || real_sendto == NULL || real_send == NULL || real_sendmsg == NULL) {
        return 0;
    }
    int installed = 0;
    uint32_t images = _dyld_image_count();
    for (uint32_t i = 0; i < images; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        if (name == NULL || header == NULL || strstr(name, image_path_part) == NULL || header->magic != MH_MAGIC_64) {
            continue;
        }
        installed += rebind_image((const struct mach_header_64 *)header, _dyld_get_image_vmaddr_slide(i));
    }
    return installed;
}

void iroh_send_recorder_watch_ports(const uint16_t *ports, int count)
{
    pthread_mutex_lock(&recorder_lock);
    watched_count = count < MAX_PORTS ? count : MAX_PORTS;
    for (int i = 0; i < watched_count; i++) {
        watched_ports[i] = ports[i];
    }
    pthread_mutex_unlock(&recorder_lock);
}

void iroh_send_recorder_reset(void)
{
    pthread_mutex_lock(&recorder_lock);
    entry_count = 0;
    pthread_mutex_unlock(&recorder_lock);
}

int iroh_send_recorder_count(void)
{
    pthread_mutex_lock(&recorder_lock);
    int count = entry_count;
    pthread_mutex_unlock(&recorder_lock);
    return count;
}

int iroh_send_recorder_entry(int index, char *buffer, size_t capacity)
{
    pthread_mutex_lock(&recorder_lock);
    int found = index >= 0 && index < entry_count && index < MAX_ENTRIES && capacity > 0;
    if (found) {
        snprintf(buffer, capacity, "%s", entries[index]);
    }
    pthread_mutex_unlock(&recorder_lock);
    return found;
}
