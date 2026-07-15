#ifndef PLUTO_RUNTIME_DIRECT_CONTROL_SERVER_H_
#define PLUTO_RUNTIME_DIRECT_CONTROL_SERVER_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "pluto/presenter.h"

namespace pluto {

enum class DirectScreenshotSurface : std::uint8_t {
  kLogical,
  kPostDither,
};

const char *direct_screenshot_surface_name(DirectScreenshotSurface surface);

// One immutable screenshot returned by the embedder integration. The callback
// encodes PNG before returning so this transport layer has no renderer or image
// codec dependency. Every field is validated before an artifact is published.
struct DirectScreenshotCapture {
  std::vector<std::uint8_t> png;
  std::int32_t width = 0;
  std::int32_t height = 0;
  std::size_t stride = 0;
  PlutoPixelFormat format = kPlutoPixelFormatRgb565;
  std::string app_id;
  std::int64_t pid = 0;
  DirectScreenshotSurface surface = DirectScreenshotSurface::kLogical;
};

struct DirectControlFailure {
  std::string code;
  std::string message;
};

// requested_app_id is null for the foreground surface. A non-null id must only
// succeed when the callback can prove it identifies this process.
using DirectScreenshotHandler = std::function<bool(
    DirectScreenshotSurface surface,
    const std::optional<std::string> &requested_app_id,
    DirectScreenshotCapture *capture, DirectControlFailure *failure)>;

// Result of one root-local, deterministic pointer gesture. This is used by the
// real-device acceptance harness to exercise the same Flutter hit-test/input
// path on devices that cannot expose a kernel uinput device. Both the switcher
// tap and Ink stroke return this bounded identity receipt.
struct DirectPointerResult {
  std::string app_id;
  std::int64_t pid = 0;
  std::size_t event_count = 0;
};

using DirectPointerHandler = std::function<bool(
    const std::string &requested_app_id, DirectPointerResult *result,
    DirectControlFailure *failure)>;

// Result of the acceptance-only Ink canvas preparation flow. The caller binds
// the request to the foreground receipt it just read; the embedder must return
// that exact process and may invoke only Ink's bounded semantic actions.
struct DirectInkCanvasResult {
  std::string app_id;
  std::int64_t pid = 0;
  std::size_t action_count = 0;
  bool canvas_ready = false;
};

using DirectInkCanvasHandler = std::function<bool(
    const std::string &requested_app_id, std::int64_t expected_pid,
    DirectInkCanvasResult *result, DirectControlFailure *failure)>;

struct DirectControlServerConfig {
  std::string run_dir = "/run/pluto";
  std::size_t max_packet_bytes = 32768;
  DirectScreenshotHandler screenshot;
  DirectPointerHandler tap_switcher_preview;
  DirectInkCanvasHandler prepare_ink_canvas;
  DirectPointerHandler draw_stroke;
};

// Root-local control endpoint for the direct embedder. On Linux it publishes
// <run_dir>/embedder-control.sock as AF_UNIX/SOCK_SEQPACKET. The run directory
// is secured to 0700, the socket and screenshot files to 0600, and every peer
// must have the same effective uid as this process.
class DirectControlServer {
public:
  explicit DirectControlServer(DirectControlServerConfig config);
  DirectControlServer(const DirectControlServer &) = delete;
  DirectControlServer &operator=(const DirectControlServer &) = delete;
  ~DirectControlServer();

  // Idempotent while already running. The parent of run_dir must exist.
  bool start(std::string *error = nullptr);

  // Stops accepting, joins the worker, closes descriptors, and removes only
  // the exact socket inode created by this instance.
  void stop();

  bool running() const;
  std::string socket_path() const;

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace pluto

#endif // PLUTO_RUNTIME_DIRECT_CONTROL_SERVER_H_
