#ifndef PLUTO_PRESENTER_SWTCON_XOCHITL_SELECTOR16_H_
#define PLUTO_PRESENTER_SWTCON_XOCHITL_SELECTOR16_H_

#include "presenter/swtcon/swtcon_constants.h"

#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <span>
#include <thread>
#include <vector>

namespace pluto::swtcon {

// Hardened production form of Xochitl 3.27.1.0's selector-16 prepass.
//
// The installed implementation reuses a coarse 4x4 flag plane and a full
// selector plane for the backend lifetime.  Its three workers each run all
// stages independently, however, so classification can observe a sibling's
// old or new coarse halo according to scheduling.  This implementation keeps
// the lifetime state but inserts operation-wide barriers:
//
//   all coarse stripes -> all classify stripes -> all resolve stripes
//
// It is therefore byte-exact to the stock single-worker route and a stable,
// deliberately deterministic extension of the large-update route.
class XochitlSelector16 final {
public:
  static constexpr std::int32_t kLogicalWidth =
      ::pluto::swtcon::kLogicalWidth;
  static constexpr std::int32_t kPanelWidth =
      ::pluto::swtcon::kPaddedSourceWidth;
  static constexpr std::int32_t kPanelHeight =
      ::pluto::swtcon::kLogicalHeight;
  static constexpr std::int32_t kCoarseWidth = kPanelWidth / 4;
  static constexpr std::int32_t kCoarseHeight = kPanelHeight / 4;

  struct InclusiveRect {
    std::int32_t left = 0;
    std::int32_t top = 0;
    std::int32_t right = -1;
    std::int32_t bottom = -1;

    friend bool operator==(const InclusiveRect &,
                           const InclusiveRect &) = default;
  };

  // Input is always the complete 954x1696 logical app surface.  ARGB bytes
  // encode the portable little-endian word 0xAARRGGBB; RGB565 uses the
  // ordinary little-endian wire/storage order.  Loads are alignment-safe.
  enum class SourceFormat : std::uint8_t {
    kRgb565LittleEndian = 0,
    kArgb8888LittleEndian = 1,
  };

  // Selector execution can round the 954-column logical surface to 960.
  // Replication avoids inventing a contrast edge; white is supplied for
  // callers whose surrounding framebuffer contract is explicitly white.
  enum class RightPadding : std::uint8_t {
    kReplicateLogicalEdge = 0,
    kWhite = 1,
  };

  struct SourceView {
    std::span<const std::uint8_t> bytes;
    std::size_t stride_bytes = 0;
    std::int32_t width = kLogicalWidth;
    std::int32_t height = kPanelHeight;
    SourceFormat format = SourceFormat::kRgb565LittleEndian;
    RightPadding right_padding = RightPadding::kReplicateLogicalEdge;
  };

  enum class BuildError : std::uint8_t {
    kNone = 0,
    kInvalidGeometry,
    kInvalidSourceGeometry,
    kUnsupportedFormat,
    kUnsupportedPadding,
    kInvalidStride,
    kBufferTooSmall,
  };

  // A completed operation owns a compact row-major snapshot of its rounded
  // execution rectangle.  Only const access is published, so later builds
  // can safely reuse the backend-lifetime scratch without changing a mask
  // already handed to a consumer.
  class SelectorMask final {
  public:
    InclusiveRect execution() const { return execution_; }
    std::int32_t width() const { return width_; }
    std::int32_t height() const { return height_; }
    std::size_t stride() const { return stride_; }
    std::span<const std::uint8_t> bytes() const { return bytes_; }

  private:
    friend class XochitlSelector16;

    SelectorMask(InclusiveRect execution, std::int32_t width,
                 std::int32_t height, std::vector<std::uint8_t> bytes);

    InclusiveRect execution_{};
    std::int32_t width_ = 0;
    std::int32_t height_ = 0;
    std::size_t stride_ = 0;
    std::vector<std::uint8_t> bytes_;
  };

  struct BuildResult {
    BuildError error = BuildError::kNone;
    std::shared_ptr<const SelectorMask> mask;

    explicit operator bool() const {
      return error == BuildError::kNone && mask != nullptr;
    }
  };

