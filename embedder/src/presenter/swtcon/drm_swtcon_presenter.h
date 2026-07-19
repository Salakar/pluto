#ifndef PLUTO_PRESENTER_SWTCON_DRM_SWTCON_PRESENTER_H_
#define PLUTO_PRESENTER_SWTCON_DRM_SWTCON_PRESENTER_H_

#include "presenter/native/gallery3_drm_backend.h"

#ifdef __cplusplus
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace pluto::swtcon {

class DrmInterface;

// Presenter-internal Fast-latch mask primitive. OR the source coverage into
// destination coordinates, clipping to the exact rect intersection. Rows are
// LSB-first bit masks with independently padded byte strides. This is exposed
// here so the production reconciliation primitive has a direct unit/benchmark
// seam; callers must provide complete stride*height storage.
bool or_fast_coverage_overlap(PlutoRect source_rect,
                              std::span<const std::uint8_t> source_bits,
                              std::size_t source_stride,
                              PlutoRect destination_rect,
                              std::span<std::uint8_t> destination_bits,
                              std::size_t destination_stride);

// TEST-ONLY seam: the next non-dry-run open() consumes this interface in
// place of make_real_drm_interface(), so host tests can observe the DRM
// flip stream through the DrmInterface mock (drm_swtcon_device.h).
void set_drm_interface_for_testing(std::unique_ptr<DrmInterface> drm);

// TEST-ONLY seam for the positive exact-color device route. This exercises
// the same fixed-profile matcher used by production after reading immutable
// kernel identity. Every geometry field and both identity strings must match
// a complete profile row; sharing only the Move's visible dimensions is not
// sufficient.
bool color_handoff_profile_matches_for_testing(
    int width, int height, int engine_stride, std::uint32_t tile_px,
    int history_stride, int history_rows, std::string_view machine,
    std::string_view soc);

// TEST-ONLY seam for the production handoff namespace gate. This calls the
// real canonical-path, ownership, permissions, and tmpfs check; it does not
// substitute a host-friendly filesystem predicate.
bool production_handoff_path_is_secure_tmpfs_for_testing(
    const std::string &path);

// TEST-ONLY seam (content-consistency oracle): snapshot of the engine's
// settled-glass truth plane (PixelEngine prev plane, 5-bit levels,
// engine-stride rows). The copy is serviced ON the engine thread — the
// call blocks until the engine wakes and fulfills it — so it is safe
// against the engine-confined planes. Returns false when the presenter is
// closed or closing.
bool debug_glass_for_testing(PlutoPresenter *presenter,
                             std::vector<std::uint8_t> *out_levels,
                             int *out_width, int *out_height, int *out_stride);

// TEST-ONLY seam (double-scan recharge oracle): per-tile snapshot of the
// DC ledger's aggregate rescan account and stress accumulator, row-major
// over the tile grid (`out_tile_cols` columns). Serviced ON the engine
// thread like debug_glass_for_testing — the ledger is engine-confined.
// Returns false when the presenter is closed or closing.
bool debug_dc_for_testing(PlutoPresenter *presenter,
                          std::vector<std::int32_t> *out_rescan,
                          std::vector<std::uint16_t> *out_stress,
                          std::uint32_t *out_tile_cols);

// TEST-ONLY exact-color history oracle. Returns the committed Xochitl A/B
// words after the engine-thread latch fence has completed.
bool debug_color_history_for_testing(PlutoPresenter *presenter, int x, int y,
                                     std::uint16_t *out_a,
                                     std::uint16_t *out_b);

} // namespace pluto::swtcon
#endif // __cplusplus

#endif // PLUTO_PRESENTER_SWTCON_DRM_SWTCON_PRESENTER_H_
