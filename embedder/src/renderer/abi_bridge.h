#ifndef PLUTO_RENDERER_ABI_BRIDGE_H_
#define PLUTO_RENDERER_ABI_BRIDGE_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/frame_ledger.h"

namespace pluto {

struct AbiPresentBridgeConfig {
  uint32_t width = 954;
  uint32_t height = 1696;
  // Clockwise logical-to-panel rotation. The bridge converts in logical
  // coordinates, then rotates both pixels and damage into panel coordinates.
  uint32_t rotation = 0;
  // Engine-true format of the transitional RGB565 mirror (the retained frame
  // FrameRenderer keeps for the settled-color paths).
  PlutoPixelFormat source_format = kPlutoPixelFormatRgb565;
  // Presenter surface format (PlutoDisplayInfo.preferred_format).
  PlutoPixelFormat target_format = kPlutoPixelFormatRgb565;
  // PlutoDisplayInfo.is_color: the glass can develop chroma.
  bool panel_is_color = false;
  // PlutoDisplayInfo.backend_quantizes_color: the backend (or its
  // downstream compositor, e.g. xochitl under qtfb) maps RGB to the panel
  // palette itself; settled color passes through as raw RGB instead of being
  // palette-crushed here.
  bool backend_quantizes_color = false;
};

// AbiPresentBridge (Stage-1 subset): the dispatch-time present conversion
// (it replaced the retired dispatch-time re-quantization pass of the
// pre-ledger renderer). Presentation pixels
// for the gray path come straight from the FrameLedger's settled 5-bit
// levels via the levels->gray8/RGB565 span kernels — no re-quantization at
// dispatch, so presented bytes are the exact bytes the diff ran on.
//
// Class policy (Stage 1; "color is a settled state, not feedback"):
//   sub-Full (fast/ui/text) -> settled 16-gray from L_cur; PreDithered SET.
//       (The legacy 4-gray/mono fast-class crush is intentionally NOT
//       reproduced: rail targets are derived at admission from Stage 4 on,
//       never at quantize/dispatch time.)
//   full, mono panel        -> settled 16-gray from L_cur; PreDithered SET.
//   full, color panel       -> backend_quantizes_color: raw RGB565 copied
//       from the retained mirror; PreDithered UNSET (qtfb/xochitl must see
//       raw RGB — pinned flag contract). Otherwise Gallery-3 palette dither
//       from the mirror; PreDithered SET.
//
// Every conversion depends only on (pixel value, absolute panel coordinates),
// so the rect-local determinism invariant holds: converting any rect is
// byte-identical to converting the whole frame and cropping — partial
// updates can never seam.
//
class AbiPresentBridge {
 public:
  AbiPresentBridge() = default;

  void configure(const AbiPresentBridgeConfig& config);

  // Whether prepare() converts content. False when the target format is
  // unsupported; prepare() then passes requests through untouched (the
  // caller decides whether to present raw bytes or fail loudly).
  bool valid() const { return valid_; }

  const AbiPresentBridgeConfig& config() const { return config_; }

  // Converts the request's damage rects into the internal present buffer and
  // returns a request pointing at it. The incoming request's surface is the
  // engine-true RGB565 mirror (consumed only on the settled-color paths);
  // `ledger` supplies the settled levels for the gray path. Sets
  // kPlutoPresentFlagPreDithered exactly when the content was quantized
  // for glass; the delegated settled-color path keeps the mirror bytes and
  // the flag unset. The bridge never invents or overlays pen pixels.
  PlutoPresentRequest prepare(const PlutoPresentRequest &in,
                                const FrameLedger &ledger);

  // Present-buffer access for tests.
  const uint8_t* present_data() const { return present_frame_.data(); }
  size_t present_stride() const { return target_stride_; }

  /// Panel-oriented buffer returned to the presenter for non-zero rotation.
  const uint8_t* panel_data() const { return panel_frame_.data(); }
  size_t panel_stride() const { return panel_stride_; }

 private:
  void copy_rect_from_mirror(const PlutoSurface& src,
                             const PlutoRect& rect);
  void fill_rect_solid(const PlutoRect& rect, bool white);
  void convert_rect_gallery3(const PlutoSurface& src,
                             const PlutoRect& rect);
  void convert_rect_levels(const FrameLedger& ledger, const PlutoRect& rect);

  AbiPresentBridgeConfig config_{};
  bool valid_ = false;
  size_t target_stride_ = 0;
  std::vector<uint8_t> present_frame_;
  uint32_t panel_width_ = 0;
  uint32_t panel_height_ = 0;
  size_t panel_stride_ = 0;
  std::vector<uint8_t> panel_frame_;
  std::vector<PlutoRect> panel_damage_;
};

}  // namespace pluto

#endif  // PLUTO_RENDERER_ABI_BRIDGE_H_
