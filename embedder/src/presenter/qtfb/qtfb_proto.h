/* qtfb wire protocol, vendored from asivery/qtfb common.h via
 * tools/device/diagnostics/qtfb/src/qtfb_proto.h.
 *
 * The AppLoad qtfb server is built with default compiler struct packing.
 * Do not add pragma-pack attributes here; the padding is part of the ABI.
 */
#ifndef PLUTO_PRESENTER_QTFB_QTFB_PROTO_H_
#define PLUTO_PRESENTER_QTFB_QTFB_PROTO_H_

#include <cstddef>
#include <cstdint>

namespace pluto::qtfb {

inline constexpr int kDefaultFramebuffer = 245209899;
inline constexpr const char *kDefaultSocketPath = "/tmp/qtfb.sock";
inline constexpr int kRm2Width = 1404;
inline constexpr int kRm2Height = 1872;
inline constexpr int kRmppWidth = 1620;
inline constexpr int kRmppHeight = 2160;
inline constexpr int kRmppmWidth = 954;
inline constexpr int kRmppmHeight = 1696;
// Historical aliases retain the default Paper Pro Move geometry.
inline constexpr int kPanelWidth = kRmppmWidth;
inline constexpr int kPanelHeight = kRmppmHeight;
inline constexpr int kRgb565BytesPerPixel = 2;

enum FramebufferFormat : std::uint8_t {
  kFbFmtRm2fb = 0,
  kFbFmtRmppRgb888 = 1,
  kFbFmtRmppRgba8888 = 2,
  kFbFmtRmppRgb565 = 3,
  kFbFmtRmppmRgb888 = 4,
  kFbFmtRmppmRgba8888 = 5,
  kFbFmtRmppmRgb565 = 6,
};

enum MessageType : std::uint8_t {
  kMessageInitialize = 0,
  kMessageUpdate = 1,
  kMessageCustomInitialize = 2,
  kMessageTerminate = 3,
  kMessageUserInput = 4,
  kMessageSetRefreshMode = 5,
  kMessageRequestFullRefresh = 6,
};

enum UpdateType : int {
  kUpdateAll = 0,
  kUpdatePartial = 1,
};

enum RefreshMode : int {
  kRefreshModeUfast = 0,
  kRefreshModeFast = 1,
  kRefreshModeAnimate = 2,
  kRefreshModeContent = 3,
  kRefreshModeUi = 4,
};

enum UserInputType : int {
  kInputTouchPress = 0x10,
  kInputTouchRelease = 0x11,
  kInputTouchUpdate = 0x12,
  kInputPenPress = 0x20,
  kInputPenRelease = 0x21,
  kInputPenUpdate = 0x22,
  kInputButtonPress = 0x30,
  kInputButtonRelease = 0x31,
  kInputVirtualKeyboardPress = 0x40,
  kInputVirtualKeyboardRelease = 0x41,
};

using FBKey = int;

struct InitMessageContents {
  FBKey framebufferKey;
  std::uint8_t framebufferType;
};

struct CustomInitMessageContents {
  FBKey framebufferKey;
  std::uint8_t framebufferType;
  std::uint16_t width;
  std::uint16_t height;
};

struct InitMessageResponseContents {
  int shmKeyDefined;
  std::size_t shmSize;
};

struct UpdateRegionMessageContents {
  int type;
  int x;
  int y;
  int w;
  int h;
};

struct UserInputContents {
  int inputType;
  int devId;
  int x;
  int y;
  int d;
};

struct ClientMessage {
  std::uint8_t type;
  union {
    InitMessageContents init;
    UpdateRegionMessageContents update;
    CustomInitMessageContents customInit;
    int refreshMode;
  };
};

struct ServerMessage {
  std::uint8_t type;
  union {
    InitMessageResponseContents init;
    UserInputContents userInput;
  };
};

static_assert(sizeof(ClientMessage) == 24,
              "qtfb ClientMessage must use default native packing");
static_assert(sizeof(InitMessageContents) == 8,
              "qtfb InitMessageContents layout drifted");
static_assert(sizeof(CustomInitMessageContents) == 12,
              "qtfb CustomInitMessageContents layout drifted");
static_assert(sizeof(UpdateRegionMessageContents) == 20,
              "qtfb UpdateRegionMessageContents layout drifted");
static_assert(sizeof(UserInputContents) == 20,
              "qtfb UserInputContents layout drifted");
static_assert(offsetof(ClientMessage, init) == 4,
              "qtfb ClientMessage union offset must match AppLoad");
static_assert(sizeof(std::size_t) == 4 || sizeof(std::size_t) == 8,
              "qtfb supports only ILP32 and LP64 ABIs");
static_assert(sizeof(InitMessageResponseContents) ==
                  (sizeof(std::size_t) == 4 ? 8u : 16u),
              "qtfb InitMessageResponseContents layout drifted");
static_assert(sizeof(ServerMessage) == (sizeof(std::size_t) == 4 ? 24u : 32u),
              "qtfb ServerMessage must match the native AppLoad ABI");
static_assert(offsetof(ServerMessage, init) ==
                  (sizeof(std::size_t) == 4 ? 4u : 8u),
              "qtfb ServerMessage union offset must match AppLoad");
static_assert(offsetof(ServerMessage, userInput) ==
                  offsetof(ServerMessage, init),
              "qtfb ServerMessage union members must overlap");

} // namespace pluto::qtfb

#endif // PLUTO_PRESENTER_QTFB_QTFB_PROTO_H_
