#define _GNU_SOURCE

#include <fcntl.h>
#include <link.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

unsigned int la_version(unsigned int version) {
  (void)version;
  return LAV_CURRENT;
}

__attribute__((constructor)) static void mark_audit_dso_loaded(void) {
  const char* marker = getenv("PLUTO_LOADER_AUDIT_MARKER");
  if (marker == NULL || marker[0] == '\0') {
    return;
  }
  const int descriptor = open(marker, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (descriptor < 0) {
    return;
  }
  const char message[] = "audit-loaded\n";
  (void)write(descriptor, message, strlen(message));
  (void)close(descriptor);
}
