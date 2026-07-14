#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_PACKET 32768
#define TIMEOUT_MS 5000

static void usage(FILE *stream) {
  fprintf(stream, "usage: pluto-controlctl --socket PATH --request JSON\n");
}

static int fail(const char *message) {
  fprintf(stderr, "pluto-controlctl: %s: %s\n", message, strerror(errno));
  return 1;
}

int main(int argc, char **argv) {
  const char *socket_path = NULL;
  const char *request = NULL;
  for (int index = 1; index < argc; ++index) {
    if (strcmp(argv[index], "--socket") == 0 && index + 1 < argc) {
      socket_path = argv[++index];
    } else if (strcmp(argv[index], "--request") == 0 && index + 1 < argc) {
      request = argv[++index];
    } else if (strcmp(argv[index], "--help") == 0) {
      usage(stdout);
      return 0;
    } else {
      usage(stderr);
      return 64;
    }
  }
  if (socket_path == NULL || request == NULL) {
    usage(stderr);
    return 64;
  }

  const size_t request_length = strlen(request);
  const size_t socket_length = strlen(socket_path);
  if (request_length == 0 || request_length > MAX_PACKET ||
      socket_length == 0 ||
      socket_length >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    fprintf(stderr, "pluto-controlctl: request or socket path is invalid\n");
    return 64;
  }

  struct stat socket_stat;
  if (lstat(socket_path, &socket_stat) != 0) {
    return fail("cannot inspect control socket");
  }
  if (!S_ISSOCK(socket_stat.st_mode) || socket_stat.st_uid != 0 ||
      (socket_stat.st_mode & 077) != 0) {
    fprintf(stderr,
            "pluto-controlctl: refusing an untrusted control socket\n");
    return 77;
  }

  int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
  if (fd < 0) {
    return fail("cannot create socket");
  }
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
    const int saved = errno;
    close(fd);
    errno = saved;
    return fail("cannot secure socket descriptor");
  }
  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, socket_path, socket_length + 1);
  const socklen_t address_length =
      (socklen_t)(offsetof(struct sockaddr_un, sun_path) + socket_length + 1);
  if (connect(fd, (struct sockaddr *)&address, address_length) != 0) {
    const int saved = errno;
    close(fd);
    errno = saved;
    return fail("cannot connect to control socket");
  }

  struct pollfd poll_fd = {.fd = fd, .events = POLLOUT, .revents = 0};
  if (poll(&poll_fd, 1, TIMEOUT_MS) != 1) {
    const int saved = errno == 0 ? ETIMEDOUT : errno;
    close(fd);
    errno = saved;
    return fail("timed out sending request");
  }
  const ssize_t sent = send(fd, request, request_length, MSG_NOSIGNAL);
  if (sent != (ssize_t)request_length) {
    const int saved = errno == 0 ? EIO : errno;
    close(fd);
    errno = saved;
    return fail("could not send complete request");
  }

  poll_fd.events = POLLIN;
  poll_fd.revents = 0;
  if (poll(&poll_fd, 1, TIMEOUT_MS) != 1) {
    const int saved = errno == 0 ? ETIMEDOUT : errno;
    close(fd);
    errno = saved;
    return fail("timed out waiting for response");
  }
  char response[MAX_PACKET + 1];
  const ssize_t received = recv(fd, response, MAX_PACKET + 1, 0);
  const int saved = errno;
  close(fd);
  if (received <= 0 || received > MAX_PACKET) {
    errno = received < 0 ? saved : EMSGSIZE;
    return fail("invalid response packet");
  }
  response[received] = '\0';
  if (memchr(response, '\0', (size_t)received) != NULL) {
    fprintf(stderr, "pluto-controlctl: response contains an embedded NUL\n");
    return 76;
  }
  if (fwrite(response, 1, (size_t)received, stdout) != (size_t)received ||
      fputc('\n', stdout) == EOF) {
    return fail("could not write response");
  }
  return 0;
}
