#ifndef PLUTO_PRESENTER_SWTCON_XOCHITL_HISTORY_STATE_H_
#define PLUTO_PRESENTER_SWTCON_XOCHITL_HISTORY_STATE_H_

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <unordered_map>
#include <utility>
#include <vector>

namespace pluto::swtcon {

// Transactional owner for Xochitl 3.27's persistent Gallery-3 A/B history.
//
// Mapping is deliberately split into prepare and commit.  Prepare snapshots
// one committed generation, evaluates the complete vector-padded operation,
// and returns an immutable journal without changing history.  Only commit()
// installs A2/B2.  A discarded, invalidated, or generation-stale journal can
// therefore never make an optical successor start from a state that was not
// actually admitted.
//
// This component consumes an already-produced operation-local ct33 byte
// plane.  Selector production and scan ownership are separate gates.
class XochitlHistoryState final {
public:
  static constexpr std::int32_t kLogicalWidth = 954;
  static constexpr std::int32_t kPackedDriveWidth = 960;
  static constexpr std::int32_t kLogicalHeight = 1696;
  static constexpr std::int32_t kStorageStride = 968;
  static constexpr std::int32_t kStorageRows = 1698;
  static constexpr std::size_t kStoragePixels =
      static_cast<std::size_t>(kStorageStride) * kStorageRows;
  static constexpr std::size_t kTransitionCount = 32u * 32u;

  struct HistoryPixel {
    std::uint16_t a = 0;
    std::uint16_t b = 0;

    friend bool operator==(const HistoryPixel &,
                           const HistoryPixel &) = default;
  };
  static_assert(sizeof(HistoryPixel) == 4);

  struct InclusiveRect {
    std::int32_t left = 0;
    std::int32_t top = 0;
    std::int32_t right = -1;
    std::int32_t bottom = -1;

    friend bool operator==(const InclusiveRect &,
                           const InclusiveRect &) = default;
  };

  enum class Mode : std::int16_t {
    kText = 1,
    kContent = 2,
    kUi = 5,
    kFull = 6,
    kFast = 7,
  };

  enum class OperationKind : std::uint8_t {
    kLegacy,
    kFastSource,
    kFastContinuation,
  };

  enum class PrepareError : std::uint8_t {
    kNone,
    kInvalidHistory,
    kInvalidGeometry,
    kBufferTooSmall,
    kInvalidMode,
    kUnsupportedPaletteState,
    kInvalidTemperature,
    kStaleGeneration,
    kStaleRegion,
    kOperationIdExhausted,
    kInvalidMask,
  };

  enum class FinalizeStatus : std::uint8_t {
    kCommitted,
    kDiscarded,
    kInvalidHistory,
    kForeignOperation,
    kStaleGeneration,
    kStaleRegion,
    kNotOutstanding,
  };

  // One row-major lane in PreparedOperation::lanes().  The requested and
  // execution rectangles make its absolute coordinate unambiguous.
  struct LaneJournal {
    std::uint16_t transition = 0;
    std::uint16_t a2 = 0;
    std::uint16_t b2 = 0;

    friend bool operator==(const LaneJournal &, const LaneJournal &) = default;
  };
  static_assert(sizeof(LaneJournal) == 6);

