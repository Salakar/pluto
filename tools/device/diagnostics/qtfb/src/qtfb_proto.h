/* qtfb wire protocol — vendored from asivery/qtfb common.h. Plain C, DEFAULT
 * struct packing: the qtfb server (appload.so) is compiled with gcc-aarch64
 * defaults, so we must match its layout exactly — do NOT add #pragma pack. */
#ifndef QTFB_PROTO_H_
#define QTFB_PROTO_H_
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#define QTFB_DEFAULT_FRAMEBUFFER 245209899
#define QTFB_SOCKET_PATH "/tmp/qtfb.sock"
/* shm object name for a given key, e.g. "/qtfb_245209899" */
#define QTFB_FORMAT_SHM(var, key) char var[24]; snprintf(var, sizeof(var), "/qtfb_%d", (key))

/* pixel formats */
#define FBFMT_RM2FB         0
#define FBFMT_RMPP_RGB888   1
#define FBFMT_RMPP_RGBA8888 2
#define FBFMT_RMPP_RGB565   3   /* Paper Pro Move panel-native */

/* client message types */
#define MESSAGE_INITIALIZE        0
#define MESSAGE_UPDATE            1
#define MESSAGE_CUSTOM_INITIALIZE 2   /* Move: pass explicit W×H */

/* update region types */
#define UPDATE_ALL     0
#define UPDATE_PARTIAL 1

typedef unsigned int FBKey;

struct InitMessageContents { FBKey framebufferKey; uint8_t framebufferType; };
struct CustomInitMessageContents {
  FBKey framebufferKey; uint8_t framebufferType; uint16_t width; uint16_t height;
};
struct InitMessageResponseContents { int shmKeyDefined; size_t shmSize; };
struct UpdateRegionMessageContents { int type; int x, y, w, h; };

struct ClientMessage {
  uint8_t type;
  union {
    struct InitMessageContents init;
    struct UpdateRegionMessageContents update;
    struct CustomInitMessageContents customInit;
  };
};

struct ServerMessage { uint8_t type; struct InitMessageResponseContents init; };

#endif /* QTFB_PROTO_H_ */
