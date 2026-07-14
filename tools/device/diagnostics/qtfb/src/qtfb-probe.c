/* qtfb-probe — isolated Stage-0 on-glass diagnostic for the reMarkable
 * Paper Pro Move. Connects to the qtfb shared-memory framebuffer server hosted
 * inside xochitl (via xovi/AppLoad), paints an 8x8 RGB565 checkerboard, then
 * animates a moving 128x128 black square, submitting a PARTIAL damage update for
 * only the changed region each frame. No Flutter engine involved — this isolates
 * the display path (our pixels -> qtfb -> xochitl SWTCON -> e-ink glass).
 *
 * Proves nothing until run on-device as an AppLoad app backend; see README.md.
 * Protocol: src/qtfb_proto.h.
 */
#define _GNU_SOURCE /* clock_gettime, CLOCK_MONOTONIC, usleep */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "qtfb_proto.h"

#define PANEL_W 954
#define PANEL_H 1696
#define SQUARE  128
#define FRAMES  200
#define STEP    24
#define FRAME_US 300000 /* 300 ms between updates */

static volatile sig_atomic_t g_stop = 0;
static void on_term(int sig) { (void)sig; g_stop = 1; }

static long long mono_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* RGB565 */
static const uint16_t BLACK = 0x0000;
static const uint16_t WHITE = 0xFFFF;

static void fill_checker(uint16_t *fb, int w, int h, int stride_px) {
  for (int y = 0; y < h; y++) {
    uint16_t *row = fb + (size_t)y * stride_px;
    for (int x = 0; x < w; x++) {
      int on = ((x >> 3) + (y >> 3)) & 1; /* 8px blocks */
      row[x] = on ? BLACK : WHITE;
    }
  }
}

static void fill_rect(uint16_t *fb, int stride_px, int x0, int y0, int w, int h,
                      uint16_t color) {
  for (int y = y0; y < y0 + h; y++) {
    uint16_t *row = fb + (size_t)y * stride_px;
    for (int x = x0; x < x0 + w; x++) row[x] = color;
  }
}

int main(int argc, char **argv) {
  signal(SIGTERM, on_term);
  signal(SIGINT, on_term);

  /* AppLoad starts backends with argv[1] = a temporary unix socket; log it. */
  const char *appload_sock = (argc > 1) ? argv[1] : "(none)";
  const char *key_env = getenv("QTFB_KEY");
  FBKey key = key_env ? (FBKey)strtoul(key_env, NULL, 10) : QTFB_DEFAULT_FRAMEBUFFER;
  fprintf(stderr, "[qtfb-probe] appload_sock=%s QTFB_KEY=%u\n", appload_sock, key);

  /* 1) connect to the qtfb server (SEQPACKET is required). */
  int sock = socket(AF_UNIX, SOCK_SEQPACKET, 0);
  if (sock < 0) { perror("socket"); return 2; }
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, QTFB_SOCKET_PATH, sizeof(addr.sun_path) - 1);
  if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    fprintf(stderr, "[qtfb-probe] connect(%s) failed: %d\n", QTFB_SOCKET_PATH, errno);
    return 3;
  }

  /* 2) CUSTOM_INITIALIZE at 954x1696 RGB565 (the Move needs an explicit size). */
  struct ClientMessage init;
  memset(&init, 0, sizeof(init));
  init.type = MESSAGE_CUSTOM_INITIALIZE;
  init.customInit.framebufferKey = key;
  init.customInit.framebufferType = FBFMT_RMPP_RGB565;
  init.customInit.width = PANEL_W;
  init.customInit.height = PANEL_H;
  if (send(sock, &init, sizeof(init), 0) < 0) { perror("send init"); return 4; }

  struct ServerMessage resp;
  memset(&resp, 0, sizeof(resp));
  if (recv(sock, &resp, sizeof(resp), 0) < 1) { perror("recv init"); return 5; }
  fprintf(stderr, "[qtfb-probe] server shmKey=%d shmSize=%zu\n",
          resp.init.shmKeyDefined, resp.init.shmSize);

  /* 3) map the shared framebuffer the server allocated. */
  QTFB_FORMAT_SHM(shm_name, resp.init.shmKeyDefined);
  int fd = shm_open(shm_name, O_RDWR, 0);
  if (fd < 0) { fprintf(stderr, "[qtfb-probe] shm_open(%s) failed: %d\n", shm_name, errno); return 6; }
  size_t shm_size = resp.init.shmSize;
  uint16_t *fb = mmap(NULL, shm_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (fb == MAP_FAILED) { perror("mmap"); return 7; }

  /* Assume tightly-packed RGB565 (stride == width). If the server padded rows,
   * shm_size > W*H*2; log the discrepancy for on-device verification. */
  int stride_px = PANEL_W;
  size_t expect = (size_t)PANEL_W * PANEL_H * 2;
  if (shm_size != expect)
    fprintf(stderr, "[qtfb-probe] NOTE shmSize=%zu != W*H*2=%zu (stride may differ)\n",
            shm_size, expect);

  /* 4) full checkerboard + complete update. */
  fill_checker(fb, PANEL_W, PANEL_H, stride_px);
  struct ClientMessage upd;
  memset(&upd, 0, sizeof(upd));
  upd.type = MESSAGE_UPDATE;
  upd.update.type = UPDATE_ALL;
  send(sock, &upd, sizeof(upd), 0);
  fprintf(stderr, "[qtfb-probe] t=%lld checkerboard + full update sent\n", mono_ms());

  /* 5) animate a moving black square; PARTIAL-update the bounding box each frame. */
  int px = 0, py = 0;
  for (int i = 0; i < FRAMES && !g_stop; i++) {
    int nx = (px + STEP) % (PANEL_W - SQUARE);
    int ny = (py + STEP) % (PANEL_H - SQUARE);
    /* erase old (white), draw new (black) */
    fill_rect(fb, stride_px, px, py, SQUARE, SQUARE, WHITE);
    fill_rect(fb, stride_px, nx, ny, SQUARE, SQUARE, BLACK);
    int bx = px < nx ? px : nx, by = py < ny ? py : ny;
    int bw = (px < nx ? nx - px : px - nx) + SQUARE;
    int bh = (py < ny ? ny - py : py - ny) + SQUARE;
    memset(&upd, 0, sizeof(upd));
    upd.type = MESSAGE_UPDATE;
    upd.update.type = UPDATE_PARTIAL;
    upd.update.x = bx; upd.update.y = by; upd.update.w = bw; upd.update.h = bh;
    send(sock, &upd, sizeof(upd), 0);
    fprintf(stderr, "[qtfb-probe] t=%lld frame=%d square=(%d,%d) damage=(%d,%d,%d,%d)\n",
            mono_ms(), i, nx, ny, bx, by, bw, bh);
    px = nx; py = ny;
    usleep(FRAME_US);
  }

  fprintf(stderr, "[qtfb-probe] done (stop=%d)\n", (int)g_stop);
  munmap(fb, shm_size);
  close(fd);
  close(sock);
  return 0;
}
