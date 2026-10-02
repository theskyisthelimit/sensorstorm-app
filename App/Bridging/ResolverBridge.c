#include "ResolverBridge.h"

#include <netdb.h>
#include <netinet/in.h>
#include <resolv.h>
#include <string.h>
#include <sys/socket.h>

int sensorstorm_copy_dns_servers(char *buffer, size_t size) {
    if (buffer == NULL || size == 0) return 0;
    buffer[0] = '\0';

    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) return 0;

    union res_sockaddr_union servers[8];
    memset(servers, 0, sizeof(servers));
    int count = res_getservers(&state, servers, 8);

    int written = 0;
    size_t used = 0;
    for (int index = 0; index < count && index < 8; index++) {
        char host[NI_MAXHOST];
        struct sockaddr *address = (struct sockaddr *)&servers[index];
        socklen_t length = servers[index].sin.sin_len != 0 ? servers[index].sin.sin_len
                                                           : (socklen_t)sizeof(struct sockaddr_in);
        if (getnameinfo(address, length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) continue;
        size_t needed = strlen(host);
        if (used + needed + 2 > size) break;
        memcpy(buffer + used, host, needed);
        buffer[used + needed] = '\n';
        used += needed + 1;
        buffer[used] = '\0';
        written++;
    }
    res_ndestroy(&state);
    return written;
}