  class PreparedOperation final {
  public:
    OperationKind kind() const { return kind_; }
    Mode mode() const { return mode_; }
    // Owner-local stable key for scan metadata; never use pointer identity.
    std::uint64_t operation_id() const { return operation_id_; }
    std::uint64_t base_generation() const { return base_generation_; }
    InclusiveRect requested() const { return requested_; }
    InclusiveRect execution() const { return execution_; }
    std::int32_t width() const { return width_; }
    std::int32_t height() const { return height_; }
    bool has_pending_flags() const { return has_pending_flags_; }
    std::span<const LaneJournal> lanes() const { return lanes_; }
    // Compact immutable sweep plane. This duplicates LaneJournal::transition
    // at prepare time while the value is already live in a register, avoiding
    // an admission-time gather from the 6-byte journal AoS.
    std::span<const std::uint16_t> transitions() const { return transitions_; }
    // Empty means the legacy dense operation: every execution lane is
    // selected. Masked operations store one canonical byte per execution
    // lane so the mapper, engine cursor and transactional commit share the
    // exact same coverage proof.
    std::span<const std::uint8_t> lane_mask() const { return lane_mask_; }
    bool masked() const { return !lane_mask_.empty(); }
    bool lane_selected(std::size_t lane) const {
      return lane_mask_.empty() || lane_mask_[lane] != 0u;
    }
    std::size_t journal_storage_bytes() const {
      return lanes_.capacity() * sizeof(LaneJournal) +
             transitions_.capacity() * sizeof(std::uint16_t) +
             lane_mask_.capacity() * sizeof(std::uint8_t) +
             tile_versions_.capacity() * sizeof(std::uint64_t);
    }

  private:
    friend class XochitlHistoryState;

    PreparedOperation(std::uint64_t owner_id, std::uint64_t operation_id,
                      std::uint64_t base_generation, OperationKind kind,
                      Mode mode, InclusiveRect requested,
                      InclusiveRect execution, std::int32_t width,
                      std::int32_t height, bool has_pending_flags,
                      std::vector<LaneJournal> lanes,
                      std::vector<std::uint16_t> transitions,
                      std::vector<std::uint8_t> lane_mask,
                      std::uint64_t seed_epoch, std::size_t first_tile_x,
                      std::size_t first_tile_y, std::size_t tile_columns,
                      std::size_t tile_rows,
                      std::vector<std::uint64_t> tile_versions);

    std::uint64_t owner_id_ = 0;
    std::uint64_t operation_id_ = 0;
    std::uint64_t base_generation_ = 0;
    OperationKind kind_ = OperationKind::kLegacy;
    Mode mode_ = Mode::kContent;
    InclusiveRect requested_{};
    InclusiveRect execution_{};
    std::int32_t width_ = 0;
    std::int32_t height_ = 0;
    bool has_pending_flags_ = false;
    std::vector<LaneJournal> lanes_;
    std::vector<std::uint16_t> transitions_;
    std::vector<std::uint8_t> lane_mask_;
    std::uint64_t seed_epoch_ = 0;
    std::size_t first_tile_x_ = 0;
    std::size_t first_tile_y_ = 0;
    std::size_t tile_columns_ = 0;
    std::size_t tile_rows_ = 0;
    // Tile indices form a rectangular grid, so storing an index beside every
    // version wastes one machine word per 8x2 tile. Indices are reconstructed
    // from the four geometry fields above in row-major order.
    std::vector<std::uint64_t> tile_versions_;
  };

  struct PrepareResult {
    PrepareError error = PrepareError::kNone;
    std::shared_ptr<const PreparedOperation> operation;

    explicit operator bool() const {
      return error == PrepareError::kNone && operation != nullptr;
    }
  };

  XochitlHistoryState();
  ~XochitlHistoryState() = default;
  XochitlHistoryState(const XochitlHistoryState &) = delete;
  XochitlHistoryState &operator=(const XochitlHistoryState &) = delete;
  XochitlHistoryState(XochitlHistoryState &&) = delete;
  XochitlHistoryState &operator=(XochitlHistoryState &&) = delete;

  // Safe initialization after a known cold clear.  The same logical A state
  // and B=0 are installed across 954 logical columns, the 960-wide packed
  // drive domain, and the remaining 968-stride / 1698-row history guards.
  // Xochitl white is normally logical state 30.
  bool initialize_cold_clear(std::uint16_t logical_a = 30);