  XochitlSelector16();
  // Deterministic constructor for cross-target parity tests. Production uses
  // the runtime logical-CPU count through the default constructor.
  explicit XochitlSelector16(unsigned int logical_cpus);
  ~XochitlSelector16();
  XochitlSelector16(const XochitlSelector16 &) = delete;
  XochitlSelector16 &operator=(const XochitlSelector16 &) = delete;
  XochitlSelector16(XochitlSelector16 &&) = delete;
  XochitlSelector16 &operator=(XochitlSelector16 &&) = delete;

  BuildResult build(SourceView source, InclusiveRect update);

  // Matches replacing/reinitializing the stock backend object: both retained
  // planes and the operation-local ARGB workspace are reset to zero/white.
  void reset();

  static constexpr std::size_t scratch_storage_bytes() {
    return static_cast<std::size_t>(kPanelWidth) * kPanelHeight *
               (sizeof(std::uint32_t) + sizeof(std::uint8_t)) +
           static_cast<std::size_t>(kCoarseWidth) * kCoarseHeight;
  }

private:
  struct Stripe {
    std::int32_t left = 0;
    std::int32_t top = 0;
    std::int32_t right = -1;
    std::int32_t bottom = -1;

    bool empty() const { return right < left || bottom < top; }
  };

  enum class Stage : std::uint8_t { kCoarse, kClassify, kResolve };
  static constexpr std::size_t kWorkerCapacity = 3;

  static bool valid_update(InclusiveRect update);
  static InclusiveRect rounded_execution(InclusiveRect update);
  static std::array<Stripe, kWorkerCapacity>
  make_stripes(InclusiveRect update, std::size_t stripe_count);
  static std::size_t panel_index(std::int32_t x, std::int32_t y);
  static std::size_t coarse_index(std::int32_t x, std::int32_t y);

  BuildError validate_source(const SourceView &source) const;
  void populate_argb(const SourceView &source, InclusiveRect execution);
  void run_coarse(const Stripe &stripe, const SourceView &source);
  void run_classify(const Stripe &stripe, const SourceView &source);
  void run_resolve(const Stripe &stripe, const SourceView &source,
                   InclusiveRect execution,
                   std::uint8_t *output, std::size_t output_stride);
  void run_stage_serial(Stage stage,
                        const std::array<Stripe, kWorkerCapacity> &stripes,
                        std::size_t count, const SourceView &source,
                        InclusiveRect execution,
                        std::uint8_t *output, std::size_t output_stride);
  void run_parallel(const std::array<Stripe, kWorkerCapacity> &stripes,
                    const SourceView &source, InclusiveRect execution,
                    std::uint8_t *output,
                    std::size_t output_stride);
  void worker_barrier();
  void worker_loop(std::size_t worker_index);

  // Serializes complete operations and protects all lifetime scratch.
  std::mutex build_mutex_;
  std::vector<std::uint32_t> argb_;
  std::vector<std::uint8_t> coarse_;
  std::vector<std::uint8_t> selector_;

  // Persistent workers avoid thread-creation latency on pen-sized updates.
  // They receive one complete operation each and rendezvous internally after
  // coarse and classify; the build thread publishes once and waits for all
  // all resolved stripes. The active count is capped to online logical CPUs.
  std::array<std::thread, kWorkerCapacity> workers_;
  std::mutex worker_mutex_;
  std::condition_variable worker_cv_;
  std::condition_variable worker_done_cv_;
  std::array<Stripe, kWorkerCapacity> worker_stripes_{};
  SourceView worker_source_{};
  InclusiveRect worker_execution_{};
  std::uint8_t *worker_output_ = nullptr;
  std::size_t worker_output_stride_ = 0;
  std::uint64_t worker_epoch_ = 0;
  std::size_t worker_done_ = 0;
  std::uint64_t worker_barrier_epoch_ = 0;
  std::size_t worker_barrier_arrived_ = 0;
  bool worker_stop_ = false;
  std::size_t compute_stripe_count_ = 1;
  std::size_t active_worker_count_ = 0;
  bool parallel_available_ = false;
};

} // namespace pluto::swtcon

#endif // PLUTO_PRESENTER_SWTCON_XOCHITL_SELECTOR16_H_
