#ifndef ResolverBridge_h
#define ResolverBridge_h

#include <stddef.h>

/// Writes the DNS servers the system is configured with into `buffer`, one numeric address
/// per line, and returns how many. `<resolv.h>` is not part of the module Swift sees on iOS,
/// so the resolver is read here and only text crosses over.
int sensorstorm_copy_dns_servers(char *buffer, size_t size);

#endif