  // Exact future handoff surface.  The seed must contain all 968x1698 pixels
  // and every A word may use only low5 plus marker bits 6/7 (bit 5 is not a
  // Xochitl A flag).  Any failed seed invalidates and clears existing history.
  bool seed_full_plane(std::span<const HistoryPixel> seed);
  // Wire-friendly equivalent for the handoff bundle's host-value layout
  // [A0,B0,A1,B1,...]. Avoids aliasing a uint16_t allocation as HistoryPixel
  // and reuses the already configured committed plane without projection
  // scratch.
  bool seed_full_plane_interleaved(
      std::span<const std::uint16_t> interleaved_ab);

  // Unknown optical state is a hard generation boundary.  It clears the
  // plane and all outstanding journals; prepare/commit remain disabled until
  // a successful cold-clear initialization or exact seed.
  void invalidate();

  // Intentional latency preemption boundary: invalidate every outstanding
  // journal and disable prepare/commit, but retain committed bytes so a later
  // regional Fast-endpoint reseed can preserve unaffected history exactly.
  // Unknown scan evidence must use invalidate(), which clears everything.
  void invalidate_preserving_committed_for_reseed();

  // Restore one known terminal Fast region as A=logical endpoint, B=0. Input
  // is tight to `update` (or `levels_stride`), while the write follows mapper
  // execution rounding (8 columns x 2 rows) and replicates the requested
  // right/bottom edge into guard lanes. Outside committed history is retained.
  // Success is a global seed/generation boundary and consumes all outstanding
  // journals; callers must prepare every successor afterwards.
  bool reseed_region_from_levels(InclusiveRect update,
                                 std::span<const std::uint8_t> levels,
                                 std::size_t levels_stride);

  // Commit positively latched Fast lanes back into A/B without creating a
  // global history boundary. `raw` and the LSB-first `driven_bits` are both
  // execution-local: row 0/bit 0 is execution.{left,top}. Execution must be
  // the mapper's exact left/top-anchored 8x2 rounding of requested. low5==7
  // is white and every other raw value is black. Only mask-set lanes install:
  //   A = (raw & bit7) | (white ? 28 : 2), B = 0
  // (bit6 is deliberately cleared). Unmarked visible padding is preserved;
  // only storage guards beyond x=953/y=1695 replicate a marked physical edge
  // lane. Only actually written 8x2 MVCC stamps advance:
  // overlapping journals become stale while disjoint outstanding journals
  // remain admissible and may still commit. Invalid input is rejected without
  // mutating valid history, its seed epoch, or any outstanding journal.
  bool reseed_fast_region_from_raw(InclusiveRect requested,
                                   InclusiveRect execution,
                                   std::span<const std::uint8_t> raw,
                                   std::size_t raw_stride,
                                   std::span<const std::uint8_t> driven_bits,
                                   std::size_t driven_stride_bytes);

  bool valid() const;
  // Opaque owner binding for admission gates. PreparedOperation owner ids stay
  // private; consumers can reject a journal paired with the wrong state owner
  // before any optical phase is emitted.
  bool owns(const PreparedOperation &operation) const {
    return operation.owner_id_ == owner_id_;
  }
  // Full pre-drive journal gate. Unlike owns(), this proves the operation is
  // still outstanding in the current seed epoch and all conservative 8x2
  // region stamps remain current.
  bool admissible(const PreparedOperation &operation) const;
  std::uint64_t generation() const;
  std::size_t outstanding_count() const;
  std::size_t owned_plane_storage_bytes() const;
  std::optional<HistoryPixel> pixel(std::int32_t x, std::int32_t y) const;
  std::vector<HistoryPixel> snapshot_full_plane() const;
  // Quiescent handoff export in the bundle's host-value staging layout.
  // Refuses invalid history or any outstanding journal and fills caller
  // storage directly, avoiding a second full-plane projection.
  bool export_full_plane_interleaved(
      std::vector<std::uint16_t> *out_interleaved_ab) const;

  // Exact installed read-only palette.  Returns null for a fabricated enum.
  static const std::array<std::uint8_t, 16> *mode_palette(Mode mode);

  // Legacy modes 1/2/5/6 use the supplied mapper-oriented delta table.
  // `raw` is operation-local: raw[0] is update.{left,top}, not panel origin.
  PrepareResult prepare_legacy(Mode mode, InclusiveRect update,
                               std::span<const std::uint8_t> raw,
                               std::size_t raw_stride,
                               std::span<const std::int16_t> delta,
                               std::span<const std::uint8_t> lane_mask = {});

  PrepareResult prepare_fast_source(InclusiveRect update,
                                    std::span<const std::uint8_t> raw,
                                    std::size_t raw_stride,
                                    float temperature_c);

  PrepareResult prepare_fast_continuation(InclusiveRect update,
                                          float temperature_c);

  // Commit is atomic with respect to every other state operation.  It
  // succeeds only while the journal is outstanding and its generation is
  // still the committed regional version.  Conservative 8x2 history-tile
  // stamps let disjoint siblings commit while overlapping siblings go stale.
  FinalizeStatus commit(const PreparedOperation &operation);

  // Discard consumes an outstanding journal without touching A/B or the
  // generation.  Copies of the discarded immutable journal cannot commit.
  FinalizeStatus discard(const PreparedOperation &operation);

private:
  friend struct XochitlHistoryStateTestAccess;

  struct FrozenOperation {
    std::uint64_t generation = 0;
    std::uint64_t seed_epoch = 0;
    InclusiveRect requested{};
    InclusiveRect execution{};
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::vector<HistoryPixel> history;
    std::size_t first_tile_x = 0;
    std::size_t first_tile_y = 0;
    std::size_t tile_columns = 0;
    std::size_t tile_rows = 0;
    std::vector<std::uint64_t> tile_versions;
  };

  PrepareResult freeze(InclusiveRect update, FrozenOperation *frozen) const;
  PrepareResult prepare_legacy_with_stripes(
      Mode mode, InclusiveRect update, std::span<const std::uint8_t> raw,
      std::size_t raw_stride, std::span<const std::int16_t> delta,
      std::size_t forced_compute_stripes,
      std::span<const std::uint8_t> lane_mask = {});
  PrepareResult publish(FrozenOperation &&frozen, OperationKind kind, Mode mode,
                        bool has_pending_flags, std::vector<LaneJournal> lanes,
                        std::vector<std::uint16_t> transitions,
                        std::vector<std::uint8_t> lane_mask = {});
  bool
  tile_versions_match_locked(std::size_t first_tile_x, std::size_t first_tile_y,
                             std::size_t tile_columns, std::size_t tile_rows,
                             std::span<const std::uint64_t> expected) const;
  void stamp_tile_versions_locked(std::size_t first_tile_x,
                                  std::size_t first_tile_y,
                                  std::size_t tile_columns,
                                  std::size_t tile_rows);
  void invalidate_locked();
  void bump_generation_locked();

  static std::atomic<std::uint64_t> next_owner_id_;
  static constexpr std::int32_t kVersionTileWidth = 8;
  static constexpr std::int32_t kVersionTileHeight = 2;
  static constexpr std::size_t kVersionTileColumns =
      (kStorageStride + kVersionTileWidth - 1) / kVersionTileWidth;
  static constexpr std::size_t kVersionTileRows =
      (kStorageRows + kVersionTileHeight - 1) / kVersionTileHeight;
  static constexpr std::size_t kVersionTileCount =
      kVersionTileColumns * kVersionTileRows;

  mutable std::mutex mutex_;
  std::vector<HistoryPixel> committed_;
  std::vector<std::uint64_t> tile_versions_;
  bool valid_ = false;
  std::uint64_t generation_ = 0;
  std::uint64_t seed_epoch_ = 0;
  const std::uint64_t owner_id_;
  std::uint64_t next_operation_id_ = 1;
  std::unordered_map<std::uint64_t, std::uint64_t> outstanding_;
};

} // namespace pluto::swtcon

#endif // PLUTO_PRESENTER_SWTCON_XOCHITL_HISTORY_STATE_H_
