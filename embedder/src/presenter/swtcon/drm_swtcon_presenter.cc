// Gallery3DrmPresenter — the per-pixel waveform engine presenter, built on
// the device-proven scan protocol.
//
// Drive stack (single renderer policy — this is the ONLY frame path):
//   present()            caller thread: validate, convert damage rects to
//                        5-bit levels, post tile-granular payload pieces
//                        into the AdmissionMailbox (full-field flashes go
//                        through the large-admission lane so the engine can
//                        band-amortize them); no full-frame copy under
//                        the presenter mutex.
//   engine thread        FIFO 60 on device, plain thread on host/dry-run:
//                        drains admissions, runs PixelEngine::advance once
//                        per scan tick (1-deep build pipeline), emits rows
//                        through PhaseEmitter into the mmap'd dumb buffers,
//                        publishes the built slot to the ScanLoop, fires
//                        completion callbacks (enqueue-only contract).
//   scan thread          ScanLoop, FIFO 80 on device: FB_ID-only atomic
//                        flips at the ENUMERATED mode period, page-flip
//                        completion events, HOLD-slot parking, double-scan
//                        detection, scan-tick publication.
//
// Thread ownership: PixelEngine/PhaseEmitter/LutCache/DcLedger state is
// engine-thread confined (no locks). The presenter mutex guards only glue
// state (completion bookkeeping, wake signals, stats snapshot). The
// AdmissionMailbox push side and the ScanReadySlot are the lock-free
// cross-thread seams.

#include "presenter/swtcon/drm_swtcon_presenter.h"

#include "pluto/glass_handoff.h"
#include "presenter/swtcon/admission_mailbox.h"
#include "presenter/swtcon/drm_swtcon_device.h"
#include "presenter/swtcon/phase_emit.h"
#include "presenter/swtcon/pixel_engine.h"
#include "presenter/swtcon/scan_loop.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_rails.h"
#include "presenter/swtcon/swtcon_temperature.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "presenter/swtcon/xochitl_color_pipeline.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <pthread.h>
#include <sched.h>

#if defined(__linux__)
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>
#endif

namespace pluto::swtcon {
namespace {

bool valid_fast_mask_layout(PlutoRect rect, std::size_t stride,
                            std::size_t storage_size) {
  if (rect.width <= 0 || rect.height <= 0) {
    return false;
  }
  const std::size_t minimum_stride =
      (static_cast<std::size_t>(rect.width) + std::size_t{7}) / 8u;
  return stride >= minimum_stride &&
         static_cast<std::size_t>(rect.height) <= storage_size / stride;
}

std::uint64_t load_fast_mask_word(const std::uint8_t *row,
                                  std::size_t row_bytes,
                                  std::size_t byte_offset) {
  if (byte_offset >= row_bytes) {
    return 0;
  }
  std::uint64_t word = 0;
  std::memcpy(&word, row + byte_offset,
              std::min(sizeof(word), row_bytes - byte_offset));
  return word;
}

void or_fast_mask_word(std::uint8_t *row, std::size_t row_bytes,
                       std::size_t byte_offset, std::uint64_t value) {
  if (byte_offset >= row_bytes || value == 0) {
    return;
  }
  const std::size_t bytes = std::min(sizeof(value), row_bytes - byte_offset);
  std::uint64_t existing = 0;
  std::memcpy(&existing, row + byte_offset, bytes);
  existing |= value;
  std::memcpy(row + byte_offset, &existing, bytes);
}

} // namespace

bool or_fast_coverage_overlap(PlutoRect source_rect,
                              std::span<const std::uint8_t> source_bits,
                              std::size_t source_stride,
                              PlutoRect destination_rect,
                              std::span<std::uint8_t> destination_bits,
                              std::size_t destination_stride) {
  if (!valid_fast_mask_layout(source_rect, source_stride, source_bits.size()) ||
      !valid_fast_mask_layout(destination_rect, destination_stride,
                              destination_bits.size())) {
    return false;
  }

  const std::int64_t source_right =
      static_cast<std::int64_t>(source_rect.x) + source_rect.width;
  const std::int64_t source_bottom =
      static_cast<std::int64_t>(source_rect.y) + source_rect.height;
  const std::int64_t destination_right =
      static_cast<std::int64_t>(destination_rect.x) + destination_rect.width;
  const std::int64_t destination_bottom =
      static_cast<std::int64_t>(destination_rect.y) + destination_rect.height;
  const std::int64_t overlap_left =
      std::max<std::int64_t>(source_rect.x, destination_rect.x);
  const std::int64_t overlap_top =
      std::max<std::int64_t>(source_rect.y, destination_rect.y);
  const std::int64_t overlap_right = std::min(source_right, destination_right);
  const std::int64_t overlap_bottom =
      std::min(source_bottom, destination_bottom);
  if (overlap_left >= overlap_right || overlap_top >= overlap_bottom) {
    return true;
  }

  const std::size_t source_row_bytes =
      (static_cast<std::size_t>(source_rect.width) + std::size_t{7}) / 8u;
  const std::size_t destination_row_bytes =
      (static_cast<std::size_t>(destination_rect.width) + std::size_t{7}) / 8u;
  const std::size_t first_word =
      static_cast<std::size_t>((overlap_left - destination_rect.x) / 64);
  const std::size_t end_word =
      static_cast<std::size_t>((overlap_right - destination_rect.x + 63) / 64);

  for (std::int64_t panel_y = overlap_top; panel_y < overlap_bottom;
       ++panel_y) {
    const std::uint8_t *source_row =
        source_bits.data() +
        static_cast<std::size_t>(panel_y - source_rect.y) * source_stride;
    std::uint8_t *destination_row =
        destination_bits.data() +
        static_cast<std::size_t>(panel_y - destination_rect.y) *
            destination_stride;
    for (std::size_t word_index = first_word; word_index < end_word;
         ++word_index) {
      const std::int64_t panel_word_x =
          static_cast<std::int64_t>(destination_rect.x) +
          static_cast<std::int64_t>(word_index) * 64;
      const std::int64_t source_bit = panel_word_x - source_rect.x;
      std::uint64_t source_word = 0;
      if (source_bit >= 0) {
        const std::size_t source_byte =
            static_cast<std::size_t>(source_bit) / 8u;
        const unsigned shift = static_cast<unsigned>(source_bit) & 7u;
        source_word =
            load_fast_mask_word(source_row, source_row_bytes, source_byte) >>
            shift;
        if (shift != 0) {
          const std::uint64_t carry =
              load_fast_mask_word(source_row, source_row_bytes,
                                  source_byte + sizeof(std::uint64_t));
          source_word |= carry << (64u - shift);
        }
      } else {
        // first_word is the first intersecting destination word, therefore a
        // negative source start is always within this 64-bit word.
        const unsigned shift = static_cast<unsigned>(-source_bit);
        if (shift < 64u) {
          source_word = load_fast_mask_word(source_row, source_row_bytes, 0)
                        << shift;
        }
      }

      const unsigned first_bit = static_cast<unsigned>(
          std::max(overlap_left, panel_word_x) - panel_word_x);
      const unsigned end_bit = static_cast<unsigned>(
          std::min(overlap_right, panel_word_x + 64) - panel_word_x);
      const std::uint64_t low_mask =
          first_bit == 0 ? ~std::uint64_t{0} : (~std::uint64_t{0} << first_bit);
      const std::uint64_t high_mask =
          end_bit == 64 ? ~std::uint64_t{0}
                        : ((std::uint64_t{1} << end_bit) - 1u);
      source_word &= low_mask & high_mask;
      or_fast_mask_word(destination_row, destination_row_bytes,
                        word_index * sizeof(std::uint64_t), source_word);
    }
  }
  return true;
}

} // namespace pluto::swtcon

namespace pluto {
namespace {

constexpr std::uint64_t kPenFocusTruthChaseNs = 24'000'000u;

std::uint64_t steady_now_ns() {
  return static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}

using swtcon::AdmissionMailbox;
using swtcon::AdmissionMailboxConfig;
using swtcon::AdmissionMailboxRecord;
using swtcon::AdmitRequest;
using swtcon::EmissionMode;
using swtcon::kActivePhaseSlots;
using swtcon::kAdmitFlagForceIdentity;
using swtcon::kAdmitFlagLargeLane;
using swtcon::kAdmitFlagSettle;
using swtcon::kDrmBufferCount;
using swtcon::kDrmPhaseWords;
using swtcon::kDrmWidth;
using swtcon::kLogicalFrameBytes;
using swtcon::kLogicalHeight;
using swtcon::kLogicalStrideBytes;
using swtcon::kLogicalWidth;
using swtcon::kPanelDpi;
using swtcon::kRgb565BytesPerPixel;
using swtcon::PhaseEmitter;
using swtcon::PhaseEmitterConfig;
using swtcon::PixelEngine;
using swtcon::PixelEngineConfig;
using swtcon::ScanFeedback;
using swtcon::ScanLoop;
using swtcon::ScanLoopConfig;
using swtcon::SteadyScanClock;
using swtcon::WaveformTable;
using swtcon::XochitlColorPipeline;
using swtcon::XochitlHistoryState;

// The panel .eink shipped on the Paper Pro Move. Used when no eink= option
// is given (the boot-hook fallback recipe passes none); host tests always
// pass an explicit synthetic file.
constexpr char kDefaultDeviceEinkPath[] =
    "/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink";

// Engine frame_id bias: the engine treats frame_id 0 as the settle
// sentinel (no user completion), so user frame_ids ride at +1.
constexpr std::uint64_t kEngineFrameIdBias = 1;
// GAL3 white top-off mode: 4 phases, drives near-white (27..31) -> 29,
// holds everything else — the vendor-tuned flash-free maintenance drive
// the sparkle ghost repair rides (kPlutoPresentFlagSparkle).
constexpr int kSparkleWaveformMode = 8;
// Develop-variant sparkle (color glass): per-pixel GC16 micro develops —
// the only drive that resets displaced Gallery-3 pigments in nominally
// white pixels. Mode 2 is the first flashing GC16-family mode; the flash
// is per masked PIXEL (paper-grain density), never a field inversion.
constexpr int kSparkleDevelopWaveformMode = 2;

// ready() headroom in mailbox records: backpressure only on (near) ring
// full — a max-area small-path present is ~420 tile pieces.
constexpr std::size_t kReadyHeadroomRecords = 512;

// Exact mapped truth may occupy the whole normal color lane for hundreds of
// milliseconds.  Pen Fast must still be admissible while that truth drains or
// a saturated fidelity queue turns directly into missing stroke segments.
// Keep one renderer-sized (64 rect) batch of bounded headroom exclusively for
// mode-Fast obligations.  Non-Fast work retains the original 64-obligation
// ceiling; once the reserve is in use it cannot admit more truth behind it.
constexpr std::size_t kColorFastReserve = 64;

// The handoff profile is a positive device route, not a geometry guess. A
// future panel is added as another complete row and can never consume the
// Move's Xochitl history layout by merely sharing one dimension.
struct FixedColorHandoffProfile {
  GlassHandoffProfile profile;
  const char *machine;
  const char *soc;
  std::uint32_t width;
  std::uint32_t height;
  std::uint32_t engine_stride;
  std::uint32_t tile_px;
  std::uint32_t history_stride;
  std::uint32_t history_rows;
};

constexpr std::array<FixedColorHandoffProfile, 1> kColorHandoffProfiles{{
    {GlassHandoffProfile::kXochitlGallery3Move, "reMarkable Chiappa", "i.MX93",
     954, 1696, 960, 32, 968, 1698},
}};

const FixedColorHandoffProfile *
find_color_handoff_profile(int width, int height, int engine_stride,
                           std::uint32_t tile_px, int history_stride,
                           int history_rows, std::string_view machine,
                           std::string_view soc, bool require_device_identity) {
  for (const FixedColorHandoffProfile &profile : kColorHandoffProfiles) {
    if (width != static_cast<int>(profile.width) ||
        height != static_cast<int>(profile.height) ||
        engine_stride != static_cast<int>(profile.engine_stride) ||
        tile_px != profile.tile_px ||
        history_stride != static_cast<int>(profile.history_stride) ||
        history_rows != static_cast<int>(profile.history_rows)) {
      continue;
    }
    if (require_device_identity &&
        (machine != profile.machine || soc != profile.soc)) {
      continue;
    }
    return &profile;
  }
  return nullptr;
}

enum class HandoffExecutionBackend : std::uint8_t {
  kDryRun = 1,
  kInjectedTestDrm = 2,
  kProductionDrm = 3,
};

// The production route is deliberately singular and rooted in a private,
// root-owned tmpfs directory. Test simulators use caller-provided non-default
// paths and therefore cannot publish a candidate a production process will
// ever inspect. A future device route may add its own canonical tmpfs path,
// but must opt in here rather than inheriting compatibility from geometry.
bool production_handoff_path_is_secure_tmpfs(const std::string &path) {
  if (path != kGlassHandoffDefaultPath) {
    return false;
  }
#if defined(__linux__)
  constexpr const char *kDirectory = "/run/pluto";
  constexpr long kTmpfsMagic = 0x01021994;
  struct stat directory_stat {};
  struct statfs filesystem_stat {};
  return ::lstat(kDirectory, &directory_stat) == 0 &&
         S_ISDIR(directory_stat.st_mode) &&
         directory_stat.st_uid == ::geteuid() &&
         (directory_stat.st_mode & 0022) == 0 &&
         ::statfs(kDirectory, &filesystem_stat) == 0 &&
         static_cast<long>(filesystem_stat.f_type) == kTmpfsMagic;
#else
  return false;
#endif
}

std::string read_small_identity_file(const char *path) {
  std::string value;
  std::FILE *file = std::fopen(path, "rb");
  if (file == nullptr) {
    return value;
  }
  std::array<char, 256> bytes{};
  const std::size_t count = std::fread(bytes.data(), 1, bytes.size(), file);
  (void)std::fclose(file);
  value.assign(bytes.data(), count);
  while (!value.empty() && (value.back() == '\0' || value.back() == '\n' ||
                            value.back() == '\r' || value.back() == ' ')) {
    value.pop_back();
  }
  return value;
}

class HandoffFingerprint final {
public:
  void add_bytes(std::span<const std::uint8_t> bytes) {
    value_ = glass_handoff_crc64(bytes, value_);
  }

  void add_u8(std::uint8_t value) {
    add_bytes(std::span<const std::uint8_t>(&value, 1));
  }

  void add_u16(std::uint16_t value) {
    const std::array<std::uint8_t, 2> bytes{
        static_cast<std::uint8_t>(value),
        static_cast<std::uint8_t>(value >> 8u)};
    add_bytes(bytes);
  }

  void add_u32(std::uint32_t value) {
    const std::array<std::uint8_t, 4> bytes{
        static_cast<std::uint8_t>(value),
        static_cast<std::uint8_t>(value >> 8u),
        static_cast<std::uint8_t>(value >> 16u),
        static_cast<std::uint8_t>(value >> 24u)};
    add_bytes(bytes);
  }

  void add_u64(std::uint64_t value) {
    std::array<std::uint8_t, 8> bytes{};
    for (unsigned shift = 0; shift < 64; shift += 8) {
      bytes[shift / 8] = static_cast<std::uint8_t>(value >> shift);
    }
    add_bytes(bytes);
  }

  void add_string(const std::string &value) {
    add_u64(value.size());
    add_bytes(std::span<const std::uint8_t>(
        reinterpret_cast<const std::uint8_t *>(value.data()), value.size()));
  }

  std::uint64_t value() const { return value_; }

private:
  std::uint64_t value_ = 0;
};

std::string option_value(const char *options, const char *key) {
  if (options == nullptr || key == nullptr) {
    return {};
  }
  const std::string input(options);
  const std::string needle = std::string(key) + "=";
  std::size_t pos = input.find(needle);
  while (pos != std::string::npos && pos != 0 && input[pos - 1] != ',') {
    pos = input.find(needle, pos + 1);
  }
  if (pos == std::string::npos) {
    return {};
  }
  pos += needle.size();
  const std::size_t end = input.find(',', pos);
  return input.substr(pos,
                      end == std::string::npos ? std::string::npos : end - pos);
}

bool parse_bool_option(const std::string &value, bool *out) {
  if (out == nullptr || value.empty()) {
    return false;
  }
  if (value == "1" || value == "true" || value == "yes" || value == "on") {
    *out = true;
    return true;
  }
  if (value == "0" || value == "false" || value == "no" || value == "off") {
    *out = false;
    return true;
  }
  return false;
}

bool parse_int_option(const std::string &value, long long *out) {
  if (out == nullptr || value.empty()) {
    return false;
  }
  char *end = nullptr;
  const long long parsed = std::strtoll(value.c_str(), &end, 10);
  if (end == value.c_str() || *end != '\0') {
    return false;
  }
  *out = parsed;
  return true;
}

bool rect_valid(const PlutoRect &rect) {
  return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
         rect.x <= kLogicalWidth && rect.y <= kLogicalHeight &&
         rect.width <= kLogicalWidth - rect.x &&
         rect.height <= kLogicalHeight - rect.y;
}

void set_thread_name(const char *name) {
#if defined(__APPLE__)
  (void)pthread_setname_np(name);
#elif defined(__linux__)
  (void)pthread_setname_np(pthread_self(), name);
#else
  (void)name;
#endif
}

// Thread plan: scan SCHED_FIFO 80, engine SCHED_FIFO 60, BOTH pinned to
// core 1; Flutter raster/UI stay SCHED_OTHER on core 0. Both knobs are
// best-effort and independent — they fail silently on unprivileged hosts
// (EPERM) and non-Linux builds.
constexpr int kEngineFifoPriority = 60;
constexpr int kRealtimeCpu = 1;

void set_engine_thread_policy() {
#if defined(SCHED_FIFO)
  sched_param param{};
  param.sched_priority = kEngineFifoPriority;
  (void)pthread_setschedparam(pthread_self(), SCHED_FIFO, &param);
#endif
#if defined(__linux__)
  cpu_set_t cpus;
  CPU_ZERO(&cpus);
  CPU_SET(kRealtimeCpu, &cpus);
  (void)sched_setaffinity(0, sizeof(cpus), &cpus);
#endif
}

PlutoDisplayInfo make_info() {
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  info.width = kLogicalWidth;
  info.height = kLogicalHeight;
  info.dpi = kPanelDpi;
  info.preferred_format = kPlutoPixelFormatRgb565;
  // Greyscale drive from the decoded `.eink`; color needs the ct33
  // front-end on top of the drive table (OPEN P1 R-Q5).
  info.is_color = false;
  info.controls_refresh_class = true;
  info.reports_completion = true;
  info.wants_pre_dithered = false;
  info.backend_quantizes_color = false;
  info.rect_alignment = 8;
  // Concurrent regional updates of any count: the engine admits every
  // scan frame; the only backpressure is mailbox-full.
  info.max_inflight_updates = 0;
  return info;
}

// TEST-ONLY (swtcon::set_drm_interface_for_testing): consumed by the next
// non-dry-run open() in place of make_real_drm_interface().
std::unique_ptr<swtcon::DrmInterface> &test_drm_interface_slot() {
  static std::unique_ptr<swtcon::DrmInterface> slot;
  return slot;
}

// Impulse-summary store (double-scan recharge WITHOUT plane reads — the
// device livelock fix): per build slot, the per-tile signed DC impulse
// and a touched-by-drive-ops flag of the plane that was built. A
// double-scan recharge then charges summary[slot] x extra straight into the
// DC ledger — the WC dumb buffer is NEVER read back. (The old recharge did
// a full 1.24 MB uncached write-combined read per vblank gap on the engine
// thread, tens of ms each; combined with jitter-induced gaps on every
// latch, it starved builds into a HOLD/recharge livelock on device.)
//
// Accumulation is FOLDED INTO the engine's fused advance sweep
// (PixelEngine::set_impulse_sink, sweep_kernels.h) — build rows no longer
// take a second per-op pass; this class is just the slot-major backing
// store the sink points into.
//
// Memory: kActivePhaseSlots x tile_count int32 + flag (~1590 tiles on the
// panel => ~100 KB), ordinary cached memory. A slot's summary restarts from
// zero at every (re)build: stale rows re-blank at end_frame, so only ops
// emitted THIS build survive on the plane. Engine-thread confined.
class ImpulseSummaryStore final {
public:
  void configure(std::size_t tile_count, std::size_t slot_count) {
    tile_count_ = tile_count;
    impulse_.assign(slot_count * tile_count, 0);
    drive_.assign(slot_count * tile_count, 0);
  }

  // Opens accumulation for the slot being (re)built: its summary restarts
  // from zero (the plane's previous content is re-blanked at end_frame).
  void begin_slot(std::size_t slot) {
    std::fill_n(impulse_.data() + slot * tile_count_, tile_count_, 0);
    std::fill_n(drive_.data() + slot * tile_count_, tile_count_, 0);
  }

  std::int32_t *slot_impulse_sink(std::size_t slot) {
    return impulse_.data() + slot * tile_count_;
  }
  std::uint8_t *slot_drive_sink(std::size_t slot) {
    return drive_.data() + slot * tile_count_;
  }
  const std::int32_t *slot_impulse(std::size_t slot) const {
    return impulse_.data() + slot * tile_count_;
  }
  const std::uint8_t *slot_drive(std::size_t slot) const {
    return drive_.data() + slot * tile_count_;
  }

private:
  std::size_t tile_count_ = 0;
  std::vector<std::int32_t> impulse_; // slot-major [slot][tile]
  std::vector<std::uint8_t> drive_;   // slot-major [slot][tile]
};

class Gallery3DrmPresenter final {
public:
  ~Gallery3DrmPresenter() { close(); }

  PlutoStatus open(const PlutoPresenterConfig *config) {
    presenter_open_t_ns_ = steady_now_ns();
    first_user_admission_t_ns_.store(0, std::memory_order_relaxed);
    first_user_build_seq_ = 0;
    first_visible_latch_logged_ = false;
    warm_handoff_accepted_.store(false, std::memory_order_relaxed);
    if (config != nullptr &&
        config->struct_size < sizeof(PlutoPresenterConfig)) {
      return kPlutoStatusInvalidArgument;
    }
    config_ = {};
    callback_ = config != nullptr ? config->on_complete : nullptr;
    callback_user_data_ = config != nullptr ? config->user_data : nullptr;

    const PlutoStatus parse_status =
        parse_options(config != nullptr ? config->options : nullptr);
    if (parse_status != kPlutoStatusOk) {
      return parse_status;
    }
    handoff_backend_ = config_.dry_run
                           ? HandoffExecutionBackend::kDryRun
                           : (test_drm_interface_slot() != nullptr
                                  ? HandoffExecutionBackend::kInjectedTestDrm
                                  : HandoffExecutionBackend::kProductionDrm);

    frame_.assign(kLogicalFrameBytes, 0xff);
    piece_levels_scratch_.assign(
        static_cast<std::size_t>(config_.engine.tile_px) *
            static_cast<std::size_t>(config_.engine.tile_px),
        0);
    reset_pending_frames();
    completion_callbacks_pending_ = 0;
    large_lane_.reserve(config_.large_lane_max);
    color_lane_.reserve(config_.color_lane_max + kColorFastReserve);
    mapped_token_frames_.reserve(config_.color_lane_max);
    mapped_terminal_fences_.reserve(config_.color_lane_max);
    mapped_events_.reserve(config_.color_lane_max);
    safe_fast_frames_.reserve(config_.color_lane_max + kColorFastReserve);
    reserved_safe_fast_engine_ids_.reserve(config_.color_lane_max +
                                           kColorFastReserve);
    safe_fast_ready_scratch_.reserve(config_.color_lane_max +
                                     kColorFastReserve);
    safe_fast_piece_order_scratch_.reserve(config_.color_lane_max +
                                           kColorFastReserve);
    scan_feedback_scratch_.reserve(kDrmBufferCount * 2);
    level_buffer_pool_.reserve(config_.large_lane_max);
    engine_completions_.reserve(config_.mailbox_capacity);
    fired_frames_.reserve(config_.mailbox_capacity);
    double_scan_scratch_.reserve(kDrmBufferCount * 2);

    // The per-pixel engine drives exclusively from the decoded `.eink`
    // LUTs (swtcon_waveform.cc is the single code source); without a valid
    // table there is nothing to drive with.
    std::string error;
    if (config_.waveform_files.eink_path.empty()) {
      config_.waveform_files.eink_path = kDefaultDeviceEinkPath;
    }
    if (!waveform_.load(config_.waveform_files, waveform_reader_, &error) ||
        !waveform_.table().valid()) {
      std::fprintf(stderr,
                   "swtcon: engine requires a decoded .eink waveform "
                   "(eink=%s): %s\n",
                   config_.waveform_files.eink_path.c_str(), error.c_str());
      return kPlutoStatusInvalidArgument;
    }

    // Direct color is an all-or-nothing capability. Missing/malformed ct33,
    // any required mode/bin record, or any exact delta failure leaves the
    // long-proven grayscale engine untouched and unadvertised as color.
    std::string color_error;
    const bool safe_fast_waveform =
        swtcon::supports_mode7_fast_recovery(waveform_.table());
    color_enabled_ =
        config_.exact_color && config_.mode_lab_step_ms == 0 &&
        safe_fast_waveform &&
        color_pipeline_.configure(&waveform_.table(), waveform_.ct33_bytes(),
                                  &color_error);
    if (config_.exact_color && !color_enabled_) {
      if (!safe_fast_waveform) {
        color_error =
            "mode 7 does not match the proven Fast recovery signature";
      }
      std::fprintf(stderr, "swtcon: color pipeline disabled: %s\n",
                   color_error.c_str());
      return kPlutoStatusInvalidArgument;
    }

    temperature_.start(config_.temperature);

    // Content-target legalization maps, one per (mode, temp bin): content
    // levels are snapped to targets the mode can actually drive from both
    // rails (GAL3 mode 7 is bilevel {2,28}; slot 31 / odd levels hold in
    // mode 1/2). Built once from the decoded table; applied in
    // convert_levels so every app admission targets a drivable level.
    {
      const swtcon::WaveformTable &table = waveform_.table();
      legal_map_ntemp_ = table.temp_count();
      legal_target_maps_.assign(
          static_cast<std::size_t>(table.mode_count()) *
              static_cast<std::size_t>(std::max(1, legal_map_ntemp_)),
          std::array<std::uint8_t, 32>{});
      for (int mode = 0; mode < table.mode_count(); ++mode) {
        for (int bin = 0; bin < std::max(1, legal_map_ntemp_); ++bin) {
          legal_target_maps_[static_cast<std::size_t>(mode) *
                                 static_cast<std::size_t>(
                                     std::max(1, legal_map_ntemp_)) +
                             static_cast<std::size_t>(bin)] =
              swtcon::build_legal_target_map(table, mode, bin);
        }
      }
    }

    std::vector<swtcon::RailWrite> dry_run_log;
    swtcon::SwtconRails::Config rail_config = config_.rails;
    rail_config.dry_run_log = &dry_run_log;
    const PlutoStatus rails_status =
        swtcon::SwtconRails::apply(rail_config, &rails_fs_, &error);
    if (rails_status != kPlutoStatusOk) {
      temperature_.stop();
      return rails_status;
    }

    // Mode 0 remains decodable for the explicit mode laboratory, but normal
    // operation never selects it. Cold glass is established with the same
    // short rail waveform as stock-style BlinkNow.
    if (!engine_.configure(&waveform_.table(), config_.engine)) {
      temperature_.stop();
      return kPlutoStatusInternal;
    }
    // start() synchronously sampled the panel thermistor. Seed both the
    // engine and producer-side admission selector before cold clear so its
    // legal targets and drive record are the same actual-temperature bin.
    engine_.set_temperature(temperature_.current_celsius());
    admission_bin_selector_ =
        swtcon::TemperatureBinSelector(config_.engine.temp_hysteresis_c);
    (void)admission_bin_selector_.select(waveform_.table().temp_thresholds(),
                                         temperature_.current_celsius());
    bind_engine_callbacks();

    AdmissionMailboxConfig mailbox_config;
    mailbox_config.capacity = config_.mailbox_capacity;
    mailbox_config.payload_capacity =
        static_cast<std::size_t>(config_.engine.tile_px) *
        static_cast<std::size_t>(config_.engine.tile_px);
    if (!mailbox_.configure(mailbox_config)) {
      temperature_.stop();
      return kPlutoStatusInternal;
    }

    PhaseEmitterConfig emitter_config;
    emitter_config.mode = config_.emission_mode;
    emitter_config.slot_count = kDrmBufferCount;
    if (!emitter_.configure(emitter_config)) {
      temperature_.stop();
      return kPlutoStatusInternal;
    }
    // Build-time impulse summaries for the double-scan recharge: the
    // recharge path never reads the dumb buffers. HOLD (slot 15) is
    // never built and never recharged, so only the active slots carry one.
    // Accumulation is folded into the engine's advance sweep via
    // set_impulse_sink (per build, in build_frame).
    summary_store_.configure(engine_.dc_ledger().tile_count(),
                             kActivePhaseSlots);

    const bool isolated_test_route =
        handoff_backend_ != HandoffExecutionBackend::kProductionDrm &&
        config_.handoff_path != kGlassHandoffDefaultPath;
    const bool production_route =
        handoff_backend_ == HandoffExecutionBackend::kProductionDrm &&
        production_handoff_path_is_secure_tmpfs(config_.handoff_path);
    const bool handoff_route_valid = !config_.handoff_path.empty() &&
                                     (isolated_test_route || production_route);
    if (!config_.handoff_path.empty() && !handoff_route_valid) {
      // A simulator is never allowed to touch the production candidate, and
      // a real backend is never allowed to follow an arbitrary or non-tmpfs
      // path. Disable the route without unlinking a file owned by another
      // execution domain.
      std::fprintf(stderr,
                   "swtcon: warm handoff route disabled backend=%u path=%s\n",
                   static_cast<unsigned>(handoff_backend_),
                   config_.handoff_path.c_str());
      config_.handoff_path.clear();
    }

    // Acquire before opening or programming DRM. A losing process must not
    // blank a slot, modeset the CRTC, or otherwise touch scanout while the
    // current glass owner is still closing. The winner retains this exact
    // inode through its complete DRM lifetime and final bundle decision.
    if (handoff_route_valid &&
        !glass_handoff_acquire_lease(config_.handoff_path, &handoff_lease_)) {
      std::fprintf(stderr, "swtcon: warm handoff namespace is owned by another "
                           "display process\n");
      config_.handoff_path.clear();
      temperature_.stop();
      return kPlutoStatusAgain;
    }
    const auto fail_open = [this](PlutoStatus status) {
      temperature_.stop();
      if (device_ != nullptr) {
        device_->close();
        device_.reset();
      }
      handoff_lease_ = GlassHandoffLease{};
      return status;
    };

    if (!config_.dry_run) {
      swtcon::DrmSwtconDevice::Config device_config;
      device_config.card_path = config_.card_path;
      std::unique_ptr<swtcon::DrmInterface> drm =
          std::move(test_drm_interface_slot());
      if (drm == nullptr) {
        drm = swtcon::make_real_drm_interface();
      }
      device_ = std::make_unique<swtcon::DrmSwtconDevice>(std::move(drm));
      const PlutoStatus device_status = device_->open(device_config);
      if (device_status != kPlutoStatusOk) {
        std::fprintf(stderr, "swtcon DRM init failed: %s\n",
                     device_->last_error().c_str());
        return fail_open(device_status);
      }
      // Build slots 0..14 target the mmap'd dumb buffers; slot 15 is the
      // permanent HOLD slot, primed by ScanLoop::configure and NEVER
      // written by the emitter (always-blank by construction).
      for (std::size_t slot = 0; slot < kActivePhaseSlots; ++slot) {
        const swtcon::DrmMappedBuffer &buffer = device_->buffers()[slot];
        auto *words = static_cast<std::uint16_t *>(buffer.map);
        if (!emitter_.set_slot_target(slot, words, buffer.pitch) ||
            !emitter_.blank_slot(slot)) {
          return fail_open(kPlutoStatusInternal);
        }
      }

      ScanLoopConfig scan_config;
      scan_config.scan_period_ns = config_.scan_period_ns;
      scan_config.hold_slot = kDrmBufferCount - 1;
      scan_config.consume_flip_events = true;
      scan_config.sched_fifo_priority = 80;    // scan thread plan
      scan_config.cpu_affinity = kRealtimeCpu; // scan+engine on core 1
      if (!scan_loop_.configure(device_.get(), &steady_clock_, scan_config)) {
        return fail_open(kPlutoStatusInternal);
      }
      // Glass bring-up: one legacy set_crtc with the ENUMERATED mode —
      // the device-proven modeset-enable chain (panel prepare, oeh/oev,
      // VCOM) — showing the blank HOLD plane. Atomic FB_ID flips ride on
      // this active CRTC afterwards.
      const PlutoStatus enable_status = device_->set_crtc(kDrmBufferCount - 1);
      if (enable_status != kPlutoStatusOk) {
        std::fprintf(stderr, "swtcon modeset enable failed: %s\n",
                     device_->last_error().c_str());
        return fail_open(enable_status);
      }

      scan_loop_.set_on_tick([this](std::uint64_t) {
        // Scan thread -> engine wake. One build per tick (1-deep pipeline);
        // coalesced ticks were HOLD frames at the scan already.
        {
          std::lock_guard<std::mutex> lock(mutex_);
          ++ticks_pending_;
        }
        engine_cv_.notify_all();
      });
      scan_loop_.set_on_pause([this] {
        // Scan thread: deferred to the engine thread (PixelEngine::pause is
        // engine-confined). Applying it one wake later keeps the accounting
        // exact — a pause only charges stress, it never moves fnum.
        pending_pauses_.fetch_add(1, std::memory_order_relaxed);
      });
      scan_loop_.set_on_double_scan([this](std::uint32_t buffer_index,
                                           std::uint64_t engine_seq,
                                           std::uint32_t extra) {
        std::lock_guard<std::mutex> lock(mutex_);
        double_scan_events_.push_back({buffer_index, engine_seq, extra});
      });
      scan_loop_.set_on_latched([this](std::uint64_t) {
        // The page-flip event advanced ScanReadySlot's optical fence before
        // this callback. Synchronize with the wait_idle condition-variable
        // mutex so the acknowledgement cannot land between its predicate
        // check and sleep (a notify without this handshake could be lost).
        { std::lock_guard<std::mutex> lock(mutex_); }
        idle_cv_.notify_all();
      });
      scan_loop_.set_on_feedback([this](const ScanFeedback &feedback) {
        {
          std::lock_guard<std::mutex> lock(mutex_);
          scan_feedback_events_.push_back(feedback);
        }
        engine_cv_.notify_all();
      });
      scan_loop_.set_engine_active(
          [this] { return engine_busy_flag_.load(std::memory_order_acquire); });
    } else {
      // Dry-run (no DRM): host memory planes stand in for the dumb-buffer
      // ring; the engine thread self-paces at flip_interval_ms.
      host_slots_.assign(kDrmBufferCount,
                         std::vector<std::uint16_t>(kDrmPhaseWords, 0));
      for (std::size_t slot = 0; slot < kActivePhaseSlots; ++slot) {
        if (!emitter_.set_slot_target(slot, host_slots_[slot].data(),
                                      kDrmWidth * sizeof(std::uint16_t)) ||
            !emitter_.blank_slot(slot)) {
          return fail_open(kPlutoStatusInternal);
        }
      }
    }

    handoff_identity_valid_ = handoff_route_valid &&
                              config_.mode_lab_step_ms == 0 &&
                              build_handoff_identity(&handoff_identity_);
    if (!config_.handoff_path.empty() && !handoff_identity_valid_) {
      // Unsupported production hardware/configuration can never route into
      // a hardcoded profile. Remove any seed left by a different route and
      // continue through the ordinary cold-clear path.
      if (!glass_handoff_discard(handoff_lease_, config_.handoff_path)) {
        std::fprintf(stderr,
                     "swtcon: incompatible handoff could not be invalidated\n");
        return fail_open(kPlutoStatusInternal);
      }
    }

    // Warm handoff is one transaction across presenter and renderer. Core
    // state may be seeded here, before threads, but the engine remains behind
    // the cold-clear gate until FrameRenderer validates and imports the
    // renderer section then explicitly confirms this same candidate.
    handoff_core_seeded_ = false;
    handoff_unlinked_ = !handoff_identity_valid_;
    handoff_chain_next_ = 0;
    handoff_frozen_ = false;
    handoff_decision_ = HandoffDecision::kNone;
    handoff_invalidation_failed_ = false;
    incoming_renderer_payload_.clear();
    incoming_renderer_info_ = {};
    incoming_handoff_claim_ = {};
    staged_handoff_.reset();
    last_published_content_seq_.store(0, std::memory_order_release);
    last_resolved_content_seq_.store(0, std::memory_order_release);
    if (handoff_identity_valid_) {
      GlassHandoffBundle candidate;
      const GlassHandoffReject reject = glass_handoff_load(
          handoff_lease_, config_.handoff_path, handoff_identity_,
          glass_handoff_now(), &candidate);
      if (reject == GlassHandoffReject::kNone &&
          seed_handoff_core(&candidate)) {
        handoff_core_seeded_ = true;
        handoff_chain_next_ = candidate.chain + 1u;
        incoming_handoff_claim_ = candidate.claim;
        incoming_renderer_info_ = candidate.renderer;
        incoming_renderer_payload_ = std::move(candidate.renderer_payload);
        handoff_decision_ = HandoffDecision::kPending;
        std::fprintf(stderr,
                     "swtcon: warm handoff candidate validated chain=%u "
                     "bytes=%zu color=%d\n",
                     candidate.chain, incoming_renderer_payload_.size(),
                     color_enabled_ ? 1 : 0);
      } else if (reject == GlassHandoffReject::kMissing) {
        handoff_unlinked_ = true;
      } else if (reject != GlassHandoffReject::kMissing) {
        std::fprintf(stderr, "swtcon: warm handoff rejected: %s\n",
                     reject == GlassHandoffReject::kNone
                         ? glass_handoff_reject_name(GlassHandoffReject::kState)
                         : glass_handoff_reject_name(reject));
        if (!glass_handoff_discard(handoff_lease_, config_.handoff_path)) {
          std::fprintf(stderr,
                       "swtcon: rejected handoff could not be invalidated\n");
          return fail_open(kPlutoStatusInternal);
        }
        handoff_unlinked_ = true;
      }
    }

    stopping_ = false;
    device_lost_ = false;
    cold_clear_done_.store(false, std::memory_order_release);
    cold_clear_phase_ = ColdClearPhase::kIdle;
    cold_clear_mode_ = -1;
    cold_clear_temp_bin_ = 0;
    cold_clear_completion_target_ = 0;
    cold_clear_waiting_latch_ = false;
    cold_clear_latch_target_ = 0;
    engine_busy_flag_.store(false, std::memory_order_release);
    mapped_terminal_count_.store(0, std::memory_order_release);
    color_obligation_count_.store(0, std::memory_order_release);
    color_fast_obligation_count_.store(0, std::memory_order_release);
    color_dependency_epoch_ = 0;
    safe_fast_frames_.clear();
    reserved_safe_fast_engine_ids_.clear();
    next_safe_fast_engine_id_ = std::numeric_limits<std::uint64_t>::max();
    next_fast_present_seq_ = 1;
    next_fast_piece_seq_ = 1;
    next_color_retry_cookie_ = 1;
    last_known_safe_scan_seq_ = 0;
    bypass_fast_present_seq_ = 0;
    pen_focus_mailbox_write_.store(0, std::memory_order_release);
    pen_focus_mailbox_published_.store(0, std::memory_order_release);
    pen_focus_wake_.store(false, std::memory_order_release);
    applied_pen_focus_ticket_ = 0;
    pen_focus_active_ = false;
    pen_focus_contact_ = false;
    pen_focus_raw_rect_ = {};
    pen_focus_rect_ = {};
    pen_focus_sequence_ = 0;
    pen_focus_motion_generation_ = 0;
    pen_focus_geometry_changed_ns_ = 0;
    fast_seed_seq_.assign(
        color_enabled_ ? XochitlHistoryState::kStoragePixels : 0, 0);
    fast_filtered_scratch_.clear();
    fast_confirmed_scratch_.clear();
    fast_newer_coverage_scratch_.clear();
    safe_fast_ready_scratch_.clear();
    safe_fast_piece_order_scratch_.clear();
    if (color_enabled_) {
      // Reserve the proven maximum mask accepted by the history/storage
      // bounds, not merely today's 32px engine tile. This also covers a
      // future coalesced or clipped Fast proof without a first-latch alloc.
      constexpr std::size_t kMaximumFastMaskBytes =
          ((static_cast<std::size_t>(XochitlHistoryState::kStorageStride) +
            std::size_t{7}) /
           8u) *
          XochitlHistoryState::kStorageRows;
      fast_filtered_scratch_.reserve(kMaximumFastMaskBytes);
      fast_confirmed_scratch_.reserve(kMaximumFastMaskBytes);
      fast_newer_coverage_scratch_.reserve(kMaximumFastMaskBytes);
    }
    stat_dropped_pieces_.store(0, std::memory_order_relaxed);
    stat_color_faults_.store(0, std::memory_order_relaxed);
    stat_color_reconciles_.store(0, std::memory_order_relaxed);
    stat_color_queue_peak_ = 0;
    stat_color_fast_bypasses_ = 0;
    stat_color_fast_bypass_wait_max_us_ = 0;
    stat_color_fast_obligation_peak_ = 0;
    stat_color_truth_obligation_peak_ = 0;
    stat_color_fast_reserve_uses_ = 0;
    stat_color_fast_reserve_declines_ = 0;
    stat_color_pen_focus_updates_ = 0;
    stat_color_pen_focus_clears_ = 0;
    stat_color_pen_focus_truth_deferrals_ = 0;
    stat_color_pen_focus_disjoint_bypasses_ = 0;
    stat_pen_truth_input_rects_ = 0;
    stat_pen_truth_grouped_tiles_ = 0;
    stat_pen_truth_masked_lanes_ = 0;
    stat_pen_truth_groups_per_request_max_ = 0;
    color_preprocess_count_ = 0;
    stats_log_next_ = {};
    build_count_ = 0;

    pen_focus_accepting_.store(true, std::memory_order_release);
    engine_thread_ = std::thread(&Gallery3DrmPresenter::engine_thread_main, this);
    if (config_.mode_lab_step_ms > 0) {
      mode_lab_thread_ =
          std::thread(&Gallery3DrmPresenter::mode_lab_thread_main, this);
    }
    if (!config_.dry_run) {
      if (!scan_loop_.start()) {
        close();
        return kPlutoStatusInternal;
      }
      scan_expected_.store(true, std::memory_order_release);
    }
    return kPlutoStatusOk;
  }

  void close() {
    // Serialize teardown with the sole producer. Without this fence a
    // concurrent present() could enqueue after the quiescence audit below
    // and leave a stale warm-handoff file that claims pixels the panel never
    // scanned.
    pen_focus_accepting_.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> producer_lock(present_mutex_);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_ && !engine_thread_.joinable()) {
        return; // already closed
      }
      stopping_ = true;
    }
    engine_cv_.notify_all();
    idle_cv_.notify_all();
    glass_cv_.notify_all();
    handoff_cv_.notify_all();
    scan_expected_.store(false, std::memory_order_release);
    scan_loop_.stop();
    if (mode_lab_thread_.joinable()) {
      mode_lab_thread_.join();
    }
    if (engine_thread_.joinable()) {
      engine_thread_.join();
    }

    // stage_handoff() already stopped the scan only after the final content
    // latch's FOLLOWING feedback resolved its exact scan count and the engine
    // applied any double-scan recharge. Re-audit every mutable owner after the
    // threads join; save only the staged transaction if nothing changed.
    bool queues_empty = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      queues_empty =
          pending_frame_count_ == 0 && large_lane_.empty() &&
          color_lane_.empty() && double_scan_events_.empty() &&
          scan_feedback_events_.empty() &&
          color_obligation_count_.load(std::memory_order_acquire) == 0 &&
          mapped_terminal_count_.load(std::memory_order_acquire) == 0 &&
          mailbox_.size_approx() == 0 && completion_callbacks_pending_ == 0 &&
          handoff_capture_request_ == nullptr && !pen_focus_active_ &&
          !pen_focus_wake_.load(std::memory_order_acquire);
    }
    const bool engine_quiescent =
        engine_.configured() && engine_.handoff_safe() && !engine_busy();
    const bool scan_quiescent =
        config_.dry_run ||
        (!scan_loop_.ready_slot().unacknowledged() &&
         last_resolved_content_seq_.load(std::memory_order_acquire) >=
             last_published_content_seq_.load(std::memory_order_acquire));
    const bool color_quiescent =
        !color_enabled_ ||
        (color_pipeline_.history().valid() &&
         color_pipeline_.history().outstanding_count() == 0 &&
         mapped_events_.empty() && mapped_token_frames_.empty() &&
         mapped_terminal_fences_.empty() && safe_fast_frames_.empty() &&
         reserved_safe_fast_engine_ids_.empty());
    const bool handoff_safe =
        handoff_identity_valid_ && handoff_frozen_ &&
        staged_handoff_.has_value() && engine_quiescent && queues_empty &&
        scan_quiescent && color_quiescent && double_scan_scratch_.empty() &&
        scan_feedback_scratch_.empty() &&
        pending_pauses_.load(std::memory_order_acquire) == 0 &&
        stat_dropped_pieces_.load(std::memory_order_acquire) == 0 &&
        stat_color_faults_.load(std::memory_order_acquire) == 0 &&
        cold_clear_done_.load(std::memory_order_acquire) && !device_lost_;
    bool handoff_saved = false;
    if (handoff_safe) {
      staged_handoff_->written = glass_handoff_now();
      handoff_saved = glass_handoff_save(handoff_lease_, config_.handoff_path,
                                         *staged_handoff_);
    }
    if (!config_.handoff_path.empty() && handoff_lease_.valid() &&
        !handoff_saved) {
      // A failed/unsafe close must invalidate both a previously consumed seed
      // and an interrupted temporary write. Leaving either behind is worse
      // than the next process paying one conservative cold clear.
      if (!glass_handoff_discard(handoff_lease_, config_.handoff_path)) {
        std::fprintf(stderr,
                     "swtcon: unsafe handoff could not be invalidated\n");
      }
    } else if (handoff_saved) {
      std::fprintf(
          stderr, "swtcon: warm handoff saved bytes_pending_load=1 t_ns=%llu\n",
          static_cast<unsigned long long>(steady_now_ns()));
    }
    staged_handoff_.reset();
    temperature_.stop();
    if (device_ != nullptr) {
      (void)device_->blank();
      device_->close();
      device_.reset();
    }
    // Release only after the final bundle decision and DRM ownership end. The
    // persistent lease inode is never unlinked, avoiding split-lock races.
    handoff_lease_ = GlassHandoffLease{};
    frame_.clear();
    host_slots_.clear();
  }

  PlutoStatus info(PlutoDisplayInfo *out_info) const {
    if (out_info == nullptr ||
        out_info->struct_size < sizeof(PlutoDisplayInfo)) {
      return kPlutoStatusInvalidArgument;
    }
    *out_info = make_info();
    out_info->is_color = color_enabled_;
    out_info->backend_quantizes_color = color_enabled_;
    // Exact mapped truth is prepared only after any earlier safe Fast island
    // has reached a known scan latch and reseeded A/B. The renderer must not
    // assume it can submit overlapping truth ahead of that real dependency.
    out_info->supports_overlap_supersession = false;
    const float celsius = temperature_.current_celsius();
    const PlutoRefreshClass classes[4] = {kPlutoRefreshFast, kPlutoRefreshUi,
                                          kPlutoRefreshText, kPlutoRefreshFull};
    for (int i = 0; i < 4; ++i) {
      out_info->nominal_latency_ms[i] =
          latency_ms_for_class(classes[i], celsius);
    }
    return kPlutoStatusOk;
  }

  bool ready(PlutoRefreshClass refresh_class) const {
    const std::size_t color_limit =
        config_.color_lane_max +
        (refresh_class == kPlutoRefreshFast ? kColorFastReserve : 0u);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (device_lost_ || stopping_ || handoff_frozen_ ||
          large_lane_.size() >= config_.large_lane_max ||
          (color_enabled_ && color_obligation_count_.load(
                                 std::memory_order_acquire) >= color_limit)) {
        return false;
      }
    }
    if (!cold_clear_done_.load(std::memory_order_acquire)) {
      return false; // cold-clear gate: nothing admits until it completes
    }
    // The ONLY steady-state backpressure is mailbox-full.
    return mailbox_.size_approx() + kReadyHeadroomRecords <=
           mailbox_.capacity();
  }

  PlutoStatus set_pen_focus(const PlutoPenFocus *focus) {
    constexpr std::uint32_t kKnownFlags =
        static_cast<std::uint32_t>(kPlutoPenFocusInRange) |
        static_cast<std::uint32_t>(kPlutoPenFocusContact);
    if (focus == nullptr || focus->struct_size < sizeof(PlutoPenFocus) ||
        (focus->flags & ~kKnownFlags) != 0 ||
        ((focus->flags & kPlutoPenFocusContact) != 0 &&
         (focus->flags & kPlutoPenFocusInRange) == 0)) {
      return kPlutoStatusInvalidArgument;
    }
    const bool active = (focus->flags & kPlutoPenFocusInRange) != 0;
    std::int64_t right = 0;
    std::int64_t bottom = 0;
    if (active) {
      right = static_cast<std::int64_t>(focus->rect.x) + focus->rect.width;
      bottom = static_cast<std::int64_t>(focus->rect.y) + focus->rect.height;
      if (focus->rect.x < 0 || focus->rect.y < 0 || focus->rect.width <= 0 ||
          focus->rect.height <= 0 || right > kLogicalWidth ||
          bottom > kLogicalHeight) {
        return kPlutoStatusInvalidArgument;
      }
    }
    if (!pen_focus_accepting_.load(std::memory_order_acquire)) {
      return kPlutoStatusDeviceLost;
    }
    const std::uint64_t ticket =
        pen_focus_mailbox_write_.fetch_add(1, std::memory_order_relaxed) + 1;
    AtomicPenFocusSlot &slot =
        pen_focus_mailbox_[ticket % kPenFocusMailboxCapacity];
    slot.guard.store((ticket << 1u) | 1u, std::memory_order_release);
    slot.x.store(focus->rect.x, std::memory_order_relaxed);
    slot.y.store(focus->rect.y, std::memory_order_relaxed);
    slot.width.store(focus->rect.width, std::memory_order_relaxed);
    slot.height.store(focus->rect.height, std::memory_order_relaxed);
    slot.flags.store(focus->flags, std::memory_order_relaxed);
    slot.sequence.store(focus->sequence, std::memory_order_relaxed);
    slot.guard.store(ticket << 1u, std::memory_order_release);
    std::uint64_t published =
        pen_focus_mailbox_published_.load(std::memory_order_relaxed);
    while (published < ticket &&
           !pen_focus_mailbox_published_.compare_exchange_weak(
               published, ticket, std::memory_order_release,
               std::memory_order_relaxed)) {
    }
    // No presenter mutex on the SCHED_FIFO input path. The engine consumes
    // this fixed-size latest-wins value and rechecks it at the exact
    // pre-prepare ordering boundary.
    pen_focus_wake_.store(true, std::memory_order_release);
    engine_cv_.notify_all();
    return kPlutoStatusOk;
  }

  PlutoStatus present(const PlutoPresentRequest *request) {
    if (request == nullptr ||
        request->struct_size < sizeof(PlutoPresentRequest)) {
      return kPlutoStatusInvalidArgument;
    }
    const PlutoStatus validation = validate_request(*request);
    if (validation != kPlutoStatusOk) {
      return validation;
    }
    // frame_id rides at +kEngineFrameIdBias inside the engine (0 is the
    // engine's settle sentinel), so the top of the range is reserved.
    if (request->frame_id >=
        std::numeric_limits<std::uint64_t>::max() - kEngineFrameIdBias) {
      return kPlutoStatusInvalidArgument;
    }
    // The scheduler is the single producer today. Keep that ordering an
    // explicit contract and make the preallocated conversion scratch safe if
    // another producer is added later; the lock is uncontended in production.
    std::lock_guard<std::mutex> producer_lock(present_mutex_);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (device_lost_) {
        return kPlutoStatusDeviceLost;
      }
      if (stopping_ || handoff_frozen_) {
        return kPlutoStatusAgain;
      }
      const std::uint64_t abi_engine_frame_id =
          request->frame_id + kEngineFrameIdBias;
      if (std::find(reserved_safe_fast_engine_ids_.begin(),
                    reserved_safe_fast_engine_ids_.end(),
                    abi_engine_frame_id) !=
          reserved_safe_fast_engine_ids_.end()) {
        return kPlutoStatusAgain;
      }
    }
    if (!cold_clear_done_.load(std::memory_order_acquire)) {
      return kPlutoStatusAgain; // cold-clear admission gate
    }
    if (config_.mode_lab_step_ms > 0) {
      // Mode-lab diagnostic owns the glass: accept-and-discard app frames
      // (completion still owed) so bands are never painted over.
      const PlutoStatus handoff_status = consume_handoff_before_admission();
      if (handoff_status != kPlutoStatusOk) {
        return handoff_status;
      }
      deliver_immediate_completion(request->frame_id);
      return kPlutoStatusOk;
    }

    // Sparkle ghost repair: header-only per-tile admissions in the panel's
    // white top-off mode (GAL3 mode 8: 4 phases, drives near-white -> the
    // maintenance slot). The engine masks pixels by the pass phase (R2
    // low-discrepancy), so each pass tops off ~1/16 of the region's white
    // pixels — flash-free by construction. Tables without a top-off mode
    // complete the frame as an accepted no-op.
    const float admission_temperature = temperature_.current_celsius();
    const int admission_bin = select_admission_bin(admission_temperature);
    if ((request->flags & kPlutoPresentFlagSparkle) != 0) {
      if (color_enabled_) {
        // Unmapped sparkle/reset drives would mutate glass behind valid A/B
        // history. Until an exact mapped maintenance sequence is supplied,
        // the only safe behavior is an accepted no-op.
        const PlutoStatus handoff_status = consume_handoff_before_admission();
        if (handoff_status != kPlutoStatusOk) {
          return handoff_status;
        }
        deliver_immediate_completion(request->frame_id);
        return kPlutoStatusOk;
      }
      return present_sparkle(request, admission_bin);
    }

    if (color_enabled_) {
      return present_color(request, admission_bin, admission_temperature);
    }

    // Pick the waveform mode for the class (proven map Fast/Ui->7, Text->1,
    // Full->2; E1 refines) with a Full-mode fallback when the table lacks
    // the class mode. Manual pixel-reset rail stages are Fast-class, so they
    // use the strong short mode 7 before the final Full content redraw.
    const int mode = mode_for_class(request->refresh_class, admission_bin);
    if (mode < 0) {
      return kPlutoStatusInvalidArgument; // no drivable mode in the table
    }

    // Piece plan: tile-granular payload records through the mailbox;
    // rects too large for the busy-pixel budget go through the
    // large-admission lane as ONE engine admission so full-field band
    // amortization sees the whole rect (<= full_flash_band_frames
    // onset stagger; pre-split tiles would be budget-paced into a visibly
    // banded flash instead).
    const std::uint32_t tile_px = config_.engine.tile_px;
    std::size_t small_pieces = 0;
    std::size_t large_pieces = 0;
    for (std::size_t i = 0; i < request->damage_count; ++i) {
      const PlutoRect &rect = request->damage[i];
      const std::uint64_t area = static_cast<std::uint64_t>(rect.width) *
                                 static_cast<std::uint64_t>(rect.height);
      if (area > config_.engine.max_active_px) {
        ++large_pieces;
      } else {
        small_pieces += count_tile_pieces(rect, tile_px);
      }
    }
    const std::size_t total_pieces = small_pieces + large_pieces;
    if (total_pieces == 0) {
      return kPlutoStatusInvalidArgument;
    }

    // Backpressure precheck so a present never half-posts: the scheduler
    // thread is the single producer today (pen-correlated app damage uses the
    // same payload path), so size_approx() is exact from here. Large rects also
    // cost one mailbox record each — their order-preserving lane marker.
    if (mailbox_.size_approx() + small_pieces + large_pieces + 8 >
        mailbox_.capacity()) {
      return kPlutoStatusAgain;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (large_lane_.size() + large_pieces > config_.large_lane_max) {
        return kPlutoStatusAgain;
      }
    }
    const PlutoStatus handoff_status = consume_handoff_before_admission();
    if (handoff_status != kPlutoStatusOk) {
      return handoff_status;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      // Register completion bookkeeping BEFORE any piece can complete.
      FrameBookkeeping *bookkeeping =
          find_or_insert_pending_frame(request->frame_id);
      if (bookkeeping == nullptr) {
        return kPlutoStatusAgain;
      }
      bookkeeping->remaining += static_cast<std::uint32_t>(total_pieces);
      bookkeeping->refresh_class = request->refresh_class;
      bookkeeping->mode = mode;
    }

    const std::uint64_t engine_frame_id =
        request->frame_id + kEngineFrameIdBias;
    std::size_t failed_pieces = 0;
    const std::uint8_t *legal_targets = legal_map_for(mode, admission_bin);
    // Renderer quality settles are marked so the engine may fold DC-stress
    // balanced promotion into them (never into live content admissions);
    // InkPriority (the ABI-stable name for pen-correlated app damage) marks
    // low-latency app pixels so they ride along in-flight same-mode tiles
    // instead of parking. PenTruth needs no internal flag here: direct SWTCON
    // already preserves every request's regional damage geometry.
    std::uint32_t admit_flags = 0;
    if ((request->flags & kPlutoPresentFlagSettle) != 0 &&
        (request->flags & kPlutoPresentFlagRequiredSettle) == 0) {
      admit_flags |= static_cast<std::uint32_t>(swtcon::kAdmitFlagQuality);
    }
    if ((request->flags & kPlutoPresentFlagInkPriority) != 0) {
      admit_flags |= static_cast<std::uint32_t>(swtcon::kAdmitFlagPenPreview);
    }
    std::uint8_t *const piece_levels = piece_levels_scratch_.data();
    for (std::size_t i = 0; i < request->damage_count; ++i) {
      const PlutoRect &rect = request->damage[i];
      const std::uint64_t area = static_cast<std::uint64_t>(rect.width) *
                                 static_cast<std::uint64_t>(rect.height);
      if (area > config_.engine.max_active_px) {
        LargeAdmit large;
        large.rect = rect;
        large.mode = mode;
        large.temp_bin = admission_bin;
        large.engine_frame_id = engine_frame_id;
        large.admit_flags = admit_flags;
        // Reuse a drained buffer: a fresh full-screen levels vector is a
        // 1.6 MB allocation + page-fault storm per large admission on the
        // scheduler thread; the pool keeps those pages warm.
        {
          std::lock_guard<std::mutex> lock(mutex_);
          if (!level_buffer_pool_.empty()) {
            large.levels = std::move(level_buffer_pool_.back());
            level_buffer_pool_.pop_back();
          }
        }
        large.levels.resize(static_cast<std::size_t>(area));
        convert_levels(request->surface, rect, legal_targets,
                       large.levels.data());
        {
          std::lock_guard<std::mutex> lock(mutex_);
          large_lane_.push_back(std::move(large));
        }
        // Order-preserving marker: the engine drain pops ONE large-lane
        // entry when it meets this record, so the full-field flash admits
        // in present() order relative to every tile record around it —
        // draining the lane out of band would let an OLDER full-field
        // admission supersede NEWER tile content (scene-bleed). The lane
        // entry is appended BEFORE the marker is published, so the drain
        // can never meet a marker without its entry.
        AdmitRequest marker;
        marker.rect = rect;
        marker.mode = mode;
        marker.temp_bin = admission_bin;
        marker.levels = nullptr;
        marker.frame_id = 0;
        marker.flags = kAdmitFlagLargeLane;
        if (mailbox_.push(marker) != kPlutoStatusOk) {
          // Defensive (the precheck reserves marker capacity): withdraw
          // the lane entry so lane and markers stay paired 1:1.
          {
            std::lock_guard<std::mutex> lock(mutex_);
            large_lane_.pop_back();
          }
          ++failed_pieces;
        }
        continue;
      }
      // Tile-grid-aligned pieces: each fits one mailbox payload record and
      // never straddles engine tiles (parks shrink to the conflict tile).
      const std::int32_t ty0 = rect.y / static_cast<std::int32_t>(tile_px);
      const std::int32_t ty1 =
          (rect.y + rect.height - 1) / static_cast<std::int32_t>(tile_px);
      const std::int32_t tx0 = rect.x / static_cast<std::int32_t>(tile_px);
      const std::int32_t tx1 =
          (rect.x + rect.width - 1) / static_cast<std::int32_t>(tile_px);
      for (std::int32_t ty = ty0; ty <= ty1; ++ty) {
        for (std::int32_t tx = tx0; tx <= tx1; ++tx) {
          PlutoRect piece;
          piece.x = std::max(rect.x, tx * static_cast<std::int32_t>(tile_px));
          piece.y = std::max(rect.y, ty * static_cast<std::int32_t>(tile_px));
          piece.width =
              std::min(rect.x + rect.width,
                       (tx + 1) * static_cast<std::int32_t>(tile_px)) -
              piece.x;
          piece.height =
              std::min(rect.y + rect.height,
                       (ty + 1) * static_cast<std::int32_t>(tile_px)) -
              piece.y;
          convert_levels(request->surface, piece, legal_targets, piece_levels);
          AdmitRequest admit;
          admit.rect = piece;
          admit.mode = mode;
          admit.temp_bin = admission_bin;
          admit.levels = piece_levels;
          admit.levels_stride = 0;
          admit.frame_id = engine_frame_id;
          admit.flags = admit_flags;
          if (mailbox_.push(admit) != kPlutoStatusOk) {
            ++failed_pieces; // precheck makes this unreachable in practice
          }
        }
      }
    }
    if (failed_pieces > 0) {
      settle_failed_pieces(request->frame_id, failed_pieces);
    }

    // Snapshot mirror (CLI screenshots): damage-rect copy only, on its own
    // mutex so it never contends with the frame path.
    {
      std::lock_guard<std::mutex> lock(snapshot_mutex_);
      copy_damage_into_frame(*request, frame_.data());
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      admissions_signal_ = true;
    }
    engine_cv_.notify_all();
    return kPlutoStatusOk;
  }

  // Sole-producer helper. Once an admission is accepted, its process may
  // crash at any later instruction; unlink the consumed candidate before
  // publishing bookkeeping, mirrors, queues, or mapped journals.
  PlutoStatus consume_handoff_before_admission() {
    if (handoff_unlinked_ || config_.handoff_path.empty()) {
      std::uint64_t no_admission = 0;
      (void)first_user_admission_t_ns_.compare_exchange_strong(
          no_admission, steady_now_ns(), std::memory_order_release,
          std::memory_order_relaxed);
      return kPlutoStatusOk;
    }
    if (!glass_handoff_claim(handoff_lease_, config_.handoff_path,
                             incoming_handoff_claim_)) {
      std::fprintf(stderr,
                   "swtcon: exact warm handoff claim lost; admission refused "
                   "and process forced to cold restart\n");
      handoff_unlinked_ = true;
      incoming_handoff_claim_ = {};
      staged_handoff_.reset();
      set_scan_identity_fault("warm handoff candidate changed before first "
                              "admission");
      return kPlutoStatusDeviceLost;
    }
    handoff_unlinked_ = true;
    incoming_handoff_claim_ = {};
    staged_handoff_.reset();
    const std::uint64_t admission_ns = steady_now_ns();
    std::uint64_t no_admission = 0;
    (void)first_user_admission_t_ns_.compare_exchange_strong(
        no_admission, admission_ns, std::memory_order_release,
        std::memory_order_relaxed);
    if (warm_handoff_accepted_.load(std::memory_order_acquire)) {
      std::fprintf(stderr, "swtcon: warm handoff consumed t_ns=%llu\n",
                   static_cast<unsigned long long>(admission_ns));
    }
    return kPlutoStatusOk;
  }

  // Sparkle top-off present: header-only per-tile admissions in the white
  // maintenance mode; the engine does the per-pixel phase masking. Levels
  // are never read, so no conversion, no mirror copy, no large lane.
  PlutoStatus present_sparkle(const PlutoPresentRequest *request,
                              int admission_bin) {
    const bool develop =
        (request->flags & kPlutoPresentFlagSparkleDevelop) != 0;
    const int sparkle_mode =
        develop ? kSparkleDevelopWaveformMode : kSparkleWaveformMode;
    const swtcon::WaveformTable &table = waveform_.table();
    if (table.phase_count(sparkle_mode, admission_bin) <= 0) {
      // No sparkle mode in this table: accepted no-op, completion still
      // owed (host synthetic tables / non-GAL3 panels).
      const PlutoStatus handoff_status = consume_handoff_before_admission();
      if (handoff_status != kPlutoStatusOk) {
        return handoff_status;
      }
      deliver_immediate_completion(request->frame_id);
      return kPlutoStatusOk;
    }
    const std::uint32_t tile_px = config_.engine.tile_px;
    std::size_t total_pieces = 0;
    for (std::size_t i = 0; i < request->damage_count; ++i) {
      total_pieces += count_tile_pieces(request->damage[i], tile_px);
    }
    if (total_pieces == 0) {
      return kPlutoStatusInvalidArgument;
    }
    if (mailbox_.size_approx() + total_pieces + 8 > mailbox_.capacity()) {
      return kPlutoStatusAgain;
    }
    const PlutoStatus handoff_status = consume_handoff_before_admission();
    if (handoff_status != kPlutoStatusOk) {
      return handoff_status;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      FrameBookkeeping *bookkeeping =
          find_or_insert_pending_frame(request->frame_id);
      if (bookkeeping == nullptr) {
        return kPlutoStatusAgain;
      }
      bookkeeping->remaining += static_cast<std::uint32_t>(total_pieces);
      bookkeeping->refresh_class = request->refresh_class;
      bookkeeping->mode = sparkle_mode;
    }
    const std::uint64_t engine_frame_id =
        request->frame_id + kEngineFrameIdBias;
    const std::uint32_t sparkle_flags =
        static_cast<std::uint32_t>(swtcon::kAdmitFlagSparkle) |
        (develop ? static_cast<std::uint32_t>(swtcon::kAdmitFlagSparkleDevelop)
                 : 0u) |
        (request->flags & kPlutoPresentSparklePhaseMask);
    std::size_t failed_pieces = 0;
    for (std::size_t i = 0; i < request->damage_count; ++i) {
      const PlutoRect &rect = request->damage[i];
      const std::int32_t tile = static_cast<std::int32_t>(tile_px);
      const std::int32_t ty0 = rect.y / tile;
      const std::int32_t ty1 = (rect.y + rect.height - 1) / tile;
      const std::int32_t tx0 = rect.x / tile;
      const std::int32_t tx1 = (rect.x + rect.width - 1) / tile;
      for (std::int32_t ty = ty0; ty <= ty1; ++ty) {
        for (std::int32_t tx = tx0; tx <= tx1; ++tx) {
          AdmitRequest admit;
          admit.rect.x = std::max(rect.x, tx * tile);
          admit.rect.y = std::max(rect.y, ty * tile);
          admit.rect.width =
              std::min(rect.x + rect.width, (tx + 1) * tile) - admit.rect.x;
          admit.rect.height =
              std::min(rect.y + rect.height, (ty + 1) * tile) - admit.rect.y;
          admit.mode = sparkle_mode;
          admit.temp_bin = admission_bin;
          admit.levels = nullptr;
          admit.levels_stride = 0;
          admit.frame_id = engine_frame_id;
          admit.flags = sparkle_flags;
          if (mailbox_.push(admit) != kPlutoStatusOk) {
            ++failed_pieces;
          }
        }
      }
    }
    if (failed_pieces > 0) {
      settle_failed_pieces(request->frame_id, failed_pieces);
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      admissions_signal_ = true;
    }
    engine_cv_.notify_all();
    return kPlutoStatusOk;
  }

  PlutoStatus present_color(const PlutoPresentRequest *request,
                            int admission_bin, float admission_temperature) {
    const auto preprocess_start = std::chrono::steady_clock::now();
    if (request == nullptr ||
        request->surface.stride_bytes >
            std::numeric_limits<std::size_t>::max() /
                static_cast<std::size_t>(kLogicalHeight)) {
      return kPlutoStatusInvalidArgument;
    }
    const XochitlHistoryState::Mode color_mode =
        color_mode_for_class(request->refresh_class);
    const bool safe_fast = color_mode == XochitlHistoryState::Mode::kFast;
    const bool pen_truth_grouping_allowed =
        (request->flags & kPlutoPresentFlagPenTruth) != 0u &&
        (color_mode == XochitlHistoryState::Mode::kText ||
         color_mode == XochitlHistoryState::Mode::kFull);

    struct PenTruthTileGroup {
      XochitlHistoryState::InclusiveRect update{};
      std::size_t mask_stride = 0;
      std::vector<std::uint8_t> mask;
      std::vector<std::size_t> contributors;
      std::uint64_t authored_lanes = 0;
    };
    struct ColorPiecePlan {
      // Exactly one of these is set. Group indices are non-negative; original
      // damage indices use group == -1.
      std::int32_t group = -1;
      std::size_t damage = 0;
    };
    std::vector<PenTruthTileGroup> pen_truth_groups;
    std::vector<ColorPiecePlan> piece_plan;
    std::uint64_t pen_truth_input_rects = 0;
    std::uint64_t pen_truth_masked_lanes = 0;
    if (pen_truth_grouping_allowed && request->damage_count > 1u) {
      // PixelEngine ownership is 32 px tile-granular. Coalesce only mapper
      // executions wholly contained by one tile. Splitting an existing dense
      // operation at a tile seam changes the legacy mapper's boundary halo,
      // so spanning operations stay byte-for-byte on the old path. A tile is
      // also ineligible when any such original operation touches it: grouping
      // the other contributors would not remove the ownership collision.
      const std::int32_t tile =
          static_cast<std::int32_t>(config_.engine.tile_px);
      if (tile <= 0 || (tile & 7) != 0 || (tile & 1) != 0) {
        return kPlutoStatusInternal;
      }
      const std::int32_t tile_columns =
          (config_.engine.stride + tile - 1) / tile;
      const std::int32_t tile_rows = (config_.engine.height + tile - 1) / tile;
      const std::size_t tile_count =
          static_cast<std::size_t>(tile_columns) * tile_rows;
      std::vector<std::int32_t> candidate_tile(request->damage_count, -1);
      std::vector<std::vector<std::size_t>> tile_contributors(tile_count);
      std::vector<std::uint8_t> tile_blocked(tile_count, 0u);
      for (std::size_t damage_index = 0; damage_index < request->damage_count;
           ++damage_index) {
        const PlutoRect &damage = request->damage[damage_index];
        const std::int32_t execution_width = (damage.width + 7) & ~7;
        const std::int32_t execution_height = (damage.height + 1) & ~1;
        const std::int32_t execution_right = damage.x + execution_width - 1;
        const std::int32_t execution_bottom = damage.y + execution_height - 1;
        const std::int32_t tx0 = damage.x / tile;
        const std::int32_t tx1 =
            std::min(execution_right / tile, tile_columns - 1);
        const std::int32_t ty0 = damage.y / tile;
        const std::int32_t ty1 =
            std::min(execution_bottom / tile, tile_rows - 1);
        if (tx0 == tx1 && ty0 == ty1 && execution_right < (tx0 + 1) * tile &&
            execution_bottom < (ty0 + 1) * tile) {
          const std::size_t tile_index =
              static_cast<std::size_t>(ty0) * tile_columns + tx0;
          candidate_tile[damage_index] = static_cast<std::int32_t>(tile_index);
          tile_contributors[tile_index].push_back(damage_index);
          continue;
        }
        for (std::int32_t ty = ty0; ty <= ty1; ++ty) {
          for (std::int32_t tx = tx0; tx <= tx1; ++tx) {
            const std::size_t tile_index =
                static_cast<std::size_t>(ty) * tile_columns + tx;
            tile_blocked[tile_index] = 1u;
          }
        }
      }

      std::vector<std::int32_t> group_for_tile(tile_count, -1);
      pen_truth_groups.reserve(request->damage_count / 2u);
      for (std::size_t tile_index = 0; tile_index < tile_count; ++tile_index) {
        const std::vector<std::size_t> &contributors =
            tile_contributors[tile_index];
        if (tile_blocked[tile_index] != 0u || contributors.size() < 2u) {
          continue;
        }
        PenTruthTileGroup group;
        group.contributors = contributors;
        const PlutoRect &first = request->damage[contributors.front()];
        group.update = {first.x, first.y, first.x + first.width - 1,
                        first.y + first.height - 1};
        std::int32_t envelope_right = first.x + ((first.width + 7) & ~7) - 1;
        std::int32_t envelope_bottom = first.y + ((first.height + 1) & ~1) - 1;
        for (const std::size_t damage_index : contributors) {
          const PlutoRect &damage = request->damage[damage_index];
          group.update.left = std::min(group.update.left, damage.x);
          group.update.top = std::min(group.update.top, damage.y);
          envelope_right = std::max(envelope_right,
                                    damage.x + ((damage.width + 7) & ~7) - 1);
          envelope_bottom = std::max(envelope_bottom,
                                     damage.y + ((damage.height + 1) & ~1) - 1);
        }
        group.update.right = std::min(envelope_right, kLogicalWidth - 1);
        group.update.bottom = std::min(envelope_bottom, kLogicalHeight - 1);
        const std::int32_t expected_tx =
            static_cast<std::int32_t>(tile_index % tile_columns);
        const std::int32_t expected_ty =
            static_cast<std::int32_t>(tile_index / tile_columns);
        const std::int32_t tile_left = expected_tx * tile;
        const std::int32_t tile_right = (expected_tx + 1) * tile - 1;
        const std::int32_t tile_top = expected_ty * tile;
        const std::int32_t tile_bottom = (expected_ty + 1) * tile - 1;
        bool x_anchor_found = false;
        for (std::int32_t left = group.update.left; left >= tile_left; --left) {
          const std::int32_t width = (group.update.right - left + 8) & ~7;
          const std::int32_t right = left + width - 1;
          if (right >= envelope_right && right <= tile_right) {
            group.update.left = left;
            x_anchor_found = true;
            break;
          }
        }
        bool y_anchor_found = false;
        for (std::int32_t top = group.update.top; top >= tile_top; --top) {
          const std::int32_t height = (group.update.bottom - top + 2) & ~1;
          const std::int32_t bottom = top + height - 1;
          if (bottom >= envelope_bottom && bottom <= tile_bottom) {
            group.update.top = top;
            y_anchor_found = true;
            break;
          }
        }
        if (!x_anchor_found || !y_anchor_found) {
          // No single operation inside the ownership tile preserves every
          // contributor's independently rounded mapper envelope.
          continue;
        }
        const std::int32_t execution_width =
            (group.update.right - group.update.left + 8) & ~7;
        const std::int32_t execution_height =
            (group.update.bottom - group.update.top + 2) & ~1;
        const std::int32_t group_execution_right =
            group.update.left + execution_width - 1;
        const std::int32_t group_execution_bottom =
            group.update.top + execution_height - 1;
        if (group.update.left / tile != expected_tx ||
            group_execution_right / tile != expected_tx ||
            group.update.top / tile != expected_ty ||
            group_execution_bottom / tile != expected_ty ||
            group_execution_right < envelope_right ||
            group_execution_bottom < envelope_bottom) {
          // Preserve the originals if the bounded anchor proof ever drifts.
          continue;
        }
        group.mask_stride = static_cast<std::size_t>(execution_width);
        group.mask.assign(
            static_cast<std::size_t>(execution_width) * execution_height, 0u);
        for (const std::size_t damage_index : contributors) {
          const PlutoRect &damage = request->damage[damage_index];
          for (std::int32_t y = damage.y; y < damage.y + damage.height; ++y) {
            std::uint8_t *mask_row =
                group.mask.data() +
                static_cast<std::size_t>(y - group.update.top) *
                    group.mask_stride;
            for (std::int32_t x = damage.x; x < damage.x + damage.width; ++x) {
              std::uint8_t &selected = mask_row[x - group.update.left];
              if (selected == 0u) {
                selected = 1u;
                ++group.authored_lanes;
              }
            }
          }
        }
        // Packed right/bottom guards are part of the stock mapper contract.
        // They mirror a selected logical edge for context/history but are not
        // counted as app-authored or emitted beyond the configured panel.
        if (group.update.right == kLogicalWidth - 1) {
          const std::size_t edge =
              static_cast<std::size_t>(kLogicalWidth - 1 - group.update.left);
          for (std::int32_t y = 0; y < execution_height; ++y) {
            std::uint8_t *row = group.mask.data() +
                                static_cast<std::size_t>(y) * group.mask_stride;
            if (row[edge] != 0u) {
              std::fill(row + edge + 1, row + group.mask_stride, 1u);
            }
          }
        }
        if (group.update.bottom == kLogicalHeight - 1) {
          const std::size_t logical_rows =
              static_cast<std::size_t>(kLogicalHeight - group.update.top);
          for (std::size_t y = logical_rows;
               y < static_cast<std::size_t>(execution_height); ++y) {
            std::copy_n(
                group.mask.data() + (logical_rows - 1u) * group.mask_stride,
                group.mask_stride, group.mask.data() + y * group.mask_stride);
          }
        }
        group_for_tile[tile_index] =
            static_cast<std::int32_t>(pen_truth_groups.size());
        pen_truth_input_rects += contributors.size();
        pen_truth_masked_lanes += group.authored_lanes;
        pen_truth_groups.push_back(std::move(group));
      }

      std::vector<std::uint8_t> emitted_group(pen_truth_groups.size(), 0u);
      piece_plan.reserve(request->damage_count);
      for (std::size_t damage_index = 0; damage_index < request->damage_count;
           ++damage_index) {
        const std::int32_t tile_index = candidate_tile[damage_index];
        const std::int32_t group_index =
            tile_index >= 0
                ? group_for_tile[static_cast<std::size_t>(tile_index)]
                : -1;
        if (group_index < 0) {
          piece_plan.push_back({.group = -1, .damage = damage_index});
          continue;
        }
        std::uint8_t &emitted =
            emitted_group[static_cast<std::size_t>(group_index)];
        if (emitted == 0u) {
          emitted = 1u;
          piece_plan.push_back({.group = group_index, .damage = damage_index});
        }
      }
    }
    if (piece_plan.empty()) {
      piece_plan.reserve(request->damage_count);
      for (std::size_t damage_index = 0; damage_index < request->damage_count;
           ++damage_index) {
        piece_plan.push_back({.group = -1, .damage = damage_index});
      }
    }
    const bool coalesce_pen_truth = !pen_truth_groups.empty();
    const std::size_t planned_pieces = piece_plan.size();
    if (planned_pieces == 0u) {
      return kPlutoStatusInvalidArgument;
    }
    const std::size_t color_limit =
        config_.color_lane_max + (safe_fast ? kColorFastReserve : 0u);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const std::size_t obligations =
          color_obligation_count_.load(std::memory_order_acquire);
      if (obligations > color_limit ||
          planned_pieces > color_limit - obligations) {
        if (safe_fast) {
          ++stat_color_fast_reserve_declines_;
        }
        return kPlutoStatusAgain;
      }
    }

    if (planned_pieces >
        std::numeric_limits<std::uint64_t>::max() - next_color_retry_cookie_) {
      set_color_fault("mapped retry cookie exhausted");
      return kPlutoStatusDeviceLost;
    }
    if (safe_fast &&
        (next_fast_present_seq_ == std::numeric_limits<std::uint64_t>::max() ||
         planned_pieces > std::numeric_limits<std::uint64_t>::max() -
                              next_fast_piece_seq_)) {
      set_color_fault("safe Fast present sequence exhausted");
      return kPlutoStatusDeviceLost;
    }
    const std::uint64_t fast_present_seq =
        safe_fast ? next_fast_present_seq_++ : 0;
    const int raw_mode = static_cast<int>(color_mode);
    if (waveform_.table().phase_count(raw_mode, admission_bin) <= 0) {
      return kPlutoStatusInvalidArgument;
    }
    const std::size_t surface_bytes = request->surface.stride_bytes *
                                      static_cast<std::size_t>(kLogicalHeight);
    const std::span<const std::uint8_t> surface(request->surface.pixels,
                                                surface_bytes);
    std::vector<ColorAdmit> built;
    built.reserve(planned_pieces);
    const std::uint64_t engine_frame_id =
        request->frame_id + kEngineFrameIdBias;
    const std::uint64_t enqueued_ns = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
    for (std::size_t i = 0; i < planned_pieces; ++i) {
      XochitlHistoryState::InclusiveRect update{};
      std::span<const std::uint8_t> lane_mask;
      std::size_t lane_mask_stride = 0;
      const ColorPiecePlan &piece = piece_plan[i];
      if (piece.group >= 0) {
        const PenTruthTileGroup &group =
            pen_truth_groups[static_cast<std::size_t>(piece.group)];
        update = group.update;
        lane_mask = group.mask;
        lane_mask_stride = group.mask_stride;
      } else {
        const PlutoRect &damage = request->damage[piece.damage];
        update = {damage.x, damage.y, damage.x + damage.width - 1,
                  damage.y + damage.height - 1};
      }
      XochitlColorPipeline::BuildResult result =
          color_pipeline_.preprocess_rgb565(
              surface, request->surface.stride_bytes, update, color_mode,
              admission_bin, admission_temperature, lane_mask,
              lane_mask_stride);
      if (!result) {
        return kPlutoStatusInternal;
      }
      ColorAdmit admit;
      admit.payload = std::move(result.operation);
      admit.engine_frame_id = engine_frame_id;
      admit.fast_present_seq = fast_present_seq;
      admit.fast_piece_seq = safe_fast ? next_fast_piece_seq_++ : 0;
      admit.fast_piece_index = static_cast<std::uint32_t>(i);
      admit.fast_piece_count = static_cast<std::uint32_t>(planned_pieces);
      admit.retry_cookie = next_color_retry_cookie_++;
      admit.enqueued_ns = enqueued_ns;
      built.push_back(std::move(admit));
    }
    const std::uint64_t preprocess_us = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - preprocess_start)
            .count());

    {
      std::lock_guard<std::mutex> lock(mutex_);
      const std::size_t current_obligations =
          color_obligation_count_.load(std::memory_order_acquire);
      if (device_lost_) {
        return kPlutoStatusDeviceLost;
      }
      if (stopping_ || handoff_frozen_ || current_obligations > color_limit ||
          built.size() > color_limit - current_obligations) {
        return kPlutoStatusAgain;
      }
    }
    const PlutoStatus handoff_status = consume_handoff_before_admission();
    if (handoff_status != kPlutoStatusOk) {
      return handoff_status;
    }

    // Publish the newest app truth before the engine can dequeue its optical
    // payload. Keep the 3.2 MB worst-case copy off the real-time glue mutex.
    {
      std::lock_guard<std::mutex> snapshot_lock(snapshot_mutex_);
      copy_damage_into_frame(*request, frame_.data());
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (device_lost_) {
        return kPlutoStatusDeviceLost;
      }
      const std::size_t current_obligations =
          color_obligation_count_.load(std::memory_order_acquire);
      if (stopping_ || current_obligations > color_limit ||
          built.size() > color_limit - current_obligations) {
        return kPlutoStatusAgain;
      }
      if (safe_fast) {
        for (ColorAdmit &admit : built) {
          admit.safe_fast_engine_id =
              allocate_safe_fast_engine_id_locked(engine_frame_id);
          if (admit.safe_fast_engine_id == 0) {
            return kPlutoStatusInternal;
          }
        }
      }
      FrameBookkeeping *bookkeeping =
          find_or_insert_pending_frame(request->frame_id);
      if (bookkeeping == nullptr) {
        return kPlutoStatusAgain;
      }
      bookkeeping->remaining += static_cast<std::uint32_t>(built.size());
      bookkeeping->refresh_class = request->refresh_class;
      bookkeeping->mode = raw_mode;
      if (safe_fast) {
        for (const ColorAdmit &admit : built) {
          reserved_safe_fast_engine_ids_.push_back(admit.safe_fast_engine_id);
        }
      }
      color_lane_.insert(color_lane_.end(),
                         std::make_move_iterator(built.begin()),
                         std::make_move_iterator(built.end()));
      const std::size_t total_after =
          color_obligation_count_.fetch_add(built.size(),
                                            std::memory_order_release) +
          built.size();
      std::size_t fast_after =
          color_fast_obligation_count_.load(std::memory_order_acquire);
      if (safe_fast) {
        fast_after = color_fast_obligation_count_.fetch_add(
                         built.size(), std::memory_order_release) +
                     built.size();
        if (total_after > config_.color_lane_max) {
          ++stat_color_fast_reserve_uses_;
        }
      }
      stat_color_fast_obligation_peak_ =
          std::max<std::uint64_t>(stat_color_fast_obligation_peak_, fast_after);
      stat_color_truth_obligation_peak_ = std::max<std::uint64_t>(
          stat_color_truth_obligation_peak_, total_after - fast_after);
      color_preprocess_us_ring_[color_preprocess_count_ %
                                color_preprocess_us_ring_.size()] =
          static_cast<std::uint32_t>(
              std::min<std::uint64_t>(preprocess_us, 0xffffffffu));
      ++color_preprocess_count_;
      stat_color_queue_peak_ = std::max<std::uint64_t>(
          stat_color_queue_peak_,
          color_obligation_count_.load(std::memory_order_acquire));
      if (coalesce_pen_truth) {
        stat_pen_truth_input_rects_ += pen_truth_input_rects;
        stat_pen_truth_grouped_tiles_ += pen_truth_groups.size();
        stat_pen_truth_masked_lanes_ += pen_truth_masked_lanes;
        stat_pen_truth_groups_per_request_max_ = std::max<std::uint64_t>(
            stat_pen_truth_groups_per_request_max_, pen_truth_groups.size());
      }
      admissions_signal_ = true;
    }
    engine_cv_.notify_all();
    return kPlutoStatusOk;
  }

  PlutoStatus wait_idle(std::uint32_t timeout_ms) {
    std::unique_lock<std::mutex> lock(mutex_);
    const auto done = [this] {
      return cold_clear_done_.load(std::memory_order_acquire) &&
             pending_frame_count_ == 0 && large_lane_.empty() &&
             color_lane_.empty() &&
             color_obligation_count_.load(std::memory_order_acquire) == 0 &&
             mapped_terminal_count_.load(std::memory_order_acquire) == 0 &&
             mailbox_.size_approx() == 0 &&
             completion_callbacks_pending_ == 0 &&
             (config_.dry_run || !scan_loop_.ready_slot().unacknowledged());
    };
    if (device_lost_) {
      return kPlutoStatusDeviceLost;
    }
    if (done()) {
      return kPlutoStatusOk;
    }
    if (timeout_ms == 0) {
      return kPlutoStatusTimeout;
    }
    const bool completed = idle_cv_.wait_for(
        lock, std::chrono::milliseconds(timeout_ms),
        [this, &done] { return done() || device_lost_ || stopping_; });
    if (device_lost_) {
      return kPlutoStatusDeviceLost;
    }
    if (!completed || !done()) {
      return kPlutoStatusTimeout;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus stage_handoff(const PlutoHandoffPayload *payload,
                            std::uint32_t timeout_ms) {
    if (payload == nullptr ||
        payload->struct_size < sizeof(PlutoHandoffPayload) ||
        payload->bytes == nullptr || payload->byte_count == 0 ||
        payload->byte_count > kGlassHandoffMaxBytes || payload->width <= 0 ||
        payload->height <= 0 ||
        payload->pixel_format != kPlutoPixelFormatRgb565 ||
        payload->configuration_hash == 0) {
      return kPlutoStatusInvalidArgument;
    }
    if (!handoff_identity_valid_) {
      return kPlutoStatusUnsupported;
    }

    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(timeout_ms);
    const auto remaining_ms = [&deadline]() -> std::uint32_t {
      const auto now = std::chrono::steady_clock::now();
      if (now >= deadline) {
        return 0;
      }
      const auto remaining =
          std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now)
              .count();
      return static_cast<std::uint32_t>(std::max<long long>(1, remaining));
    };

    // Sole producer fence: no admission can race the optical barrier or the
    // engine-thread snapshot. A successful stage freezes this presenter; its
    // only legal successor is close().
    std::lock_guard<std::mutex> producer_lock(present_mutex_);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_ || device_lost_ || handoff_frozen_ ||
          handoff_decision_ == HandoffDecision::kPending ||
          handoff_chain_next_ >= kGlassHandoffMaxChain) {
        return device_lost_ ? kPlutoStatusDeviceLost : kPlutoStatusAgain;
      }
    }
    if (wait_idle(remaining_ms()) != kPlutoStatusOk) {
      return device_lost_ ? kPlutoStatusDeviceLost : kPlutoStatusTimeout;
    }

    const std::uint64_t final_content =
        last_published_content_seq_.load(std::memory_order_acquire);
    if (!config_.dry_run && final_content != 0) {
      std::unique_lock<std::mutex> lock(mutex_);
      const bool resolved =
          handoff_cv_.wait_until(lock, deadline, [this, final_content] {
            return stopping_ || device_lost_ ||
                   last_resolved_content_seq_.load(std::memory_order_acquire) >=
                       final_content;
          });
      if (!resolved || stopping_) {
        return kPlutoStatusTimeout;
      }
      if (device_lost_) {
        return kPlutoStatusDeviceLost;
      }
    }

    // No later scan may introduce fresh feedback after the capture audit.
    // scan_expected_ drops first so the engine's health check treats this as
    // an intentional terminal freeze rather than device loss.
    pen_focus_accepting_.store(false, std::memory_order_release);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      handoff_frozen_ = true;
    }
    if (!config_.dry_run) {
      scan_expected_.store(false, std::memory_order_release);
      scan_loop_.stop();
    }

    const auto capture = std::make_shared<HandoffCaptureRequest>();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      handoff_capture_request_ = capture;
    }
    engine_cv_.notify_all();
    {
      std::unique_lock<std::mutex> lock(mutex_);
      if (!handoff_cv_.wait_until(lock, deadline,
                                  [this, &capture] {
                                    return capture->done || stopping_ ||
                                           device_lost_;
                                  }) ||
          !capture->done) {
        if (handoff_capture_request_ == capture) {
          handoff_capture_request_.reset();
        }
        return device_lost_ ? kPlutoStatusDeviceLost : kPlutoStatusTimeout;
      }
    }
    if (!capture->success) {
      return kPlutoStatusInternal;
    }

    GlassHandoffBundle staged;
    staged.identity = handoff_identity_;
    staged.renderer = {
        .width = static_cast<std::uint32_t>(payload->width),
        .height = static_cast<std::uint32_t>(payload->height),
        .rotation = payload->rotation,
        .pixel_format = static_cast<std::uint32_t>(payload->pixel_format),
        .configuration_hash = payload->configuration_hash,
    };
    staged.written = glass_handoff_now();
    staged.chain = handoff_chain_next_;
    staged.core = std::move(capture->core);
    staged.renderer_payload.assign(payload->bytes,
                                   payload->bytes + payload->byte_count);
    staged_handoff_ = std::move(staged);
    std::fprintf(stderr,
                 "swtcon: warm handoff staged chain=%u renderer_bytes=%zu "
                 "final_seq=%llu t_ns=%llu\n",
                 handoff_chain_next_, payload->byte_count,
                 static_cast<unsigned long long>(final_content),
                 static_cast<unsigned long long>(steady_now_ns()));
    return kPlutoStatusOk;
  }

  PlutoStatus get_handoff(PlutoHandoffPayload *out_payload) {
    if (out_payload == nullptr ||
        out_payload->struct_size < sizeof(PlutoHandoffPayload)) {
      return kPlutoStatusInvalidArgument;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (device_lost_) {
      return kPlutoStatusDeviceLost;
    }
    if (!handoff_core_seeded_ ||
        handoff_decision_ != HandoffDecision::kPending ||
        incoming_renderer_payload_.empty()) {
      return kPlutoStatusAgain;
    }
    *out_payload = {
        .struct_size = sizeof(PlutoHandoffPayload),
        .bytes = incoming_renderer_payload_.data(),
        .byte_count = incoming_renderer_payload_.size(),
        .width = static_cast<std::int32_t>(incoming_renderer_info_.width),
        .height = static_cast<std::int32_t>(incoming_renderer_info_.height),
        .rotation = incoming_renderer_info_.rotation,
        .pixel_format =
            static_cast<PlutoPixelFormat>(incoming_renderer_info_.pixel_format),
        .configuration_hash = incoming_renderer_info_.configuration_hash,
    };
    return kPlutoStatusOk;
  }

  PlutoStatus confirm_handoff(bool accepted) {
    bool invalidation_failed = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (device_lost_) {
        return kPlutoStatusDeviceLost;
      }
      if (!handoff_core_seeded_ ||
          handoff_decision_ != HandoffDecision::kPending) {
        return kPlutoStatusAgain;
      }
      if (!accepted &&
          !glass_handoff_discard(handoff_lease_, config_.handoff_path)) {
        handoff_invalidation_failed_ = true;
        invalidation_failed = true;
      }
      handoff_decision_ =
          accepted ? HandoffDecision::kAccepted : HandoffDecision::kRejected;
      std::vector<std::uint8_t>().swap(incoming_renderer_payload_);
      incoming_renderer_info_ = {};
    }
    handoff_cv_.notify_all();
    engine_cv_.notify_all();
    if (invalidation_failed) {
      set_scan_identity_fault(
          "renderer rejection could not invalidate warm handoff");
      return kPlutoStatusDeviceLost;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus snapshot(PlutoSurface *out_surface) {
    if (out_surface == nullptr || out_surface->pixels == nullptr ||
        out_surface->width != kLogicalWidth ||
        out_surface->height != kLogicalHeight ||
        out_surface->format != kPlutoPixelFormatRgb565 ||
        out_surface->stride_bytes < kLogicalStrideBytes) {
      return kPlutoStatusInvalidArgument;
    }
    std::lock_guard<std::mutex> lock(snapshot_mutex_);
    if (frame_.size() != kLogicalFrameBytes) {
      return kPlutoStatusDeviceLost;
    }
    auto *out = const_cast<std::uint8_t *>(out_surface->pixels);
    for (int y = 0; y < kLogicalHeight; ++y) {
      std::memcpy(out + static_cast<std::size_t>(y) * out_surface->stride_bytes,
                  frame_.data() +
                      static_cast<std::size_t>(y) * kLogicalStrideBytes,
                  kLogicalStrideBytes);
    }
    return kPlutoStatusOk;
  }

  // TEST-ONLY (swtcon::debug_glass_for_testing): the engine thread services
  // the copy, so the engine-confined planes are never read cross-thread.
  bool debug_glass(std::vector<std::uint8_t> *out_levels, int *out_width,
                   int *out_height, int *out_stride) {
    if (out_levels == nullptr || out_width == nullptr ||
        out_height == nullptr || out_stride == nullptr) {
      return false;
    }
    std::unique_lock<std::mutex> lock(mutex_);
    if (stopping_ || !engine_thread_.joinable()) {
      return false;
    }
    GlassRequest request;
    request.out = out_levels;
    glass_request_ = &request;
    engine_cv_.notify_all();
    glass_cv_.wait(lock,
                   [this, &request] { return request.done || stopping_; });
    if (glass_request_ == &request) {
      glass_request_ = nullptr;
    }
    if (!request.done) {
      return false;
    }
    *out_width = config_.engine.width;
    *out_height = config_.engine.height;
    *out_stride = config_.engine.stride;
    return true;
  }

  // TEST-ONLY (swtcon::debug_dc_for_testing): DC-ledger per-tile snapshot,
  // serviced on the engine thread like debug_glass (the ledger is
  // engine-confined).
  bool debug_dc(std::vector<std::int32_t> *out_rescan,
                std::vector<std::uint16_t> *out_stress,
                std::uint32_t *out_tile_cols) {
    if (out_rescan == nullptr || out_stress == nullptr ||
        out_tile_cols == nullptr) {
      return false;
    }
    std::unique_lock<std::mutex> lock(mutex_);
    if (stopping_ || !engine_thread_.joinable()) {
      return false;
    }
    GlassRequest request;
    request.rescan = out_rescan;
    request.stress = out_stress;
    glass_request_ = &request;
    engine_cv_.notify_all();
    glass_cv_.wait(lock,
                   [this, &request] { return request.done || stopping_; });
    if (glass_request_ == &request) {
      glass_request_ = nullptr;
    }
    if (!request.done) {
      return false;
    }
    *out_tile_cols = request.tile_cols;
    return true;
  }

  bool debug_color_history(int x, int y, std::uint16_t *out_a,
                           std::uint16_t *out_b) const {
    if (!color_enabled_ || out_a == nullptr || out_b == nullptr) {
      return false;
    }
    const auto pixel = color_pipeline_.history().pixel(x, y);
    if (!pixel.has_value()) {
      return false;
    }
    *out_a = pixel->a;
    *out_b = pixel->b;
    return true;
  }

  PlutoStatus debug_stats(PlutoGallery3DrmDebugStats *out_stats) const {
    if (out_stats == nullptr || out_stats->struct_size < sizeof(std::size_t)) {
      return kPlutoStatusInvalidArgument;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const std::size_t size = out_stats->struct_size;
    PlutoGallery3DrmDebugStats stats = stats_snapshot_;
    stats.struct_size = size;
    stats.updates_completed = stat_updates_;
    stats.gc16_updates = stat_gc16_;
    stats.full_updates = stat_fulls_;
    // Always 0 since Stage 2: the presenter never self-schedules settles
    // (the renderer's SettlePlanner owns them). Field kept — append-only.
    stats.settle_updates = 0;
    const std::size_t samples =
        static_cast<std::size_t>(std::min<std::uint64_t>(
            color_preprocess_count_, color_preprocess_us_ring_.size()));
    if (samples > 0) {
      std::array<std::uint32_t, 256> sorted{};
      std::copy_n(color_preprocess_us_ring_.begin(), samples, sorted.begin());
      std::sort(sorted.begin(),
                sorted.begin() + static_cast<std::ptrdiff_t>(samples));
      stats.color_preprocess_p50_us = sorted[samples / 2];
      stats.color_preprocess_p95_us = sorted[(samples * 95) / 100];
      stats.color_preprocess_max_us = sorted[samples - 1];
    }
    stats.color_faults = stat_color_faults_.load(std::memory_order_relaxed);
    stats.color_reconciles =
        stat_color_reconciles_.load(std::memory_order_relaxed);
    stats.color_queue_peak = stat_color_queue_peak_;
    const std::size_t total_obligations =
        color_obligation_count_.load(std::memory_order_acquire);
    const std::size_t fast_obligations =
        color_fast_obligation_count_.load(std::memory_order_acquire);
    stats.color_fast_obligations = fast_obligations;
    stats.color_truth_obligations = total_obligations >= fast_obligations
                                        ? total_obligations - fast_obligations
                                        : 0;
    stats.color_fast_obligation_peak = stat_color_fast_obligation_peak_;
    stats.color_truth_obligation_peak = stat_color_truth_obligation_peak_;
    stats.color_fast_reserve_uses = stat_color_fast_reserve_uses_;
    stats.color_fast_reserve_declines = stat_color_fast_reserve_declines_;
    stats.color_pen_focus_updates = stat_color_pen_focus_updates_;
    stats.color_pen_focus_clears = stat_color_pen_focus_clears_;
    stats.color_pen_focus_truth_deferrals =
        stat_color_pen_focus_truth_deferrals_;
    stats.color_pen_focus_disjoint_bypasses =
        stat_color_pen_focus_disjoint_bypasses_;
    stats.color_pen_focus_deferred_current = 0;
    if (pen_focus_active_) {
      const std::uint64_t now_ns = steady_now_ns();
      for (const ColorAdmit &admit : color_lane_) {
        stats.color_pen_focus_deferred_current +=
            color_admit_overlaps_pen_focus_locked(admit) &&
                    admit.pen_focus_defer_until_ns > now_ns
                ? 1u
                : 0u;
      }
    }
    stats.color_pen_truth_input_rects = stat_pen_truth_input_rects_;
    stats.color_pen_truth_grouped_tiles = stat_pen_truth_grouped_tiles_;
    stats.color_pen_truth_masked_lanes = stat_pen_truth_masked_lanes_;
    stats.color_pen_truth_groups_per_request_max =
        stat_pen_truth_groups_per_request_max_;
    // This diagnostics ABI is append-only. Older callers intentionally pass
    // their smaller struct_size; copy only the prefix they know, while newer
    // callers retain any future tail beyond this implementation's version.
    std::memcpy(out_stats, &stats,
                std::min(size, sizeof(PlutoGallery3DrmDebugStats)));
    return kPlutoStatusOk;
  }

private:
  struct Config {
    bool dry_run = false;
    bool exact_color = false;
    // Dry-run engine pacing ONLY. The production scan period comes from
    // the ENUMERATED DRM mode (scan_period_ns overrides for tests).
    int flip_interval_ms = 12;
    std::string card_path = "/dev/dri/card0";
    swtcon::SwtconRails::Config rails;
    swtcon::SwtconTemperatureMonitor::Config temperature;
    swtcon::SwtconWaveform::Files waveform_files;
    // Per-pixel engine constants (every field carries its experiment tag
    // in pixel_engine.h): max_active_px (E13),
    // full_flash_band_frames (E10), early_cancel_enabled (E2, default OFF),
    // settle_force_identity (E3, default OFF), temp_hysteresis_c (E5),
    // DcLedgerConfig (E2).
    PixelEngineConfig engine;
    // `emission_mode` (E13 WC-write bench): row-stage default,
    // copy_phase_to_buffer-shaped shadow fallback kept available.
    EmissionMode emission_mode = EmissionMode::kRowStage;
    // `scan_period_ns`: 0 = derive from the enumerated mode (~85.01
    // Hz); test override.
    std::uint64_t scan_period_ns = 0;
    // `payload_ring_tiles` shape: AdmissionMailbox record capacity.
    std::size_t mailbox_capacity = 2048;
    // Large-admission lane depth (full-field flashes; each entry is a
    // whole-rect level copy the engine band-amortizes). Backpressure
    // knob, not a hot-path constant.
    std::size_t large_lane_max = 8;
    // Bounded immutable producer payloads waiting for engine-thread history
    // preparation. Full-screen payloads are compact raw bytes, never caller
    // surface pointers.
    std::size_t color_lane_max = 64;
    // Periodic engine stats log (device diagnosis from journal logs): one
    // line every stats_log_s seconds while the presenter is open; 0 = off.
    int stats_log_s = 10;
    // E1 mode-identity diagnostic (device experiment, camera-verified):
    // when > 0, after the cold clear a self-drive thread paints one
    // horizontal band per RAW .eink mode index to black, waits step_ms,
    // then erases each band to white with the SAME mode. A camera still
    // after each phase yields the definitive per-mode develop/erase map.
    // Never enable in normal operation.
    int mode_lab_step_ms = 0;
    // Warm glass handoff (include/pluto/glass_handoff.h): tmpfs path the
    // outgoing embedder dumps its settled glass plane to on clean close and
    // the incoming embedder seeds from, skipping the cold rail clear
    // on app switches. Empty = disabled ("handoff=0").
    std::string handoff_path = kGlassHandoffDefaultPath;
  };

  struct FrameBookkeeping {
    std::uint32_t remaining = 0;
    PlutoRefreshClass refresh_class = kPlutoRefreshUi;
    int mode = 2;
  };

  // Allocation-free completion table. At most one pending frame can exist
  // per mailbox record, so 4096 slots keep the fixed 2048-record mailbox at
  // <= 50% load. Tombstones preserve open-addressing probe chains.
  static constexpr std::size_t kPendingFrameCapacity = 4096;
  static_assert((kPendingFrameCapacity & (kPendingFrameCapacity - 1)) == 0);
  enum class PendingFrameState : std::uint8_t { kEmpty, kOccupied, kDeleted };
  struct PendingFrameSlot {
    std::uint64_t frame_id = 0;
    FrameBookkeeping bookkeeping{};
    PendingFrameState state = PendingFrameState::kEmpty;
  };

  static std::size_t pending_frame_hash(std::uint64_t frame_id) {
    frame_id ^= frame_id >> 30u;
    frame_id *= 0xbf58476d1ce4e5b9ULL;
    frame_id ^= frame_id >> 27u;
    frame_id *= 0x94d049bb133111ebULL;
    frame_id ^= frame_id >> 31u;
    return static_cast<std::size_t>(frame_id) & (kPendingFrameCapacity - 1);
  }

  void reset_pending_frames() {
    for (PendingFrameSlot &slot : pending_frames_) {
      slot = {};
    }
    pending_frame_count_ = 0;
  }

  PendingFrameSlot *find_pending_frame_slot(std::uint64_t frame_id) {
    const std::size_t start = pending_frame_hash(frame_id);
    for (std::size_t probe = 0; probe < kPendingFrameCapacity; ++probe) {
      PendingFrameSlot &slot =
          pending_frames_[(start + probe) & (kPendingFrameCapacity - 1)];
      if (slot.state == PendingFrameState::kEmpty) {
        return nullptr;
      }
      if (slot.state == PendingFrameState::kOccupied &&
          slot.frame_id == frame_id) {
        return &slot;
      }
    }
    return nullptr;
  }

  FrameBookkeeping *find_or_insert_pending_frame(std::uint64_t frame_id) {
    const std::size_t start = pending_frame_hash(frame_id);
    PendingFrameSlot *first_deleted = nullptr;
    for (std::size_t probe = 0; probe < kPendingFrameCapacity; ++probe) {
      PendingFrameSlot &slot =
          pending_frames_[(start + probe) & (kPendingFrameCapacity - 1)];
      if (slot.state == PendingFrameState::kOccupied) {
        if (slot.frame_id == frame_id) {
          return &slot.bookkeeping;
        }
        continue;
      }
      if (slot.state == PendingFrameState::kDeleted) {
        if (first_deleted == nullptr) {
          first_deleted = &slot;
        }
        continue;
      }
      PendingFrameSlot *target =
          first_deleted != nullptr ? first_deleted : &slot;
      target->frame_id = frame_id;
      target->bookkeeping = {};
      target->state = PendingFrameState::kOccupied;
      ++pending_frame_count_;
      return &target->bookkeeping;
    }
    if (first_deleted != nullptr) {
      first_deleted->frame_id = frame_id;
      first_deleted->bookkeeping = {};
      first_deleted->state = PendingFrameState::kOccupied;
      ++pending_frame_count_;
      return &first_deleted->bookkeeping;
    }
    return nullptr;
  }

  void erase_pending_frame(PendingFrameSlot *slot) {
    if (slot == nullptr || slot->state != PendingFrameState::kOccupied) {
      return;
    }
    slot->bookkeeping = {};
    slot->state = PendingFrameState::kDeleted;
    --pending_frame_count_;
  }

  struct LargeAdmit {
    PlutoRect rect{};
    int mode = 2;
    int temp_bin = 0;
    std::uint64_t engine_frame_id = 0;
    std::uint32_t admit_flags = 0;
    std::vector<std::uint8_t> levels;
  };

  struct AtomicPenFocusSlot {
    std::atomic<std::uint64_t> guard{0};
    std::atomic<std::int32_t> x{0};
    std::atomic<std::int32_t> y{0};
    std::atomic<std::int32_t> width{0};
    std::atomic<std::int32_t> height{0};
    std::atomic<std::uint32_t> flags{0};
    std::atomic<std::uint64_t> sequence{0};
  };

  struct PenFocusValue {
    PlutoRect rect{};
    std::uint32_t flags = 0;
    std::uint64_t sequence = 0;
    std::uint64_t ticket = 0;
  };

  // Fixed-size latest-wins mailbox. Production has one InkThread publisher;
  // spare slots also make renderer fallback/tests with concurrent publishers
  // coherent without a writer lock. Every payload word is atomic so TSan and
  // the reader can never observe a torn rectangle.
  static constexpr std::size_t kPenFocusMailboxCapacity = 64;

  struct ColorAdmit {
    std::shared_ptr<const XochitlColorPipeline::ImmutableOperation> payload;
    // ABI-facing engine id (user frame_id + 1). Safe Fast pieces use a
    // distinct presenter-internal id at PixelEngine::admit() so completion
    // order can be bound to the exact raw payload and coverage journal.
    std::uint64_t engine_frame_id = 0;
    std::uint64_t safe_fast_engine_id = 0;
    std::uint64_t fast_present_seq = 0;
    std::uint64_t fast_piece_seq = 0;
    std::uint32_t fast_piece_index = 0;
    std::uint32_t fast_piece_count = 0;
    std::uint64_t retry_cookie = 0;
    std::uint64_t retry_after_dependency_epoch = 0;
    std::uint64_t enqueued_ns = 0;
    // Armed only on this raw truth's first actual collision with active
    // proximity. Identical publications never renew it; genuine focus motion
    // extends it to one quiet window so a long Full cannot enter beneath a
    // continuously moving nib.
    std::uint64_t pen_focus_defer_until_ns = 0;
    std::uint64_t pen_focus_motion_generation = 0;
  };

  struct SafeFastPiece {
    std::uint64_t internal_engine_frame_id = 0;
    std::uint64_t seed_seq = 0;
    std::uint32_t index = 0;
    std::shared_ptr<const XochitlColorPipeline::ImmutableOperation> payload;
    std::shared_ptr<swtcon::FastCoverage> coverage;
    std::uint64_t last_drive_build_seq = 0;
    bool completion_arrived = false;
  };

  struct SafeFastFrame {
    std::uint64_t abi_engine_frame_id = 0;
    std::uint64_t present_seq = 0;
    std::uint32_t expected_pieces = 0;
    std::uint32_t admitted_pieces = 0;
    std::uint32_t completed_pieces = 0;
    std::uint64_t terminal_build_seq = 0;
    std::vector<SafeFastPiece> pieces;
  };

  struct MappedTokenFrame {
    swtcon::MappedOperationToken token = 0;
    std::uint64_t engine_frame_id = 0;
    std::uint64_t retry_cookie = 0;
    std::shared_ptr<const XochitlColorPipeline::ImmutableOperation> payload;
  };

  struct MappedTerminalFence {
    std::uint64_t build_seq = 0;
    std::vector<swtcon::MappedOperationToken> tokens;
  };

  struct DoubleScanEvent {
    std::uint32_t buffer_index = 0;
    std::uint64_t engine_seq = 0;
    std::uint32_t extra = 0;
  };

  // TEST-ONLY engine-state-snapshot handshake (guarded by mutex_): the
  // engine thread fills whichever outputs are non-null.
  struct GlassRequest {
    std::vector<std::uint8_t> *out = nullptr;     // settled glass levels
    std::vector<std::int32_t> *rescan = nullptr;  // DcLedger rescan_dc
    std::vector<std::uint16_t> *stress = nullptr; // DcLedger stress
    std::uint32_t tile_cols = 0;                  // filled by the engine
    bool done = false;
  };

  enum class HandoffDecision : std::uint8_t {
    kNone,
    kPending,
    kAccepted,
    kRejected,
  };

  struct HandoffCaptureRequest {
    GlassHandoffCoreState core;
    bool success = false;
    bool done = false;
  };

  const FixedColorHandoffProfile *select_color_handoff_profile() const {
    // Host dry-run and the explicitly injected TEST-ONLY DRM interface are
    // deterministic profile simulators on isolated paths. Production must
    // positively match both immutable kernel identities before this
    // hardcoded layout is selectable.
    const bool require_device_identity =
        handoff_backend_ == HandoffExecutionBackend::kProductionDrm;
    const std::string machine =
        require_device_identity
            ? read_small_identity_file("/sys/devices/soc0/machine")
            : std::string{};
    const std::string soc =
        require_device_identity
            ? read_small_identity_file("/sys/devices/soc0/soc_id")
            : std::string{};
    return find_color_handoff_profile(
        config_.engine.width, config_.engine.height, config_.engine.stride,
        config_.engine.tile_px, XochitlHistoryState::kStorageStride,
        XochitlHistoryState::kStorageRows, machine, soc,
        require_device_identity);
  }

  bool build_handoff_identity(GlassHandoffIdentity *out) const {
    if (out == nullptr || !engine_.configured() || !waveform_.loaded()) {
      return false;
    }
    GlassHandoffIdentity identity;
    identity.flags =
        color_enabled_ ? kGlassHandoffFlagExactColor : kGlassHandoffFlagNone;
    identity.width = static_cast<std::uint32_t>(config_.engine.width);
    identity.height = static_cast<std::uint32_t>(config_.engine.height);
    identity.pixel_format = static_cast<std::uint32_t>(kPlutoPixelFormatRgb565);
    identity.engine_stride = static_cast<std::uint32_t>(config_.engine.stride);
    identity.tile_px = config_.engine.tile_px;

    const FixedColorHandoffProfile *fixed_profile = nullptr;
    if (color_enabled_) {
      fixed_profile = select_color_handoff_profile();
      if (fixed_profile == nullptr) {
        return false;
      }
      identity.profile = fixed_profile->profile;
      identity.history_stride = fixed_profile->history_stride;
      identity.history_rows = fixed_profile->history_rows;
      identity.history_pixel_bytes = sizeof(XochitlHistoryState::HistoryPixel);
    } else {
      identity.profile = GlassHandoffProfile::kMonochrome;
    }

    identity.waveform_bytes = waveform_.eink_bytes().size();
    identity.waveform_hash = glass_handoff_crc64(waveform_.eink_bytes());
    if (identity.waveform_bytes == 0) {
      return false;
    }

    if (color_enabled_) {
      HandoffFingerprint ct33;
      ct33.add_u32(1); // canonical named-blob encoding revision
      for (const auto &[name, bytes] : waveform_.ct33_bytes()) {
        ct33.add_string(name);
        ct33.add_u64(bytes.size());
        ct33.add_bytes(bytes);
        identity.ct33_bytes += bytes.size();
      }
      identity.ct33_hash = ct33.value();
      if (identity.ct33_bytes == 0) {
        return false;
      }
    }

    // Canonical behavior fingerprint. This is deliberately exhaustive and
    // explicitly revisioned; any future drive/state semantic change bumps
    // the revision and fails closed even when its C++ layout happens to stay
    // source-compatible.
    constexpr std::uint32_t kPipelineIdentityRevision = 2;
    const PixelEngineConfig &engine = config_.engine;
    const swtcon::DcLedgerConfig &dc = engine.dc;
    HandoffFingerprint pipeline;
    pipeline.add_u32(kPipelineIdentityRevision);
    pipeline.add_u32(static_cast<std::uint32_t>(identity.profile));
    if (fixed_profile != nullptr) {
      pipeline.add_string(fixed_profile->machine);
      pipeline.add_string(fixed_profile->soc);
    }
    pipeline.add_u32(identity.flags);
    pipeline.add_u32(identity.width);
    pipeline.add_u32(identity.height);
    pipeline.add_u32(identity.pixel_format);
    pipeline.add_u32(identity.engine_stride);
    pipeline.add_u32(identity.tile_px);
    pipeline.add_u32(identity.history_stride);
    pipeline.add_u32(identity.history_rows);
    pipeline.add_u32(identity.history_pixel_bytes);
    pipeline.add_u8(static_cast<std::uint8_t>(handoff_backend_));
    pipeline.add_u64(period_ns());
    pipeline.add_string(config_.card_path);
    if (device_ != nullptr) {
      const swtcon::DrmModeInfo &mode = device_->mode();
      pipeline.add_u32(mode.clock);
      pipeline.add_u16(mode.hdisplay);
      pipeline.add_u16(mode.hsync_start);
      pipeline.add_u16(mode.hsync_end);
      pipeline.add_u16(mode.htotal);
      pipeline.add_u16(mode.hskew);
      pipeline.add_u16(mode.vdisplay);
      pipeline.add_u16(mode.vsync_start);
      pipeline.add_u16(mode.vsync_end);
      pipeline.add_u16(mode.vtotal);
      pipeline.add_u16(mode.vscan);
      pipeline.add_u32(mode.vrefresh);
      pipeline.add_u32(mode.flags);
      pipeline.add_u32(mode.type);
      const char *mode_name_end =
          std::find(mode.name, mode.name + sizeof(mode.name), '\0');
      pipeline.add_u64(static_cast<std::uint64_t>(mode_name_end - mode.name));
      pipeline.add_bytes(std::span<const std::uint8_t>(
          reinterpret_cast<const std::uint8_t *>(mode.name),
          static_cast<std::size_t>(mode_name_end - mode.name)));
    }
    pipeline.add_u8(config_.rails.enable ? 1u : 0u);
    pipeline.add_u8(config_.rails.dry_run ? 1u : 0u);
    pipeline.add_string(config_.rails.panel_base);
    pipeline.add_string(config_.rails.regulator_base);
    pipeline.add_string(config_.rails.vcom_value);
    pipeline.add_string(config_.rails.vpdd_value);
    pipeline.add_string(config_.temperature.hwmon_root);
    pipeline.add_string(config_.temperature.sensor_path);
    pipeline.add_string(config_.temperature.sensor_name);
    pipeline.add_u64(config_.temperature.sensor_name_preference.size());
    for (const std::string &preference :
         config_.temperature.sensor_name_preference) {
      pipeline.add_string(preference);
    }
    pipeline.add_u64(
        static_cast<std::uint64_t>(config_.temperature.poll_interval.count()));
    pipeline.add_u32(
        static_cast<std::uint32_t>(config_.temperature.default_milli_celsius));
    pipeline.add_string(temperature_.selected_path());
    pipeline.add_u32(engine.max_active_px);
    pipeline.add_u32(engine.full_flash_band_frames);
    pipeline.add_u8(engine.early_cancel_enabled ? 1u : 0u);
    pipeline.add_u16(engine.rail_mode_mask);
    pipeline.add_u8(engine.stress_balanced_mode);
    pipeline.add_u8(engine.promote_regional_stress ? 1u : 0u);
    pipeline.add_u8(engine.settle_force_identity ? 1u : 0u);
    pipeline.add_u8(engine.initial_prev_level);
    pipeline.add_u32(std::bit_cast<std::uint32_t>(engine.temp_hysteresis_c));
    pipeline.add_u8(engine.force_scalar_sweep ? 1u : 0u);
    pipeline.add_u8(static_cast<std::uint8_t>(dc.dc_pixel_cap));
    for (const std::int8_t impulse : dc.impulse_map) {
      pipeline.add_u8(static_cast<std::uint8_t>(impulse));
    }
    pipeline.add_u8(dc.trust_vendor_balance ? 1u : 0u);
    pipeline.add_u16(dc.balanced_mode_mask);
    pipeline.add_u16(dc.k_cancel);
    pipeline.add_u16(dc.k_pause);
    pipeline.add_u16(dc.k_dscan);
    pipeline.add_u16(dc.dc_stress_force);
    pipeline.add_u32(static_cast<std::uint32_t>(config_.emission_mode));
    identity.pipeline_hash = pipeline.value();
    *out = identity;
    return true;
  }

  void bind_engine_callbacks() {
    engine_.set_completion_callback([this](std::uint64_t engine_frame_id) {
      // Engine thread; collected locally and flushed after the step.
      engine_completions_.push_back(engine_frame_id);
    });
    engine_.set_mapped_event_callback([this](const swtcon::MappedEvent &event) {
      mapped_events_.push_back(event);
    });
  }

  bool reset_engine_to_cold_state() {
    color_pipeline_.invalidate_history();
    if (!engine_.configure(&waveform_.table(), config_.engine)) {
      return false;
    }
    bind_engine_callbacks();
    engine_.set_temperature(temperature_.current_celsius());
    admission_bin_selector_ =
        swtcon::TemperatureBinSelector(config_.engine.temp_hysteresis_c);
    (void)admission_bin_selector_.select(waveform_.table().temp_thresholds(),
                                         temperature_.current_celsius());
    summary_store_.configure(engine_.dc_ledger().tile_count(),
                             kActivePhaseSlots);
    return true;
  }

  bool seed_handoff_core(GlassHandoffBundle *bundle) {
    if (bundle == nullptr) {
      return false;
    }
    swtcon::PixelEngineHandoffState state;
    state.config = config_.engine;
    state.temperature_bin = bundle->core.engine_temperature_bin;
    state.dc.width = config_.engine.width;
    state.dc.height = config_.engine.height;
    state.dc.stride = config_.engine.stride;
    state.dc.tile_px = config_.engine.tile_px;
    state.dc.tile_cols = engine_.dc_ledger().tile_cols();
    state.dc.tile_rows = engine_.dc_ledger().tile_rows();
    state.dc.config = config_.engine.dc;
    state.dc.dc = std::move(bundle->core.engine_dc);
    state.dc.stress = std::move(bundle->core.engine_stress);
    state.dc.rescan_dc = std::move(bundle->core.engine_rescan);

    bool imported = false;
    if (color_enabled_) {
      const swtcon::ExactColorAView history_view{
          bundle->core.xochitl_history_ab,
          static_cast<std::size_t>(bundle->identity.history_stride),
          static_cast<std::size_t>(bundle->identity.history_rows)};
      imported = color_pipeline_.history().seed_full_plane_interleaved(
                     bundle->core.xochitl_history_ab) &&
                 engine_.import_handoff_state(state, history_view);
    } else {
      state.settled_levels = std::move(bundle->core.engine_levels);
      imported = engine_.import_handoff_state(state);
    }
    if (!imported || !admission_bin_selector_.seed_held_bin(
                         bundle->core.admission_temperature_bin,
                         waveform_.table().temp_thresholds().size())) {
      (void)reset_engine_to_cold_state();
      return false;
    }
    return true;
  }

  PlutoStatus parse_options(const char *options) {
    const std::string dry_run = option_value(options, "dry_run");
    if (!dry_run.empty() && !parse_bool_option(dry_run, &config_.dry_run)) {
      return kPlutoStatusInvalidArgument;
    }
    const std::string exact_color = option_value(options, "exact_color");
    if (!exact_color.empty() &&
        !parse_bool_option(exact_color, &config_.exact_color)) {
      return kPlutoStatusInvalidArgument;
    }
    const std::string card = option_value(options, "card");
    if (!card.empty()) {
      config_.card_path = card;
    }
    const std::string flip_interval = option_value(options, "flip_interval_ms");
    if (!flip_interval.empty()) {
      long long value = 0;
      if (!parse_int_option(flip_interval, &value) || value < 0 ||
          value > std::numeric_limits<int>::max()) {
        return kPlutoStatusInvalidArgument;
      }
      config_.flip_interval_ms = static_cast<int>(value);
    }

    const std::string stats_log = option_value(options, "stats_log_s");
    if (!stats_log.empty()) {
      long long value = 0;
      if (!parse_int_option(stats_log, &value) || value < 0 || value > 86400) {
        return kPlutoStatusInvalidArgument;
      }
      config_.stats_log_s = static_cast<int>(value);
    }

    const std::string mode_lab = option_value(options, "mode_lab");
    if (!mode_lab.empty()) {
      long long value = 0;
      if (!parse_int_option(mode_lab, &value) || value < 0 || value > 60000) {
        return kPlutoStatusInvalidArgument;
      }
      config_.mode_lab_step_ms = static_cast<int>(value);
    }

    const std::string handoff = option_value(options, "handoff");
    if (!handoff.empty()) {
      config_.handoff_path =
          (handoff == "0" || handoff == "off") ? std::string() : handoff;
    }

    const std::string enable_rails = option_value(options, "enable_rails");
    if (!enable_rails.empty() &&
        !parse_bool_option(enable_rails, &config_.rails.enable)) {
      return kPlutoStatusInvalidArgument;
    }
    const std::string rails_dry_run = option_value(options, "rails_dry_run");
    if (!rails_dry_run.empty() &&
        !parse_bool_option(rails_dry_run, &config_.rails.dry_run)) {
      return kPlutoStatusInvalidArgument;
    }
    const std::string panel_base = option_value(options, "panel_base");
    if (!panel_base.empty()) {
      config_.rails.panel_base = panel_base;
    }
    const std::string regulator_base = option_value(options, "regulator_base");
    if (!regulator_base.empty()) {
      config_.rails.regulator_base = regulator_base;
    }
    config_.rails.vcom_value = option_value(options, "vcom");
    config_.rails.vpdd_value = option_value(options, "vpdd");

    const std::string hwmon = option_value(options, "hwmon");
    if (!hwmon.empty()) {
      config_.temperature.hwmon_root = hwmon;
    }
    const std::string waveform = option_value(options, "waveform");
    const std::string eink = option_value(options, "eink");
    config_.waveform_files.eink_path = !waveform.empty() ? waveform : eink;
    const std::string ct33_std = option_value(options, "ct33_std");
    const std::string ct33_best = option_value(options, "ct33_best");
    const std::string ct33_pen = option_value(options, "ct33_pen");
    const std::string ct33_fast = option_value(options, "ct33_fast");
    if (!ct33_std.empty()) {
      config_.waveform_files.ct33_std_path = ct33_std;
    }
    if (!ct33_best.empty()) {
      config_.waveform_files.ct33_best_path = ct33_best;
    }
    if (!ct33_pen.empty()) {
      config_.waveform_files.ct33_pen_path = ct33_pen;
    }
    if (!ct33_fast.empty()) {
      config_.waveform_files.ct33_fast_path = ct33_fast;
    }

    // Engine constants exposed through the option surface.
    const std::string max_active_px = option_value(options, "max_active_px");
    if (!max_active_px.empty()) {
      long long value = 0;
      if (!parse_int_option(max_active_px, &value) || value <= 0 ||
          value > std::numeric_limits<std::int32_t>::max()) {
        return kPlutoStatusInvalidArgument;
      }
      config_.engine.max_active_px = static_cast<std::uint32_t>(value);
    }
    const std::string band_frames =
        option_value(options, "full_flash_band_frames");
    if (!band_frames.empty()) {
      long long value = 0;
      if (!parse_int_option(band_frames, &value) || value <= 0 || value > 16) {
        return kPlutoStatusInvalidArgument;
      }
      config_.engine.full_flash_band_frames = static_cast<std::uint32_t>(value);
    }
    const std::string early_cancel = option_value(options, "early_cancel");
    if (!early_cancel.empty() &&
        !parse_bool_option(early_cancel,
                           &config_.engine.early_cancel_enabled)) {
      return kPlutoStatusInvalidArgument;
    }
    const std::string settle_force_identity =
        option_value(options, "settle_force_identity");
    if (!settle_force_identity.empty() &&
        !parse_bool_option(settle_force_identity,
                           &config_.engine.settle_force_identity)) {
      return kPlutoStatusInvalidArgument;
    }
    const std::string emission_mode = option_value(options, "emission_mode");
    if (!emission_mode.empty()) {
      if (emission_mode == "row_stage") {
        config_.emission_mode = EmissionMode::kRowStage;
      } else if (emission_mode == "shadow_copy") {
        config_.emission_mode = EmissionMode::kShadowCopy;
      } else {
        return kPlutoStatusInvalidArgument;
      }
    }
    const std::string scan_period = option_value(options, "scan_period_ns");
    if (!scan_period.empty()) {
      long long value = 0;
      if (!parse_int_option(scan_period, &value) || value < 0) {
        return kPlutoStatusInvalidArgument;
      }
      config_.scan_period_ns = static_cast<std::uint64_t>(value);
    }

    // Retired keys (option-surface migration rule): the old
    // record-playback drive core died with the per-pixel engine. Warn-and-
    // ignore so proven device recipes keep working and never silently
    // change meaning. settle_delay_ms/full_refresh_every retired at Stage 2
    // (SettlePlanner is the single settle authority); the du_*/dither
    // emergency-DU surface retired at the engine stage (the engine drives
    // exclusively from decoded .eink LUTs).
    for (const char *retired :
         {"settle_delay_ms", "full_refresh_every", "du_mode", "du_white",
          "du_black", "dither", "du_frames", "du_frames_fast", "du_frames_ui",
          "du_frames_text", "du_frames_full"}) {
      if (!option_value(options, retired).empty()) {
        std::fprintf(stderr,
                     "swtcon: option '%s' is retired and ignored (per-pixel "
                     "engine drive core)\n",
                     retired);
      }
    }
    return kPlutoStatusOk;
  }

  PlutoStatus validate_request(const PlutoPresentRequest &request) const {
    const PlutoSurface &surface = request.surface;
    if (surface.pixels == nullptr || surface.width != kLogicalWidth ||
        surface.height != kLogicalHeight ||
        surface.format != kPlutoPixelFormatRgb565 ||
        surface.stride_bytes < kLogicalStrideBytes ||
        request.damage == nullptr || request.damage_count == 0) {
      return kPlutoStatusInvalidArgument;
    }
    for (std::size_t i = 0; i < request.damage_count; ++i) {
      if (!rect_valid(request.damage[i])) {
        return kPlutoStatusInvalidArgument;
      }
    }
    return kPlutoStatusOk;
  }

  // Waveform mode for a refresh class: the proven map (Fast/Ui->7, Text->1,
  // Full->2; E1 refines identities) with a GC16 (mode 2) fallback when the
  // loaded table lacks the class mode. -1 = nothing drivable.
  int mode_for_class(PlutoRefreshClass refresh_class, int bin) const {
    const WaveformTable &table = waveform_.table();
    if (color_enabled_) {
      int mode = -1;
      switch (refresh_class) {
      case kPlutoRefreshFast:
        mode = 7;
        break;
      case kPlutoRefreshUi:
        mode = 5;
        break;
      case kPlutoRefreshText:
        mode = 1;
        break;
      case kPlutoRefreshFull:
        mode = 6;
        break;
      }
      return mode >= 0 && table.phase_count(mode, bin) > 0 ? mode : -1;
    }
    const int preferred = swtcon::waveform_mode_index(
        swtcon::update_mode_from_refresh_class(refresh_class));
    for (const int mode : {preferred, 2}) {
      if (table.phase_count(mode, bin) > 0) {
        return mode;
      }
    }
    return -1;
  }

  static XochitlHistoryState::Mode
  color_mode_for_class(PlutoRefreshClass refresh_class) {
    switch (refresh_class) {
    case kPlutoRefreshFast:
      return XochitlHistoryState::Mode::kFast;
    case kPlutoRefreshUi:
      return XochitlHistoryState::Mode::kUi;
    case kPlutoRefreshText:
      return XochitlHistoryState::Mode::kText;
    case kPlutoRefreshFull:
      return XochitlHistoryState::Mode::kFull;
    }
    return XochitlHistoryState::Mode::kFull;
  }

  int latency_ms_for_class(PlutoRefreshClass refresh_class,
                           float celsius) const {
    const WaveformTable &table = waveform_.table();
    const int bin = table.temp_bin(celsius);
    const int mode = mode_for_class(refresh_class, bin);
    const int phases = mode >= 0 ? table.phase_count(mode, bin) : 0;
    if (phases <= 0) {
      return 1000; // undrivable class: pessimistic placeholder
    }
    const std::uint64_t period = period_ns();
    return static_cast<int>(std::max<std::uint64_t>(
        1, (static_cast<std::uint64_t>(phases) * period + 999999) / 1000000));
  }

  std::uint64_t period_ns() const {
    if (!config_.dry_run && scan_loop_.configured()) {
      return scan_loop_.period_ns();
    }
    if (config_.scan_period_ns != 0) {
      return config_.scan_period_ns;
    }
    if (config_.flip_interval_ms > 0) {
      return static_cast<std::uint64_t>(config_.flip_interval_ms) * 1000000ull;
    }
    return 11764706ull; // round(1e9 / 85)
  }

  static std::size_t count_tile_pieces(const PlutoRect &rect,
                                       std::uint32_t tile_px) {
    const std::int32_t tile = static_cast<std::int32_t>(tile_px);
    const std::int32_t cols =
        (rect.x + rect.width - 1) / tile - rect.x / tile + 1;
    const std::int32_t rows =
        (rect.y + rect.height - 1) / tile - rect.y / tile + 1;
    return static_cast<std::size_t>(cols) * static_cast<std::size_t>(rows);
  }

  int select_admission_bin(float temperature_celsius) {
    return admission_bin_selector_.select(waveform_.table().temp_thresholds(),
                                          temperature_celsius);
  }

  // Legal-target map for the exact temperature record pinned into the
  // admission. Identity fallback when maps are absent (open() not run /
  // degenerate table).
  const std::uint8_t *legal_map_for(int mode, int requested_bin) const {
    static constexpr std::array<std::uint8_t, 32> kIdentity = [] {
      std::array<std::uint8_t, 32> m{};
      for (int i = 0; i < 32; ++i) {
        m[i] = static_cast<std::uint8_t>(i);
      }
      return m;
    }();
    const int ntemp = std::max(1, legal_map_ntemp_);
    const int bin = std::clamp(requested_bin, 0, ntemp - 1);
    const std::size_t index =
        static_cast<std::size_t>(mode) * static_cast<std::size_t>(ntemp) +
        static_cast<std::size_t>(bin);
    if (mode < 0 || index >= legal_target_maps_.size()) {
      return kIdentity.data();
    }
    return legal_target_maps_[index].data();
  }

  // RGB565 -> 5-bit level conversion for one rect (tight rect.width pitch),
  // legalized onto the mode's drivable-target lattice. Runs per admission on
  // the scheduler thread (up to full-panel on the large lane): dispatches to
  // the swtcon_waveform kernel (NEON on aarch64, byte-identical to the
  // scalar reference by exhaustive golden).
  static void convert_levels(const PlutoSurface &surface, const PlutoRect &rect,
                             const std::uint8_t *legal_targets,
                             std::uint8_t *out) {
    const std::uint8_t *src =
        surface.pixels +
        static_cast<std::size_t>(rect.y) * surface.stride_bytes +
        static_cast<std::size_t>(rect.x) * kRgb565BytesPerPixel;
    swtcon::convert_rgb565_levels(src, surface.stride_bytes, rect.width,
                                  rect.height, legal_targets, out);
  }

  void copy_damage_into_frame(const PlutoPresentRequest &request,
                              std::uint8_t *out_frame) {
    for (std::size_t i = 0; i < request.damage_count; ++i) {
      const PlutoRect &rect = request.damage[i];
      const std::size_t row_bytes =
          static_cast<std::size_t>(rect.width) * kRgb565BytesPerPixel;
      for (int y = 0; y < rect.height; ++y) {
        const std::size_t src_offset =
            static_cast<std::size_t>(rect.y + y) *
                request.surface.stride_bytes +
            static_cast<std::size_t>(rect.x) * kRgb565BytesPerPixel;
        const std::size_t dst_offset =
            static_cast<std::size_t>(rect.y + y) * kLogicalStrideBytes +
            static_cast<std::size_t>(rect.x) * kRgb565BytesPerPixel;
        std::memcpy(out_frame + dst_offset, request.surface.pixels + src_offset,
                    row_bytes);
      }
    }
  }

  // The completion ABI is C-shaped, but tests and embedders are still C++
  // callers. Never let an accidental exception terminate the presenter engine
  // thread or strand wait_idle() behind the delivery fence.
  void invoke_completion_callback_noexcept(std::uint64_t frame_id) noexcept {
    if (callback_ == nullptr) {
      return;
    }
    try {
      callback_(frame_id, callback_user_data_);
    } catch (...) {
      std::fprintf(stderr, "swtcon: completion callback threw for frame %llu\n",
                   static_cast<unsigned long long>(frame_id));
    }
  }

  // Called only after completion_callbacks_pending_ was incremented while
  // holding mutex_. The callback itself stays outside mutex_: the presenter ABI
  // permits an enqueue-only callback to run synchronously, and taking the
  // presenter lock across it would turn that harmless handoff into a deadlock.
  // The post-callback decrement is the wait_idle fence: idle is not observable
  // until the completion has actually been delivered (or safely caught).
  void deliver_fenced_completion(std::uint64_t frame_id) noexcept {
    invoke_completion_callback_noexcept(frame_id);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      assert(completion_callbacks_pending_ > 0);
      --completion_callbacks_pending_;
    }
    idle_cv_.notify_all();
  }

  // Accepted no-op presents (mode laboratory / unavailable sparkle waveform)
  // complete on the producer stack rather than through PixelEngine. Fence them
  // too so a concurrent wait_idle observes one completion contract, regardless
  // of which internal path supplied it. With no callback there is nothing to
  // deliver and present() itself is the completion boundary.
  void deliver_immediate_completion(std::uint64_t frame_id) noexcept {
    if (callback_ == nullptr) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      ++completion_callbacks_pending_;
    }
    deliver_fenced_completion(frame_id);
  }

  // A piece that could not be posted/admitted still owes its completion
  // decrement, or wait_idle would hang on a frame the engine never saw.
  void settle_failed_pieces(std::uint64_t frame_id, std::size_t count) {
    // Content is LOST for these pieces — dropped must stay 0 in the log.
    stat_dropped_pieces_.fetch_add(count, std::memory_order_relaxed);
    bool completed = false;
    bool deliver_callback = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      PendingFrameSlot *slot = find_pending_frame_slot(frame_id);
      if (slot == nullptr) {
        return;
      }
      const std::uint32_t drop = static_cast<std::uint32_t>(
          std::min<std::size_t>(count, slot->bookkeeping.remaining));
      slot->bookkeeping.remaining -= drop;
      if (slot->bookkeeping.remaining == 0) {
        erase_pending_frame(slot);
        completed = true; // degenerate: every piece failed; complete the frame
        if (callback_ != nullptr) {
          ++completion_callbacks_pending_;
          deliver_callback = true;
        }
      }
    }
    if (deliver_callback) {
      deliver_fenced_completion(frame_id);
    } else if (completed) {
      // Callback-null presenters still need to wake wait_idle after the last
      // defensively-settled piece retires.
      idle_cv_.notify_all();
    }
  }

  // ---- engine thread ------------------------------------------------------

  bool capture_handoff_core_on_engine_thread(GlassHandoffCoreState *out) {
    if (out == nullptr || !engine_.handoff_safe() || engine_busy() ||
        pending_pauses_.load(std::memory_order_acquire) != 0 ||
        stat_dropped_pieces_.load(std::memory_order_acquire) != 0 ||
        stat_color_faults_.load(std::memory_order_acquire) != 0 ||
        (color_enabled_ &&
         (!color_pipeline_.history().valid() ||
          color_pipeline_.history().outstanding_count() != 0)) ||
        !mapped_events_.empty() || !mapped_token_frames_.empty() ||
        !mapped_terminal_fences_.empty() || !safe_fast_frames_.empty() ||
        !reserved_safe_fast_engine_ids_.empty() ||
        !engine_completions_.empty() || !fired_frames_.empty()) {
      std::fprintf(
          stderr,
          "swtcon: warm handoff core audit failed engine_safe=%d busy=%d "
          "pauses=%u drops=%llu faults=%llu history_outstanding=%zu "
          "mapped=%zu/%zu/%zu safe_fast=%zu/%zu completions=%zu/%zu\n",
          engine_.handoff_safe() ? 1 : 0, engine_busy() ? 1 : 0,
          pending_pauses_.load(std::memory_order_acquire),
          static_cast<unsigned long long>(
              stat_dropped_pieces_.load(std::memory_order_acquire)),
          static_cast<unsigned long long>(
              stat_color_faults_.load(std::memory_order_acquire)),
          color_enabled_ ? color_pipeline_.history().outstanding_count() : 0,
          mapped_events_.size(), mapped_token_frames_.size(),
          mapped_terminal_fences_.size(), safe_fast_frames_.size(),
          reserved_safe_fast_engine_ids_.size(), engine_completions_.size(),
          fired_frames_.size());
      return false;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (pending_frame_count_ != 0 || !large_lane_.empty() ||
          !color_lane_.empty() || mailbox_.size_approx() != 0 ||
          completion_callbacks_pending_ != 0 || !double_scan_events_.empty() ||
          !scan_feedback_events_.empty() || ticks_pending_ != 0 ||
          admissions_signal_ || pen_focus_active_ ||
          pen_focus_mailbox_published_.load(std::memory_order_acquire) !=
              applied_pen_focus_ticket_ ||
          pen_focus_wake_.load(std::memory_order_acquire) || device_lost_) {
        return false;
      }
    }

    GlassHandoffCoreState captured;
    swtcon::PixelEngineHandoffState engine_state;
    bool exported = false;
    if (color_enabled_) {
      exported = color_pipeline_.history().export_full_plane_interleaved(
          &captured.xochitl_history_ab);
      if (exported) {
        const swtcon::ExactColorAView history_view{
            captured.xochitl_history_ab,
            static_cast<std::size_t>(XochitlHistoryState::kStorageStride),
            static_cast<std::size_t>(XochitlHistoryState::kStorageRows)};
        exported = engine_.export_handoff_state(history_view, &engine_state);
      }
    } else {
      exported = engine_.export_handoff_state(&engine_state);
    }
    if (!exported) {
      std::fprintf(stderr,
                   "swtcon: warm handoff core export rejected settled-state "
                   "invariants\n");
      return false;
    }
    captured.engine_temperature_bin = engine_state.temperature_bin;
    captured.admission_temperature_bin = admission_bin_selector_.held_bin();
    captured.engine_levels = std::move(engine_state.settled_levels);
    captured.engine_dc = std::move(engine_state.dc.dc);
    captured.engine_stress = std::move(engine_state.dc.stress);
    captured.engine_rescan = std::move(engine_state.dc.rescan_dc);
    *out = std::move(captured);
    return true;
  }

  void service_handoff_capture_request() {
    std::shared_ptr<HandoffCaptureRequest> request;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      request = handoff_capture_request_;
    }
    if (request == nullptr) {
      return;
    }
    const bool success = capture_handoff_core_on_engine_thread(&request->core);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (handoff_capture_request_ == request) {
        request->success = success;
        request->done = true;
        handoff_capture_request_.reset();
      }
    }
    handoff_cv_.notify_all();
  }

  void engine_thread_main() {
    set_thread_name("swtcon-engine");
    if (!config_.dry_run) {
      set_engine_thread_policy();
    }
    bool handoff_accepted = false;
    bool handoff_timed_out = false;
    if (handoff_core_seeded_) {
      std::unique_lock<std::mutex> lock(mutex_);
      const bool decided =
          handoff_cv_.wait_for(lock, std::chrono::seconds(2), [this] {
            return stopping_ || handoff_decision_ != HandoffDecision::kPending;
          });
      if (stopping_) {
        return;
      }
      handoff_timed_out = !decided;
      if (handoff_timed_out) {
        handoff_decision_ = HandoffDecision::kRejected;
      }
      handoff_accepted = handoff_decision_ == HandoffDecision::kAccepted;
    }
    if (handoff_accepted) {
      // The renderer and presenter seeded the same fully validated bundle.
      // Glass already matches, so first content is an ordinary exact diff.
      warm_handoff_accepted_.store(true, std::memory_order_release);
      std::fprintf(stderr,
                   "swtcon: warm handoff accepted; cold_clear=skip t_ns=%llu\n",
                   static_cast<unsigned long long>(steady_now_ns()));
      complete_cold_clear();
    } else {
      if (handoff_core_seeded_) {
        if (handoff_timed_out) {
          std::fprintf(stderr,
                       "swtcon: warm handoff renderer confirmation timed out; "
                       "cold_clear=start\n");
        }
        if (handoff_invalidation_failed_ ||
            !glass_handoff_discard(handoff_lease_, config_.handoff_path)) {
          set_scan_identity_fault(
              "warm handoff could not be invalidated before cold clear");
          return;
        }
        handoff_unlinked_ = true;
        incoming_handoff_claim_ = {};
        if (!reset_engine_to_cold_state()) {
          set_scan_identity_fault("failed to restore cold engine state");
          return;
        }
      }
      std::fprintf(stderr, "swtcon: cold_clear=start t_ns=%llu\n",
                   static_cast<unsigned long long>(steady_now_ns()));
      admit_cold_clear();
    }
    publish_engine_state();

    auto dry_run_deadline = std::chrono::steady_clock::now();
    for (;;) {
      bool tick = false;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        if (config_.dry_run) {
          // Self-paced ticks: every loop iteration is one virtual scan
          // frame while the engine is busy; block for admissions when idle.
          if (!engine_busy() && !admissions_signal_ && !stopping_ &&
              glass_request_ == nullptr && scan_feedback_events_.empty() &&
              handoff_capture_request_ == nullptr &&
              !pen_focus_wake_.load(std::memory_order_acquire)) {
            const auto wake_predicate = [this] {
              return stopping_ || admissions_signal_ ||
                     pen_focus_wake_.load(std::memory_order_acquire) ||
                     glass_request_ != nullptr ||
                     handoff_capture_request_ != nullptr ||
                     !scan_feedback_events_.empty();
            };
            const std::uint64_t focus_deadline_ns =
                earliest_pen_focus_deadline_locked(steady_now_ns());
            if (focus_deadline_ns == 0) {
              engine_cv_.wait(lock, wake_predicate);
            } else {
              engine_cv_.wait_until(
                  lock,
                  std::chrono::steady_clock::time_point(
                      std::chrono::nanoseconds(focus_deadline_ns)),
                  wake_predicate);
            }
          }
          tick = true;
        } else {
          const auto wake_predicate = [this] {
            return stopping_ || ticks_pending_ > 0 || admissions_signal_ ||
                   pen_focus_wake_.load(std::memory_order_acquire) ||
                   glass_request_ != nullptr ||
                   handoff_capture_request_ != nullptr ||
                   !scan_feedback_events_.empty();
          };
          auto wake_deadline =
              std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
          const std::uint64_t focus_deadline_ns =
              earliest_pen_focus_deadline_locked(steady_now_ns());
          if (focus_deadline_ns != 0) {
            wake_deadline =
                std::min(wake_deadline,
                         std::chrono::steady_clock::time_point(
                             std::chrono::nanoseconds(focus_deadline_ns)));
          }
          engine_cv_.wait_until(lock, wake_deadline, wake_predicate);
          tick = ticks_pending_ > 0;
          // Coalesce: each missed tick already flipped HOLD at the scan (a
          // counted pause); building more than one frame per wake would
          // outrun the 1-deep pipeline and drop published planes.
          ticks_pending_ = 0;
        }
        if (stopping_) {
          return;
        }
        pen_focus_wake_.store(false, std::memory_order_release);
        apply_latest_pen_focus_locked();
        // TEST-ONLY state snapshot: copied here, on the engine thread, so
        // the engine-confined planes/ledger are never read cross-thread.
        if (glass_request_ != nullptr) {
          if (glass_request_->out != nullptr) {
            const std::size_t plane =
                static_cast<std::size_t>(config_.engine.stride) *
                static_cast<std::size_t>(config_.engine.height);
            glass_request_->out->assign(engine_.prev_plane(),
                                        engine_.prev_plane() + plane);
          }
          const auto &dc = engine_.dc_ledger();
          glass_request_->tile_cols = dc.tile_cols();
          if (glass_request_->rescan != nullptr) {
            glass_request_->rescan->resize(dc.tile_count());
            for (std::size_t tile = 0; tile < dc.tile_count(); ++tile) {
              (*glass_request_->rescan)[tile] = dc.rescan_dc(tile);
            }
          }
          if (glass_request_->stress != nullptr) {
            glass_request_->stress->resize(dc.tile_count());
            for (std::size_t tile = 0; tile < dc.tile_count(); ++tile) {
              (*glass_request_->stress)[tile] = dc.stress(tile);
            }
          }
          glass_request_->done = true;
          glass_request_ = nullptr;
          glass_cv_.notify_all();
        }
        admissions_signal_ = false;
        double_scan_scratch_.clear();
        double_scan_scratch_.swap(double_scan_events_);
        scan_feedback_scratch_.clear();
        scan_feedback_scratch_.swap(scan_feedback_events_);
      }

      // Deferred scan-thread notifications (engine-confined state).
      std::uint32_t pauses =
          pending_pauses_.exchange(0, std::memory_order_acq_rel);
      while (pauses-- > 0) {
        engine_.pause();
      }
      if (!double_scan_scratch_.empty()) {
        // Bounded drain: coalesce by slot. The recharge is LINEAR in the
        // extra-scan count and slot_seq is constant during this drain (the
        // engine only builds after it), so per-slot summing is exactly
        // equivalent to per-event processing while capping the recharge
        // work at kActivePhaseSlots O(tile_count) charges per wake — a
        // queue backlog can never starve builds.
        std::array<std::uint64_t, kActivePhaseSlots> extras{};
        for (const DoubleScanEvent &event : double_scan_scratch_) {
          if (event.engine_seq == 0 ||
              event.buffer_index >= kActivePhaseSlots || event.extra == 0) {
            continue; // HOLD is impulse-free (the scan already exempts it)
          }
          if (emitter_.slot_seq(event.buffer_index) != event.engine_seq) {
            continue; // slot rebuilt since; bytes are no longer that plane
          }
          extras[event.buffer_index] += event.extra;
        }
        for (std::size_t slot = 0; slot < kActivePhaseSlots; ++slot) {
          if (extras[slot] != 0) {
            recharge_double_scan(slot, extras[slot]);
          }
        }
      }

      // TemperatureBinSelector wiring: every admission's bin lookup
      // goes through the engine's sticky selector; active tiles keep their
      // pinned bin for the whole sequence.
      engine_.set_temperature(temperature_.current_celsius());

      process_scan_feedback();
      // Scan feedback may confirm and erase a mapped token inside PixelEngine.
      // Reconcile the matching presenter token record before admitting a
      // queued overlapping Fast; otherwise that Fast observes a stale token
      // and mistakes the legitimate same-loop confirmation for corruption.
      process_mapped_events();
      double_scan_scratch_.clear();
      scan_feedback_scratch_.clear();
      service_handoff_capture_request();

      bool admitted = false;
      if (cold_clear_done_.load(std::memory_order_acquire)) {
        admitted =
            color_enabled_ ? drain_color_admissions() : drain_admissions();
      }

      // Build on the tick as always — but ALSO build immediately when fresh
      // admissions arrive and the 1-deep pipeline slot is free (build_frame
      // early-returns while a published plane awaits its scan): the first
      // phase of new ink/content then rides the NEXT flip instead of the
      // one after, cutting up to a full scan period of visible latency.
      if ((tick || admitted) && engine_busy()) {
        build_frame();
      }

      advance_cold_clear();

      process_mapped_events();
      publish_engine_state();
      flush_user_completions();
      update_stats_snapshot();
      maybe_log_stats();
      check_device_lost();

      if (config_.dry_run && engine_busy()) {
        if (config_.flip_interval_ms > 0) {
          dry_run_deadline +=
              std::chrono::milliseconds(config_.flip_interval_ms);
          std::this_thread::sleep_until(dry_run_deadline);
        } else {
          dry_run_deadline = std::chrono::steady_clock::now();
          std::this_thread::yield();
        }
      }
    }
  }

  bool engine_busy() const {
    return !engine_.idle() || engine_.parked_count() > 0;
  }

  enum class ColdClearPhase : std::uint8_t { kIdle, kBlack, kWhite, kDone };

  // Cold clear uses frame_id 0 and therefore never enters pending_frames_.
  // Publish its terminal transition under the wait_idle mutex, then notify,
  // so completion cannot race between a waiter's predicate check and sleep.
  void complete_cold_clear() {
    cold_clear_phase_ = ColdClearPhase::kDone;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      cold_clear_done_.store(true, std::memory_order_release);
    }
    idle_cv_.notify_all();
  }

  // Cold glass uses two short, naturally differing rail transitions. This
  // is deliberately not mode 0/INIT: Fast black and Fast white overlap their
  // full-field bands after the normal onset stagger and complete in roughly
  // two mode-7 waveforms instead of a 161-phase serial clear.
  void admit_cold_clear() {
    const WaveformTable &table = waveform_.table();
    const int bin = engine_.current_temp_bin();
    cold_clear_temp_bin_ = bin;
    cold_clear_mode_ = -1;
    const std::array<int, 3> candidates = color_enabled_
                                              ? std::array<int, 3>{2, -1, -1}
                                              : std::array<int, 3>{7, 1, 2};
    for (const int candidate : candidates) {
      if (candidate >= 0 && table.phase_count(candidate, bin) > 0) {
        cold_clear_mode_ = candidate;
        break;
      }
    }
    if (cold_clear_mode_ < 0) {
      if (color_enabled_) {
        set_color_fault("balanced color cold-clear mode is unavailable");
        return;
      }
      complete_cold_clear();
      return; // open() only proceeds with a valid table; defensive
    }
    if (color_enabled_ && legal_map_for(cold_clear_mode_, bin)[30] != 30) {
      set_color_fault("balanced color cold-clear cannot reach logical white");
      return;
    }
    const std::uint8_t black = legal_map_for(cold_clear_mode_, bin)[0];
    cold_levels_.assign(static_cast<std::size_t>(config_.engine.width) *
                            static_cast<std::size_t>(config_.engine.height),
                        black);
    AdmitRequest request;
    request.rect = {0, 0, config_.engine.width, config_.engine.height};
    request.mode = cold_clear_mode_;
    request.temp_bin = bin;
    request.levels = cold_levels_.data();
    request.levels_stride = 0;
    request.frame_id = 0; // settle sentinel
    request.flags = kAdmitFlagSettle;
    if (!engine_.admit(request)) {
      std::vector<std::uint8_t>().swap(cold_levels_);
      if (color_enabled_) {
        set_color_fault("color cold-clear black admission failed");
        return;
      }
      complete_cold_clear();
      return;
    }
    cold_clear_phase_ = ColdClearPhase::kBlack;
    cold_clear_completion_target_ = engine_.stats().settle_completions + 1;
  }

  void advance_cold_clear() {
    if (cold_clear_done_.load(std::memory_order_acquire) ||
        cold_clear_waiting_latch_ ||
        engine_.stats().settle_completions < cold_clear_completion_target_) {
      return;
    }
    if (cold_clear_phase_ == ColdClearPhase::kBlack) {
      const int bin = cold_clear_temp_bin_;
      const std::uint8_t white = legal_map_for(cold_clear_mode_, bin)[30];
      std::fill(cold_levels_.begin(), cold_levels_.end(), white);
      AdmitRequest request;
      request.rect = {0, 0, config_.engine.width, config_.engine.height};
      request.mode = cold_clear_mode_;
      request.temp_bin = bin;
      request.levels = cold_levels_.data();
      request.levels_stride = 0;
      request.frame_id = 0;
      request.flags = kAdmitFlagSettle;
      if (engine_.admit(request)) {
        cold_clear_phase_ = ColdClearPhase::kWhite;
        cold_clear_completion_target_ = engine_.stats().settle_completions + 1;
        return;
      }
      if (color_enabled_) {
        std::vector<std::uint8_t>().swap(cold_levels_);
        set_color_fault("color cold-clear white admission failed");
        return;
      }
    }
    std::vector<std::uint8_t>().swap(cold_levels_);
    if (color_enabled_) {
      if (config_.dry_run) {
        if (!color_pipeline_.initialize_white_history()) {
          set_color_fault("dry-run color history initialization failed");
          return;
        }
        complete_cold_clear();
      } else {
        // The engine completed while BUILDING the final white plane. Exact
        // A=30/B=0 becomes authoritative only when ScanFeedback proves this
        // build reached the scan latch.
        cold_clear_waiting_latch_ = true;
        cold_clear_latch_target_ = build_seq_;
      }
      return;
    }
    complete_cold_clear();
  }

  // E1 mode-identity lab (config.mode_lab_step_ms > 0): one horizontal band
  // per RAW .eink mode index, driven to black then erased to white with the
  // same mode, through the ordinary mailbox path. Camera stills after each
  // phase identify which modes actually develop and erase on THIS panel.
  void mode_lab_thread_main() {
    const auto stopping = [this] {
      std::lock_guard<std::mutex> lock(mutex_);
      return stopping_;
    };
    while (!cold_clear_done_.load(std::memory_order_acquire)) {
      if (stopping()) {
        return;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    const auto step =
        std::chrono::milliseconds(std::max(config_.mode_lab_step_ms, 100));
    std::this_thread::sleep_for(step); // let the clear settle visually

    const WaveformTable &table = waveform_.table();
    const int bin = engine_.current_temp_bin();
    const int n = table.mode_count();
    const int width = config_.engine.width;
    const int height = config_.engine.height;
    const int band_gap = 12;
    const int band_h =
        std::max(24, std::min(120, height / std::max(n, 1) - band_gap));
    std::fprintf(stderr, "mode_lab: %d modes, temp_bin=%d, band_h=%d\n", n, bin,
                 band_h);
    const auto band_rect = [&](int m) {
      PlutoRect rect;
      rect.x = 64;
      rect.y = 8 + m * (band_h + band_gap);
      rect.width = width - 128;
      rect.height = band_h;
      return rect;
    };
    for (const std::uint8_t level : {std::uint8_t{0x00}, std::uint8_t{0x1e}}) {
      for (int m = 0; m < n; ++m) {
        if (stopping()) {
          return;
        }
        if (table.phase_count(m, bin) <= 0 ||
            band_rect(m).y + band_h > height) {
          continue;
        }
        push_uniform_admission(band_rect(m), level, m, bin);
        std::fprintf(stderr, "mode_lab: mode=%d level=0x%02x phases=%d\n", m,
                     level, table.phase_count(m, bin));
        std::this_thread::sleep_for(step);
      }
      std::fprintf(stderr,
                   "mode_lab: %s phase complete — capture camera still\n",
                   level == 0x00 ? "DEVELOP(black)" : "ERASE(white)");
      std::this_thread::sleep_for(step * 4);
    }
    std::fprintf(stderr, "mode_lab: done\n");
  }

  // Tile-split uniform-level admission with a RAW mode index (mode-lab
  // only; mirrors the present() piece loop, settle-sentinel frame id).
  void push_uniform_admission(const PlutoRect &rect, std::uint8_t level,
                              int raw_mode, int temp_bin) {
    const int tile_px = static_cast<int>(config_.engine.tile_px);
    std::vector<std::uint8_t> piece_levels(
        static_cast<std::size_t>(tile_px) * tile_px, level);
    const std::int32_t ty0 = rect.y / tile_px;
    const std::int32_t ty1 = (rect.y + rect.height - 1) / tile_px;
    const std::int32_t tx0 = rect.x / tile_px;
    const std::int32_t tx1 = (rect.x + rect.width - 1) / tile_px;
    for (std::int32_t ty = ty0; ty <= ty1; ++ty) {
      for (std::int32_t tx = tx0; tx <= tx1; ++tx) {
        PlutoRect piece;
        piece.x = std::max(rect.x, tx * tile_px);
        piece.y = std::max(rect.y, ty * tile_px);
        piece.width =
            std::min(rect.x + rect.width, (tx + 1) * tile_px) - piece.x;
        piece.height =
            std::min(rect.y + rect.height, (ty + 1) * tile_px) - piece.y;
        AdmitRequest admit;
        admit.rect = piece;
        admit.mode = raw_mode;
        admit.temp_bin = temp_bin;
        admit.levels = piece_levels.data();
        admit.levels_stride = 0;
        admit.frame_id = 0; // settle sentinel: no user completion
        admit.flags = 0;
        while (mailbox_.push(admit) == kPlutoStatusAgain) {
          std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
      }
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      admissions_signal_ = true;
    }
    engine_cv_.notify_all();
  }

  std::vector<MappedTokenFrame>::iterator
  find_mapped_token(swtcon::MappedOperationToken token) {
    return std::find_if(mapped_token_frames_.begin(),
                        mapped_token_frames_.end(),
                        [token](const MappedTokenFrame &entry) {
                          return entry.token == token;
                        });
  }

  std::vector<SafeFastFrame>::iterator
  find_safe_fast_frame(std::uint64_t present_seq) {
    return std::find_if(safe_fast_frames_.begin(), safe_fast_frames_.end(),
                        [present_seq](const SafeFastFrame &frame) {
                          return frame.present_seq == present_seq;
                        });
  }

  std::pair<SafeFastFrame *, SafeFastPiece *>
  find_safe_fast_piece(std::uint64_t internal_engine_frame_id) {
    for (SafeFastFrame &frame : safe_fast_frames_) {
      for (SafeFastPiece &piece : frame.pieces) {
        if (piece.internal_engine_frame_id == internal_engine_frame_id) {
          return {&frame, &piece};
        }
      }
    }
    return {nullptr, nullptr};
  }

  // mutex_ must be held. Internal ids are never passed through the ABI and
  // are intercepted before generic completion processing. Still avoid every
  // live ABI id so an adversarial high user frame_id cannot alias one.
  std::uint64_t
  allocate_safe_fast_engine_id_locked(std::uint64_t avoid_engine_frame_id) {
    while (next_safe_fast_engine_id_ > kEngineFrameIdBias) {
      const std::uint64_t candidate = next_safe_fast_engine_id_--;
      if (candidate == avoid_engine_frame_id) {
        continue;
      }
      const bool reserved =
          std::find(reserved_safe_fast_engine_ids_.begin(),
                    reserved_safe_fast_engine_ids_.end(),
                    candidate) != reserved_safe_fast_engine_ids_.end();
      if (reserved) {
        continue;
      }
      bool pending = false;
      for (const PendingFrameSlot &slot : pending_frames_) {
        if (slot.state == PendingFrameState::kOccupied &&
            slot.frame_id + kEngineFrameIdBias == candidate) {
          pending = true;
          break;
        }
      }
      if (!pending) {
        return candidate;
      }
    }
    return 0;
  }

  void remove_terminal_token(swtcon::MappedOperationToken token) {
    for (std::size_t index = mapped_terminal_fences_.size(); index > 0;
         --index) {
      auto &tokens = mapped_terminal_fences_[index - 1].tokens;
      tokens.erase(std::remove(tokens.begin(), tokens.end(), token),
                   tokens.end());
      if (tokens.empty()) {
        mapped_terminal_fences_.erase(mapped_terminal_fences_.begin() +
                                      static_cast<std::ptrdiff_t>(index - 1));
        mapped_terminal_count_.fetch_sub(1, std::memory_order_release);
      }
    }
  }

  static bool inclusive_intersects(XochitlHistoryState::InclusiveRect a,
                                   XochitlHistoryState::InclusiveRect b) {
    return a.left <= b.right && b.left <= a.right && a.top <= b.bottom &&
           b.top <= a.bottom;
  }

  static bool inclusive_contains(XochitlHistoryState::InclusiveRect outer,
                                 XochitlHistoryState::InclusiveRect inner) {
    return outer.left <= inner.left && outer.top <= inner.top &&
           outer.right >= inner.right && outer.bottom >= inner.bottom;
  }

  static bool color_admits_overlap(const ColorAdmit &a, const ColorAdmit &b) {
    return a.payload != nullptr && b.payload != nullptr &&
           inclusive_intersects(a.payload->execution(), b.payload->execution());
  }

  bool snapshot_pen_focus_mailbox(PenFocusValue *out) const {
    if (out == nullptr) {
      return false;
    }
    for (int attempt = 0; attempt < 8; ++attempt) {
      const std::uint64_t ticket =
          pen_focus_mailbox_published_.load(std::memory_order_acquire);
      if (ticket == 0 || ticket <= applied_pen_focus_ticket_) {
        return false;
      }
      const AtomicPenFocusSlot &slot =
          pen_focus_mailbox_[ticket % kPenFocusMailboxCapacity];
      const std::uint64_t expected = ticket << 1u;
      if (slot.guard.load(std::memory_order_acquire) != expected) {
        continue;
      }
      PenFocusValue value;
      value.rect.x = slot.x.load(std::memory_order_relaxed);
      value.rect.y = slot.y.load(std::memory_order_relaxed);
      value.rect.width = slot.width.load(std::memory_order_relaxed);
      value.rect.height = slot.height.load(std::memory_order_relaxed);
      value.flags = slot.flags.load(std::memory_order_relaxed);
      value.sequence = slot.sequence.load(std::memory_order_relaxed);
      value.ticket = ticket;
      if (slot.guard.load(std::memory_order_acquire) == expected) {
        *out = value;
        return true;
      }
    }
    return false;
  }

  // mutex_ must be held; engine thread only. The mailbox ticket, rather than
  // an app sequence, is the publication order. A reopened presenter starts a
  // new ticket domain, so an app may restart its provenance sequence at 1.
  void apply_latest_pen_focus_locked() {
    PenFocusValue focus;
    if (!snapshot_pen_focus_mailbox(&focus)) {
      return;
    }
    const bool active =
        (focus.flags & static_cast<std::uint32_t>(kPlutoPenFocusInRange)) != 0;
    if (active) {
      const bool contact =
          (focus.flags & static_cast<std::uint32_t>(kPlutoPenFocusContact)) !=
          0;
      const bool geometry_changed =
          !pen_focus_active_ || pen_focus_contact_ != contact ||
          pen_focus_raw_rect_.x != focus.rect.x ||
          pen_focus_raw_rect_.y != focus.rect.y ||
          pen_focus_raw_rect_.width != focus.rect.width ||
          pen_focus_raw_rect_.height != focus.rect.height;
      if (geometry_changed) {
        ++pen_focus_motion_generation_;
        pen_focus_geometry_changed_ns_ = steady_now_ns();
      }
      const std::int64_t right =
          static_cast<std::int64_t>(focus.rect.x) + focus.rect.width;
      const std::int64_t bottom =
          static_cast<std::int64_t>(focus.rect.y) + focus.rect.height;
      // Mapped ownership and Fast parking collide by engine tile, not by
      // exact pixel intersection. Expand metadata to that physical domain.
      const std::int32_t tile =
          static_cast<std::int32_t>(config_.engine.tile_px);
      const std::int32_t x0 = (focus.rect.x / tile) * tile;
      const std::int32_t y0 = (focus.rect.y / tile) * tile;
      const std::int32_t x1 = std::min<std::int32_t>(
          kLogicalWidth,
          static_cast<std::int32_t>(((right + tile - 1) / tile) * tile));
      const std::int32_t y1 = std::min<std::int32_t>(
          kLogicalHeight,
          static_cast<std::int32_t>(((bottom + tile - 1) / tile) * tile));
      pen_focus_active_ = true;
      pen_focus_contact_ = contact;
      pen_focus_raw_rect_ = focus.rect;
      pen_focus_rect_ = {x0, y0, x1 - x0, y1 - y0};
      ++stat_color_pen_focus_updates_;
    } else {
      if (pen_focus_active_) {
        ++stat_color_pen_focus_clears_;
      }
      pen_focus_active_ = false;
      pen_focus_contact_ = false;
      pen_focus_raw_rect_ = {};
      pen_focus_rect_ = {};
    }
    pen_focus_sequence_ = focus.sequence;
    applied_pen_focus_ticket_ = focus.ticket;
  }

  // mutex_ must be held. Focus applies only to raw mapped truth that has not
  // left color_lane_. Safe Fast is the app-rendered preview lane and prepared
  // mapped_token_frames_ are deliberately outside this gate.
  bool color_admit_overlaps_pen_focus_locked(const ColorAdmit &admit) const {
    if (!pen_focus_active_ || admit.payload == nullptr ||
        admit.payload->mode() == XochitlHistoryState::Mode::kFast) {
      return false;
    }
    const XochitlHistoryState::InclusiveRect focus{
        pen_focus_rect_.x, pen_focus_rect_.y,
        pen_focus_rect_.x + pen_focus_rect_.width - 1,
        pen_focus_rect_.y + pen_focus_rect_.height - 1};
    return inclusive_intersects(admit.payload->execution(), focus);
  }

  bool pen_focus_blocks_color_admit_locked(ColorAdmit &admit,
                                           std::uint64_t now_ns) {
    if (!color_admit_overlaps_pen_focus_locked(admit)) {
      return false;
    }
    if (admit.pen_focus_defer_until_ns == 0) {
      admit.pen_focus_defer_until_ns =
          now_ns > std::numeric_limits<std::uint64_t>::max() -
                       kPenFocusTruthChaseNs
              ? std::numeric_limits<std::uint64_t>::max()
              : now_ns + kPenFocusTruthChaseNs;
      admit.pen_focus_motion_generation = pen_focus_motion_generation_;
    } else if (admit.pen_focus_motion_generation !=
               pen_focus_motion_generation_) {
      const std::uint64_t moved_deadline =
          pen_focus_geometry_changed_ns_ >
                  std::numeric_limits<std::uint64_t>::max() -
                      kPenFocusTruthChaseNs
              ? std::numeric_limits<std::uint64_t>::max()
              : pen_focus_geometry_changed_ns_ + kPenFocusTruthChaseNs;
      admit.pen_focus_defer_until_ns =
          std::max(admit.pen_focus_defer_until_ns, moved_deadline);
      admit.pen_focus_motion_generation = pen_focus_motion_generation_;
    }
    return now_ns < admit.pen_focus_defer_until_ns;
  }

  std::uint64_t earliest_pen_focus_deadline_locked(std::uint64_t now_ns) const {
    std::uint64_t earliest = 0;
    for (const ColorAdmit &admit : color_lane_) {
      if (admit.pen_focus_defer_until_ns <= now_ns ||
          !color_admit_overlaps_pen_focus_locked(admit)) {
        continue;
      }
      if (earliest == 0 || admit.pen_focus_defer_until_ns < earliest) {
        earliest = admit.pen_focus_defer_until_ns;
      }
    }
    return earliest;
  }

  bool color_admit_overlaps_live_fast(const ColorAdmit &admit) const {
    if (admit.payload == nullptr) {
      return false;
    }
    for (const SafeFastFrame &frame : safe_fast_frames_) {
      for (const SafeFastPiece &piece : frame.pieces) {
        if (piece.payload != nullptr &&
            inclusive_intersects(admit.payload->execution(),
                                 piece.payload->execution())) {
          return true;
        }
      }
    }
    return false;
  }

  // mutex_ must be held; engine thread only. A complete later Fast present may
  // pass disjoint older raw work, and may retire an overlapping older raw
  // mapped-truth obligation only when one Fast execution wholly contains it.
  // Partial coverage and older Fast batches remain ordered. Prepared tokens
  // are handled separately at the engine boundary, where discard_mapped() can
  // prove no phase was built.
  std::size_t select_color_lane_index_locked(bool *bypassed) {
    // Reload the lock-free input mailbox inside the selection critical
    // section. A focus publication never waits for this mutex, but the engine
    // must observe its latest committed ticket before choosing raw truth.
    apply_latest_pen_focus_locked();
    if (bypassed != nullptr) {
      *bypassed = false;
    }
    if (color_lane_.empty()) {
      bypass_fast_present_seq_ = 0;
      return color_lane_.size();
    }
    if (bypass_fast_present_seq_ != 0) {
      const auto continuation = std::find_if(
          color_lane_.begin(), color_lane_.end(), [this](const ColorAdmit &a) {
            return a.fast_present_seq == bypass_fast_present_seq_;
          });
      if (continuation != color_lane_.end()) {
        return static_cast<std::size_t>(
            std::distance(color_lane_.begin(), continuation));
      }
      bypass_fast_present_seq_ = 0;
    }
    ColorAdmit &front = color_lane_.front();
    const bool front_epoch_blocked =
        front.retry_after_dependency_epoch > color_dependency_epoch_;
    const bool front_fast =
        front.payload != nullptr &&
        front.payload->mode() == XochitlHistoryState::Mode::kFast;
    const bool front_fast_dependency =
        !front_fast && color_admit_overlaps_live_fast(front);
    // Never reorder one Fast batch around an older Fast batch. For a
    // non-Fast head, however, inspect later Fast presents even when the head
    // is otherwise runnable: disjoint work can coexist, and wholly covered
    // unprepared truth is safely superseded before it acquires optical state.
    // This keeps the nib/hover lane from paying a legacy prepare plus a long
    // mapped waveform merely because that older raw entry reached the FIFO
    // first.
    if (front_fast) {
      return 0;
    }

    for (std::size_t candidate = 1; candidate < color_lane_.size();) {
      const ColorAdmit &first = color_lane_[candidate];
      if (first.payload == nullptr ||
          first.payload->mode() != XochitlHistoryState::Mode::kFast ||
          first.fast_present_seq == 0 || first.fast_piece_count == 0 ||
          first.fast_piece_index != 0) {
        ++candidate;
        continue;
      }
      std::size_t end = candidate;
      while (end < color_lane_.size() &&
             color_lane_[end].fast_present_seq == first.fast_present_seq) {
        ++end;
      }
      if (end - candidate != first.fast_piece_count) {
        return color_lane_.size(); // producer publishes a batch atomically
      }
      const std::uint64_t candidate_present_seq = first.fast_present_seq;
      bool safe = true;
      std::vector<std::size_t> superseded;
      superseded.reserve(candidate);
      for (std::size_t older = 0; older < candidate && safe; ++older) {
        const ColorAdmit &old = color_lane_[older];
        if (old.payload == nullptr) {
          safe = false;
          break;
        }
        bool overlaps = false;
        bool fully_covered = false;
        for (std::size_t piece = candidate; piece < end; ++piece) {
          const ColorAdmit &fast = color_lane_[piece];
          if (!color_admits_overlap(fast, old)) {
            continue;
          }
          overlaps = true;
          if (fast.payload != nullptr &&
              inclusive_contains(fast.payload->execution(),
                                 old.payload->execution())) {
            fully_covered = true;
          }
        }
        if (!overlaps) {
          continue;
        }
        const bool old_fast =
            old.payload->mode() == XochitlHistoryState::Mode::kFast;
        if (old_fast || !fully_covered) {
          safe = false;
          break;
        }
        superseded.push_back(older);
      }
      if (safe) {
        // Newest-wins retirement is piece-granular. The old raw operation has
        // never been prepared, so there is no history journal or optical state
        // to discard. Completion still settles its ABI obligation exactly once.
        for (auto it = superseded.rbegin(); it != superseded.rend(); ++it) {
          engine_completions_.push_back(color_lane_[*it].engine_frame_id);
          color_obligation_count_.fetch_sub(1, std::memory_order_release);
          color_lane_.erase(color_lane_.begin() +
                            static_cast<std::ptrdiff_t>(*it));
        }
        candidate -= superseded.size();
        bypass_fast_present_seq_ = candidate_present_seq;
        if (bypassed != nullptr) {
          *bypassed = true;
        }
        return candidate;
      }
      candidate = end;
    }
    const std::uint64_t focus_now_ns = steady_now_ns();
    const bool front_focus_blocked =
        pen_focus_blocks_color_admit_locked(front, focus_now_ns);
    if (!front_focus_blocked) {
      return (!front_epoch_blocked && !front_fast_dependency)
                 ? std::size_t{0}
                 : color_lane_.size();
    }

    ++stat_color_pen_focus_truth_deferrals_;
    // Preserve overlap order, but let exact disjoint fidelity continue behind
    // one or more focus-held raw entries. The first non-focus item is an
    // ordering barrier unless it is runnable and disjoint from every skipped
    // entry; later work never jumps around that barrier.
    for (std::size_t candidate = 1; candidate < color_lane_.size();
         ++candidate) {
      ColorAdmit &next = color_lane_[candidate];
      if (next.payload == nullptr ||
          next.payload->mode() == XochitlHistoryState::Mode::kFast) {
        return color_lane_.size();
      }
      if (pen_focus_blocks_color_admit_locked(next, focus_now_ns)) {
        continue;
      }
      if (next.retry_after_dependency_epoch > color_dependency_epoch_ ||
          color_admit_overlaps_live_fast(next)) {
        return color_lane_.size();
      }
      for (std::size_t older = 0; older < candidate; ++older) {
        if (color_admits_overlap(next, color_lane_[older])) {
          return color_lane_.size();
        }
      }
      ++stat_color_pen_focus_disjoint_bypasses_;
      return candidate;
    }
    return color_lane_.size();
  }

  static bool safe_fast_frames_overlap(const SafeFastFrame &a,
                                       const SafeFastFrame &b) {
    for (const SafeFastPiece &left : a.pieces) {
      if (left.payload == nullptr) {
        continue;
      }
      for (const SafeFastPiece &right : b.pieces) {
        if (right.payload != nullptr &&
            inclusive_intersects(left.payload->execution(),
                                 right.payload->execution())) {
          return true;
        }
      }
    }
    return false;
  }

  bool safe_fast_completion_needs_fence(std::size_t begin) {
    for (std::size_t index = begin; index < engine_completions_.size();
         ++index) {
      const auto [frame, piece] =
          find_safe_fast_piece(engine_completions_[index]);
      (void)frame;
      if (piece != nullptr && piece->coverage != nullptr &&
          !piece->coverage->empty()) {
        return true;
      }
    }
    return false;
  }

  void record_safe_fast_drive_build(std::uint64_t engine_frame,
                                    std::uint64_t build_seq) {
    for (SafeFastFrame &frame : safe_fast_frames_) {
      for (SafeFastPiece &piece : frame.pieces) {
        if (piece.coverage != nullptr && !piece.coverage->empty() &&
            piece.coverage->last_drive_engine_frame() == engine_frame) {
          piece.last_drive_build_seq =
              std::max(piece.last_drive_build_seq, build_seq);
        }
      }
    }
  }

  void capture_safe_fast_completions(std::size_t begin,
                                     std::uint64_t terminal_build_seq) {
    if (begin >= engine_completions_.size()) {
      return;
    }
    std::size_t write = begin;
    for (std::size_t read = begin; read < engine_completions_.size(); ++read) {
      const std::uint64_t id = engine_completions_[read];
      const auto [frame, piece] = find_safe_fast_piece(id);
      if (frame == nullptr || piece == nullptr) {
        engine_completions_[write++] = id;
        continue;
      }
      if (piece->completion_arrived) {
        set_color_fault("duplicate safe Fast engine completion");
        continue;
      }
      piece->completion_arrived = true;
      ++frame->completed_pieces;
      if (piece->coverage == nullptr || !piece->coverage->valid()) {
        set_color_fault("invalid safe Fast coverage journal");
        continue;
      }
      if (!piece->coverage->empty()) {
        const std::uint64_t fence_seq = terminal_build_seq != 0
                                            ? terminal_build_seq
                                            : piece->last_drive_build_seq;
        if (fence_seq == 0) {
          set_color_fault("driven safe Fast completed without terminal build");
          continue;
        }
        frame->terminal_build_seq =
            std::max(frame->terminal_build_seq, fence_seq);
      }
    }
    engine_completions_.resize(write);
  }

  void release_safe_fast_frame(std::size_t index) {
    if (index >= safe_fast_frames_.size()) {
      return;
    }
    SafeFastFrame frame = std::move(safe_fast_frames_[index]);
    safe_fast_frames_.erase(safe_fast_frames_.begin() +
                            static_cast<std::ptrdiff_t>(index));
    for (std::uint32_t piece = 0; piece < frame.expected_pieces; ++piece) {
      engine_completions_.push_back(frame.abi_engine_frame_id);
    }
    if (color_dependency_epoch_ != std::numeric_limits<std::uint64_t>::max()) {
      ++color_dependency_epoch_;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const std::size_t fast_before = color_fast_obligation_count_.fetch_sub(
          frame.expected_pieces, std::memory_order_release);
      const std::size_t total_before = color_obligation_count_.fetch_sub(
          frame.expected_pieces, std::memory_order_release);
      assert(fast_before >= frame.expected_pieces);
      assert(total_before >= frame.expected_pieces);
      (void)fast_before;
      (void)total_before;
      for (const SafeFastPiece &piece : frame.pieces) {
        reserved_safe_fast_engine_ids_.erase(
            std::remove(reserved_safe_fast_engine_ids_.begin(),
                        reserved_safe_fast_engine_ids_.end(),
                        piece.internal_engine_frame_id),
            reserved_safe_fast_engine_ids_.end());
      }
      if (!color_lane_.empty()) {
        admissions_signal_ = true;
      }
    }
  }

  // Fail-closed cleanup for a malformed/rejected member of a Fast present.
  // SafeFastFrame completion is whole-present atomic, so no member has
  // retired from the obligation counters until release_safe_fast_frame().
  // Remove the remaining raw entries and partial frame together and retire
  // the original expected count exactly once. Any already-admitted internal
  // engine pieces may still finish, but device_lost_ rejects future presents
  // and their now-unmapped private completion ids are intentionally ignored.
  void abandon_safe_fast_present(std::uint64_t present_seq,
                                 std::uint32_t expected_pieces,
                                 std::uint64_t failed_engine_id) {
    if (present_seq == 0 || expected_pieces == 0) {
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const auto release_reserved_id = [this](std::uint64_t engine_id) {
      reserved_safe_fast_engine_ids_.erase(
          std::remove(reserved_safe_fast_engine_ids_.begin(),
                      reserved_safe_fast_engine_ids_.end(), engine_id),
          reserved_safe_fast_engine_ids_.end());
    };
    release_reserved_id(failed_engine_id);
    for (std::size_t index = 0; index < color_lane_.size();) {
      if (color_lane_[index].fast_present_seq == present_seq) {
        release_reserved_id(color_lane_[index].safe_fast_engine_id);
        color_lane_.erase(color_lane_.begin() +
                          static_cast<std::ptrdiff_t>(index));
      } else {
        ++index;
      }
    }
    const auto frame = find_safe_fast_frame(present_seq);
    if (frame != safe_fast_frames_.end()) {
      expected_pieces = frame->expected_pieces;
      for (const SafeFastPiece &piece : frame->pieces) {
        release_reserved_id(piece.internal_engine_frame_id);
      }
      safe_fast_frames_.erase(frame);
    }
    const std::size_t fast_before = color_fast_obligation_count_.fetch_sub(
        expected_pieces, std::memory_order_release);
    const std::size_t total_before = color_obligation_count_.fetch_sub(
        expected_pieces, std::memory_order_release);
    assert(fast_before >= expected_pieces);
    assert(total_before >= expected_pieces);
    (void)fast_before;
    (void)total_before;
    if (bypass_fast_present_seq_ == present_seq) {
      bypass_fast_present_seq_ = 0;
    }
  }

  void release_ready_noop_safe_fast_frames() {
    for (std::size_t index = 0; index < safe_fast_frames_.size();) {
      const SafeFastFrame &frame = safe_fast_frames_[index];
      const bool complete = frame.admitted_pieces == frame.expected_pieces &&
                            frame.completed_pieces == frame.expected_pieces;
      const bool any_driven = std::any_of(
          frame.pieces.begin(), frame.pieces.end(),
          [](const SafeFastPiece &piece) {
            return piece.coverage != nullptr && !piece.coverage->empty();
          });
      bool blocked_by_older_overlap = false;
      if (complete && !any_driven) {
        for (std::size_t older = 0; older < safe_fast_frames_.size(); ++older) {
          if (safe_fast_frames_[older].present_seq >= frame.present_seq) {
            continue;
          }
          if (safe_fast_frames_overlap(safe_fast_frames_[older], frame)) {
            blocked_by_older_overlap = true;
            break;
          }
        }
      }
      if (complete && !any_driven && !blocked_by_older_overlap) {
        release_safe_fast_frame(index);
        continue;
      }
      ++index;
    }
  }

  bool collect_higher_live_fast_coverage(
      std::uint64_t seed_seq, PlutoRect destination_rect,
      std::size_t destination_stride,
      std::span<std::uint8_t> destination_bits) const {
    for (const SafeFastFrame &frame : safe_fast_frames_) {
      for (const SafeFastPiece &piece : frame.pieces) {
        if (piece.seed_seq <= seed_seq || piece.coverage == nullptr ||
            !piece.coverage->valid() || piece.coverage->empty()) {
          continue;
        }
        if (!swtcon::or_fast_coverage_overlap(
                piece.coverage->rect(), piece.coverage->bits(),
                piece.coverage->stride_bytes(), destination_rect,
                destination_bits, destination_stride)) {
          return false;
        }
      }
    }
    return true;
  }

  bool seed_safe_fast_piece(const SafeFastPiece &piece) {
    if (piece.payload == nullptr || piece.coverage == nullptr ||
        !piece.coverage->valid() || piece.seed_seq == 0) {
      return false;
    }
    const auto execution = piece.payload->execution();
    const PlutoRect coverage_rect = piece.coverage->rect();
    const std::int32_t width = execution.right - execution.left + 1;
    const std::int32_t height = execution.bottom - execution.top + 1;
    const std::int32_t visible_right =
        std::min(execution.right, XochitlHistoryState::kLogicalWidth - 1);
    const std::int32_t visible_bottom =
        std::min(execution.bottom, XochitlHistoryState::kLogicalHeight - 1);
    if (coverage_rect.x != execution.left || coverage_rect.y != execution.top ||
        coverage_rect.width != visible_right - execution.left + 1 ||
        coverage_rect.height != visible_bottom - execution.top + 1 ||
        fast_seed_seq_.size() != XochitlHistoryState::kStoragePixels) {
      return false;
    }

    const std::size_t stride =
        (static_cast<std::size_t>(width) + std::size_t{7}) / 8u;
    const std::size_t confirmed_stride = piece.coverage->stride_bytes();
    const std::size_t filtered_size = stride * static_cast<std::size_t>(height);
    const std::size_t confirmed_size = piece.coverage->bits().size();
    fast_filtered_scratch_.resize(filtered_size);
    fast_confirmed_scratch_.resize(confirmed_size);
    fast_newer_coverage_scratch_.resize(confirmed_size);
    std::fill(fast_filtered_scratch_.begin(), fast_filtered_scratch_.end(), 0u);
    std::fill(fast_confirmed_scratch_.begin(), fast_confirmed_scratch_.end(),
              0u);
    std::fill(fast_newer_coverage_scratch_.begin(),
              fast_newer_coverage_scratch_.end(), 0u);
    if (!collect_higher_live_fast_coverage(piece.seed_seq, coverage_rect,
                                           confirmed_stride,
                                           fast_newer_coverage_scratch_)) {
      return false;
    }

    const std::vector<std::uint8_t> &coverage_bits = piece.coverage->bits();
    const std::size_t words_per_row =
        (static_cast<std::size_t>(coverage_rect.width) + 63u) / 64u;
    std::size_t retained = 0;
    for (std::int32_t y = 0; y < coverage_rect.height; ++y) {
      const std::size_t coverage_row =
          static_cast<std::size_t>(y) * confirmed_stride;
      for (std::size_t word_index = 0; word_index < words_per_row;
           ++word_index) {
        const std::size_t byte_offset = word_index * sizeof(std::uint64_t);
        const std::size_t coverage_bytes =
            byte_offset < confirmed_stride
                ? std::min(sizeof(std::uint64_t),
                           confirmed_stride - byte_offset)
                : 0;
        std::uint64_t current_word = 0;
        std::uint64_t newer_word = 0;
        if (coverage_bytes != 0) {
          std::memcpy(&current_word,
                      coverage_bits.data() + coverage_row + byte_offset,
                      coverage_bytes);
          std::memcpy(&newer_word,
                      fast_newer_coverage_scratch_.data() + coverage_row +
                          byte_offset,
                      coverage_bytes);
        }
        std::uint64_t candidates = current_word & ~newer_word;
        std::uint64_t retained_word = 0;
        while (candidates != 0) {
          const unsigned bit = std::countr_zero(candidates);
          candidates &= candidates - 1u;
          const std::size_t x = word_index * 64u + bit;
          if (x >= static_cast<std::size_t>(coverage_rect.width)) {
            continue;
          }
          const std::size_t panel =
              static_cast<std::size_t>(coverage_rect.y + y) *
                  XochitlHistoryState::kStorageStride +
              static_cast<std::size_t>(coverage_rect.x) + x;
          if (fast_seed_seq_[panel] >= piece.seed_seq) {
            continue;
          }
          retained_word |= std::uint64_t{1} << bit;
          ++retained;
        }
        if (retained_word == 0) {
          continue;
        }
        std::memcpy(fast_confirmed_scratch_.data() + coverage_row + byte_offset,
                    &retained_word, coverage_bytes);
      }
    }
    if (retained == 0) {
      return true;
    }
    // Coverage is currently the visible prefix of execution, but keep this
    // transfer coordinate-aware: future clipped/sub-piece proofs must not be
    // shifted merely because their origin is not byte-aligned to execution.
    const PlutoRect execution_rect{execution.left, execution.top, width,
                                   height};
    if (!swtcon::or_fast_coverage_overlap(
            coverage_rect, fast_confirmed_scratch_, confirmed_stride,
            execution_rect, fast_filtered_scratch_, stride)) {
      return false;
    }
    if (!color_pipeline_.history().reseed_fast_region_from_raw(
            piece.payload->requested(), execution, piece.payload->raw(),
            piece.payload->raw_stride(), fast_filtered_scratch_, stride)) {
      return false;
    }
    if (!engine_.confirm_safe_fast_latched(
            *piece.coverage, fast_confirmed_scratch_, confirmed_stride)) {
      return false;
    }

    // Mirror the history method's storage-guard replication into the
    // newest-wins seed ledger. Visible unmarked padding remains untouched.
    const auto filtered_set = [&](std::int32_t source_x,
                                  std::int32_t source_y) {
      const std::size_t byte = static_cast<std::size_t>(source_y) * stride +
                               static_cast<std::size_t>(source_x) / 8u;
      return (fast_filtered_scratch_[byte] &
              static_cast<std::uint8_t>(
                  1u << (static_cast<unsigned>(source_x) & 7u))) != 0;
    };
    for (std::int32_t y = 0; y < height; ++y) {
      const std::int32_t panel_y = execution.top + y;
      const std::int32_t source_y =
          std::min(panel_y, XochitlHistoryState::kLogicalHeight - 1) -
          execution.top;
      for (std::int32_t x = 0; x < width; ++x) {
        const std::int32_t panel_x = execution.left + x;
        const std::int32_t source_x =
            std::min(panel_x, XochitlHistoryState::kLogicalWidth - 1) -
            execution.left;
        if (source_x >= 0 && source_y >= 0 &&
            filtered_set(source_x, source_y)) {
          fast_seed_seq_[static_cast<std::size_t>(panel_y) *
                             XochitlHistoryState::kStorageStride +
                         static_cast<std::size_t>(panel_x)] = piece.seed_seq;
        }
      }
    }
    stat_color_reconciles_.fetch_add(1, std::memory_order_relaxed);
    return true;
  }

  bool resolve_safe_fast_latch(std::uint64_t build_seq, bool known_latch) {
    std::vector<std::uint64_t> &ready = safe_fast_ready_scratch_;
    ready.clear();
    for (const SafeFastFrame &frame : safe_fast_frames_) {
      if (frame.terminal_build_seq == build_seq &&
          frame.admitted_pieces == frame.expected_pieces &&
          frame.completed_pieces == frame.expected_pieces) {
        ready.push_back(frame.present_seq);
      }
    }
    if (ready.empty()) {
      return true;
    }
    if (!known_latch) {
      set_color_fault("safe Fast terminal latch is unknown");
      return false;
    }
    std::sort(ready.begin(), ready.end());
    for (const std::uint64_t present_seq : ready) {
      const auto frame = find_safe_fast_frame(present_seq);
      if (frame == safe_fast_frames_.end()) {
        continue;
      }
      std::vector<const SafeFastPiece *> &pieces =
          safe_fast_piece_order_scratch_;
      pieces.clear();
      for (const SafeFastPiece &piece : frame->pieces) {
        pieces.push_back(&piece);
      }
      std::sort(pieces.begin(), pieces.end(),
                [](const SafeFastPiece *a, const SafeFastPiece *b) {
                  return a->seed_seq < b->seed_seq;
                });
      for (const SafeFastPiece *piece : pieces) {
        if (!piece->coverage->empty() && !seed_safe_fast_piece(*piece)) {
          set_color_fault("safe Fast masked history seed failed");
          return false;
        }
      }
    }
    // Seed every frame in global present order before releasing any callback;
    // overlapping newest raw is therefore authoritative atomically to the
    // mapped-truth lane.
    for (const std::uint64_t present_seq : ready) {
      const auto frame = find_safe_fast_frame(present_seq);
      if (frame != safe_fast_frames_.end()) {
        release_safe_fast_frame(static_cast<std::size_t>(
            std::distance(safe_fast_frames_.begin(), frame)));
      }
    }
    release_ready_noop_safe_fast_frames();
    return true;
  }

  void resolve_previously_latched_safe_fast_frames() {
    for (;;) {
      std::uint64_t ready_seq = 0;
      for (const SafeFastFrame &frame : safe_fast_frames_) {
        if (frame.terminal_build_seq != 0 &&
            frame.terminal_build_seq <= last_known_safe_scan_seq_ &&
            frame.admitted_pieces == frame.expected_pieces &&
            frame.completed_pieces == frame.expected_pieces &&
            (ready_seq == 0 || frame.terminal_build_seq < ready_seq)) {
          ready_seq = frame.terminal_build_seq;
        }
      }
      const std::size_t before = safe_fast_frames_.size();
      if (ready_seq == 0 || !resolve_safe_fast_latch(ready_seq, true) ||
          safe_fast_frames_.size() == before) {
        return;
      }
    }
  }

  void set_color_fault(const char *reason) {
    color_pipeline_.invalidate_history();
    pen_focus_accepting_.store(false, std::memory_order_release);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!device_lost_) {
        stat_color_faults_.fetch_add(1, std::memory_order_relaxed);
        device_lost_ = true;
        std::fprintf(stderr, "swtcon: color history fail-closed: %s\n",
                     reason != nullptr ? reason : "unknown");
      }
    }
    idle_cv_.notify_all();
  }

  void set_scan_identity_fault(const char *reason) {
    if (color_enabled_) {
      set_color_fault(reason);
      return;
    }
    pen_focus_accepting_.store(false, std::memory_order_release);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!device_lost_) {
        device_lost_ = true;
        std::fprintf(stderr, "swtcon: scan identity fail-closed: %s\n",
                     reason != nullptr ? reason : "unknown");
      }
    }
    idle_cv_.notify_all();
  }

  void process_mapped_events() {
    for (const swtcon::MappedEvent &event : mapped_events_) {
      if (event.kind == swtcon::MappedEventKind::kTerminal) {
        continue;
      }
      if (color_dependency_epoch_ !=
          std::numeric_limits<std::uint64_t>::max()) {
        ++color_dependency_epoch_;
      }
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!color_lane_.empty()) {
          admissions_signal_ = true;
        }
      }
      const auto found = find_mapped_token(event.token);
      if (found == mapped_token_frames_.end()) {
        continue;
      }
      if (event.kind == swtcon::MappedEventKind::kDiscarded) {
        if (event.discard_reason ==
            swtcon::MappedDiscardReason::kStaleAfterMvccSeed) {
          if (event.retry_cookie == 0 ||
              event.retry_cookie != found->retry_cookie) {
            set_color_fault("stale mapped retry cookie mismatch");
            color_obligation_count_.fetch_sub(1, std::memory_order_release);
            mapped_token_frames_.erase(found);
            continue;
          }
          ColorAdmit retry;
          retry.payload = found->payload;
          retry.engine_frame_id = found->engine_frame_id;
          retry.retry_cookie = found->retry_cookie;
          retry.retry_after_dependency_epoch = color_dependency_epoch_;
          retry.enqueued_ns = static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(
                  std::chrono::steady_clock::now().time_since_epoch())
                  .count());
          mapped_token_frames_.erase(found);
          {
            std::lock_guard<std::mutex> lock(mutex_);
            color_lane_.insert(color_lane_.begin(), std::move(retry));
            admissions_signal_ = true;
          }
          continue; // same ABI obligation; no completion/decrement
        }
        if (event.discard_reason !=
            swtcon::MappedDiscardReason::kSupersededByNewer) {
          remove_terminal_token(event.token);
          set_color_fault("mapped operation discarded without supersession");
        }
      }
      if (event.kind == swtcon::MappedEventKind::kDisplacedForFast ||
          event.kind == swtcon::MappedEventKind::kInvalidatedForReseed ||
          event.kind == swtcon::MappedEventKind::kInvalidated) {
        remove_terminal_token(event.token);
        // No production exact-color path is allowed to invalidate mapped
        // truth. In particular, safe ordinary Fast parks behind mapped tile
        // claims instead of truncating them. Never fabricate a successful
        // user completion for truth whose optical/history transaction died.
        set_color_fault(event.kind == swtcon::MappedEventKind::kDisplacedForFast
                            ? "mapped operation displaced by unsafe Fast"
                            : "mapped operation invalidated");
      }
      color_obligation_count_.fetch_sub(1, std::memory_order_release);
      mapped_token_frames_.erase(found);
    }
    mapped_events_.clear();
  }

  void finalize_terminal_fence(std::size_t index, bool known_latch) {
    if (index >= mapped_terminal_fences_.size()) {
      return;
    }
    MappedTerminalFence fence = std::move(mapped_terminal_fences_[index]);
    mapped_terminal_fences_.erase(mapped_terminal_fences_.begin() +
                                  static_cast<std::ptrdiff_t>(index));
    mapped_terminal_count_.fetch_sub(1, std::memory_order_release);
    for (const swtcon::MappedOperationToken token : fence.tokens) {
      const swtcon::MappedFinalizeStatus status =
          known_latch ? engine_.confirm_mapped(token)
                      : engine_.invalidate_mapped(token);
      const bool accepted =
          known_latch ? status == swtcon::MappedFinalizeStatus::kConfirmed
                      : status == swtcon::MappedFinalizeStatus::kInvalidated;
      if (!accepted) {
        set_color_fault(known_latch ? "mapped commit failed"
                                    : "mapped invalidation failed");
      }
    }
  }

  void process_scan_feedback() {
    for (const ScanFeedback &feedback : scan_feedback_scratch_) {
      bool scan_identity_safe = true;
      if (!feedback.latched_scan_known && feedback.latched_engine_seq != 0) {
        // Do not fake-positive acknowledge an unknown content identity.
        // Device loss lets wait_idle return even though ScanReadySlot remains
        // deliberately unacknowledged.
        set_scan_identity_fault("unknown content flip identity");
        scan_identity_safe = false;
      }
      if (feedback.previous_flip_valid && feedback.previous_engine_seq != 0 &&
          !feedback.previous_scan_count_known) {
        set_scan_identity_fault("unresolved prior content scan count");
        scan_identity_safe = false;
      }
      if (feedback.previous_content_resolved &&
          feedback.previous_scan_count_known &&
          feedback.previous_engine_seq != 0) {
        std::uint64_t resolved =
            last_resolved_content_seq_.load(std::memory_order_relaxed);
        while (resolved < feedback.previous_engine_seq &&
               !last_resolved_content_seq_.compare_exchange_weak(
                   resolved, feedback.previous_engine_seq,
                   std::memory_order_release, std::memory_order_relaxed)) {
        }
        handoff_cv_.notify_all();
      }
      if (!first_visible_latch_logged_ && feedback.latched_scan_known &&
          first_user_build_seq_ != 0 &&
          feedback.latched_engine_seq == first_user_build_seq_) {
        first_visible_latch_logged_ = true;
        const std::uint64_t now_ns = steady_now_ns();
        const std::uint64_t admission_ns =
            first_user_admission_t_ns_.load(std::memory_order_acquire);
        std::fprintf(
            stderr,
            "swtcon: first_visible_latch warm=%d seq=%llu "
            "open_to_latch_us=%llu admission_to_latch_us=%llu t_ns=%llu\n",
            warm_handoff_accepted_.load(std::memory_order_acquire) ? 1 : 0,
            static_cast<unsigned long long>(first_user_build_seq_),
            static_cast<unsigned long long>((now_ns - presenter_open_t_ns_) /
                                            1000u),
            static_cast<unsigned long long>(
                admission_ns == 0 ? 0 : (now_ns - admission_ns) / 1000u),
            static_cast<unsigned long long>(now_ns));
      }
      if (cold_clear_waiting_latch_ &&
          feedback.latched_engine_seq == cold_clear_latch_target_) {
        if (!feedback.latched_scan_known) {
          set_color_fault("cold-clear terminal latch is unknown");
        } else if (!color_pipeline_.initialize_white_history()) {
          set_color_fault("color history white initialization failed");
        } else {
          cold_clear_waiting_latch_ = false;
          cold_clear_latch_target_ = 0;
          complete_cold_clear();
        }
      }

      if (feedback.latched_engine_seq != 0) {
        if (feedback.latched_scan_known) {
          for (const SafeFastFrame &frame : safe_fast_frames_) {
            if (frame.terminal_build_seq != 0 &&
                frame.terminal_build_seq > last_known_safe_scan_seq_ &&
                frame.terminal_build_seq < feedback.latched_engine_seq) {
              set_color_fault("safe Fast terminal scan identity was skipped");
              scan_identity_safe = false;
              break;
            }
          }
        }
        if (scan_identity_safe) {
          if (feedback.latched_scan_known) {
            last_known_safe_scan_seq_ = std::max(last_known_safe_scan_seq_,
                                                 feedback.latched_engine_seq);
          }
          (void)resolve_safe_fast_latch(feedback.latched_engine_seq,
                                        feedback.latched_scan_known);
          resolve_previously_latched_safe_fast_frames();
        } else {
          (void)resolve_safe_fast_latch(feedback.latched_engine_seq,
                                        /*known_latch=*/false);
        }
      }

      for (std::size_t index = mapped_terminal_fences_.size(); index > 0;
           --index) {
        const std::uint64_t seq = mapped_terminal_fences_[index - 1].build_seq;
        if (seq == feedback.latched_engine_seq) {
          finalize_terminal_fence(index - 1, feedback.latched_scan_known);
        } else if (feedback.latched_scan_known &&
                   feedback.latched_engine_seq != 0 &&
                   seq < feedback.latched_engine_seq) {
          // A wrong/skipped/unknown identity is never evidence for commit.
          // Invalidate conservatively instead of leaving a terminal lock (or
          // wait_idle) pending forever.
          finalize_terminal_fence(index - 1, false);
        }
      }
    }
  }

  bool admit_safe_fast(ColorAdmit admit) {
    if (admit.payload == nullptr ||
        admit.payload->mode() != XochitlHistoryState::Mode::kFast ||
        admit.safe_fast_engine_id == 0 || admit.fast_present_seq == 0 ||
        admit.fast_piece_seq == 0 || admit.fast_piece_count == 0 ||
        admit.fast_piece_index >= admit.fast_piece_count) {
      set_color_fault("malformed safe Fast lane entry");
      return false;
    }

    // A newer Fast payload may cancel wholly covered mapped truth only when
    // PixelEngine proves that token has emitted no phase. A scanned token is
    // untouchable: leave its claim in place and let ordinary safe Fast park.
    const auto fast_execution = admit.payload->execution();
    for (std::size_t index = mapped_token_frames_.size(); index > 0; --index) {
      const MappedTokenFrame &mapped = mapped_token_frames_[index - 1];
      if (mapped.payload == nullptr) {
        set_color_fault("mapped token lost immutable payload");
        return false;
      }
      if (!inclusive_contains(fast_execution, mapped.payload->execution())) {
        continue;
      }
      const swtcon::MappedFinalizeStatus status =
          engine_.discard_mapped(mapped.token);
      if (status == swtcon::MappedFinalizeStatus::kAlreadyScanned) {
        continue;
      }
      if (status != swtcon::MappedFinalizeStatus::kDiscarded) {
        set_color_fault("safe Fast mapped pre-scan discard failed");
        return false;
      }
      remove_terminal_token(mapped.token);
      engine_completions_.push_back(mapped.engine_frame_id);
      color_obligation_count_.fetch_sub(1, std::memory_order_release);
      mapped_token_frames_.erase(mapped_token_frames_.begin() +
                                 static_cast<std::ptrdiff_t>(index - 1));
    }

    auto frame = find_safe_fast_frame(admit.fast_present_seq);
    if (frame == safe_fast_frames_.end()) {
      SafeFastFrame created;
      created.abi_engine_frame_id = admit.engine_frame_id;
      created.present_seq = admit.fast_present_seq;
      created.expected_pieces = admit.fast_piece_count;
      created.pieces.resize(admit.fast_piece_count);
      safe_fast_frames_.push_back(std::move(created));
      frame = std::prev(safe_fast_frames_.end());
    }
    if (frame->abi_engine_frame_id != admit.engine_frame_id ||
        frame->expected_pieces != admit.fast_piece_count ||
        frame->pieces[admit.fast_piece_index].internal_engine_frame_id != 0) {
      set_color_fault("inconsistent safe Fast frame grouping");
      return false;
    }

    const auto execution = admit.payload->execution();
    const std::int32_t width = execution.right - execution.left + 1;
    const std::int32_t height = execution.bottom - execution.top + 1;
    if (width <= 0 || height <= 0 ||
        admit.payload->raw().size() !=
            static_cast<std::size_t>(width) * height) {
      set_color_fault("invalid safe Fast execution payload");
      return false;
    }
    const std::int32_t visible_right =
        std::min(execution.right, kLogicalWidth - 1);
    const std::int32_t visible_bottom =
        std::min(execution.bottom, kLogicalHeight - 1);
    const PlutoRect rect{execution.left, execution.top,
                         visible_right - execution.left + 1,
                         visible_bottom - execution.top + 1};
    auto coverage = std::make_shared<swtcon::FastCoverage>(rect);
    if (!coverage->valid()) {
      set_color_fault("safe Fast coverage allocation failed");
      return false;
    }
    safe_fast_levels_scratch_.resize(static_cast<std::size_t>(rect.width) *
                                     rect.height);
    for (std::int32_t y = 0; y < rect.height; ++y) {
      for (std::int32_t x = 0; x < rect.width; ++x) {
        const std::uint8_t raw =
            admit.payload->raw()[static_cast<std::size_t>(y) *
                                     admit.payload->raw_stride() +
                                 static_cast<std::size_t>(x)];
        safe_fast_levels_scratch_[static_cast<std::size_t>(y) * rect.width +
                                  static_cast<std::size_t>(x)] =
            (raw & 31u) == 7u ? swtcon::kMode7FastWhiteEndpoint
                              : swtcon::kMode7FastBlackEndpoint;
      }
    }

    SafeFastPiece &piece = frame->pieces[admit.fast_piece_index];
    piece.internal_engine_frame_id = admit.safe_fast_engine_id;
    piece.seed_seq = admit.fast_piece_seq;
    piece.index = admit.fast_piece_index;
    piece.payload = std::move(admit.payload);
    piece.coverage = coverage;

    AdmitRequest request;
    request.rect = rect;
    request.mode = 7;
    request.temp_bin = piece.payload->temperature_bin();
    request.levels = safe_fast_levels_scratch_.data();
    request.levels_stride = static_cast<std::size_t>(rect.width);
    request.frame_id = piece.internal_engine_frame_id;
    request.flags = swtcon::kAdmitFlagPenPreview |
                    swtcon::kAdmitFlagNoMappedInvalidation |
                    swtcon::kAdmitFlagFastRailRebase;
    request.fast_coverage = coverage;
    const std::size_t completion_begin = engine_completions_.size();
    swtcon::AdmitOutcome outcome;
    if (!engine_.admit(request, &outcome) || !outcome.accepted) {
      set_color_fault("safe Fast admission rejected");
      return false;
    }
    ++frame->admitted_pieces;
    capture_safe_fast_completions(completion_begin,
                                  /*terminal_build_seq=*/0);
    release_ready_noop_safe_fast_frames();
    return true;
  }

  bool drain_color_admissions() {
    bool admitted_any = false;
    for (;;) {
      // One admission can supersede an unstarted mapped predecessor and emit
      // its discard event. Reconcile that event before selecting the next
      // raw/Fast item from this same drain, so presenter token bookkeeping
      // cannot lag PixelEngine by one admission.
      process_mapped_events();
      ColorAdmit admit;
      bool bypassed = false;
      std::size_t selected_index = 0;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        const std::size_t selected = select_color_lane_index_locked(&bypassed);
        if (selected >= color_lane_.size()) {
          break;
        }
        selected_index = selected;
        admit = std::move(color_lane_[selected]);
        color_lane_.erase(color_lane_.begin() +
                          static_cast<std::ptrdiff_t>(selected));
        if (bypassed && admit.fast_piece_index == 0) {
          ++stat_color_fast_bypasses_;
          const std::uint64_t now_ns = static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::nanoseconds>(
                  std::chrono::steady_clock::now().time_since_epoch())
                  .count());
          if (now_ns >= admit.enqueued_ns) {
            stat_color_fast_bypass_wait_max_us_ =
                std::max(stat_color_fast_bypass_wait_max_us_,
                         (now_ns - admit.enqueued_ns) / 1000u);
          }
        }
      }
      if (admit.payload != nullptr &&
          admit.payload->mode() == XochitlHistoryState::Mode::kFast) {
        const bool fast_admitted = admit_safe_fast(std::move(admit));
        admitted_any = fast_admitted || admitted_any;
        if (!fast_admitted) {
          abandon_safe_fast_present(admit.fast_present_seq,
                                    admit.fast_piece_count,
                                    admit.safe_fast_engine_id);
          break;
        }
        continue;
      }
      {
        // Linearization point for "unstarted": a focus publication that wins
        // this mutex before preparation requeues the immutable raw payload at
        // its original position. Once this check wins, prepare/admit owns the
        // operation and later focus cannot preempt emitted or scanned truth.
        // Digitizer proximity lead time is what normally makes publication
        // win this boundary before contact pixels arrive.
        std::lock_guard<std::mutex> lock(mutex_);
        apply_latest_pen_focus_locked();
        if (pen_focus_blocks_color_admit_locked(admit, steady_now_ns())) {
          color_lane_.insert(color_lane_.begin() +
                                 static_cast<std::ptrdiff_t>(std::min(
                                     selected_index, color_lane_.size())),
                             std::move(admit));
          ++stat_color_pen_focus_truth_deferrals_;
          break;
        }
      }
      const XochitlColorPipeline::PrepareResult prepared =
          color_pipeline_.prepare(*admit.payload);
      if (!prepared) {
        engine_completions_.push_back(admit.engine_frame_id);
        color_obligation_count_.fetch_sub(1, std::memory_order_release);
        set_color_fault("history preparation failed");
        break;
      }
      swtcon::MappedAdmitOutcome outcome;
      const swtcon::MappedAdmitRequest request{
          .operation = prepared.operation,
          .history = &color_pipeline_.history(),
          .temp_bin = admit.payload->temperature_bin(),
          .frame_id = admit.engine_frame_id,
          .retry_cookie = admit.retry_cookie,
      };
      if (engine_.admit_mapped(request, &outcome)) {
        mapped_token_frames_.push_back({outcome.token, admit.engine_frame_id,
                                        admit.retry_cookie, admit.payload});
        admitted_any = true;
        continue;
      }
      if (outcome.status == swtcon::MappedAdmitStatus::kConflictScanned ||
          outcome.status == swtcon::MappedAdmitStatus::kConflictPartial ||
          outcome.status == swtcon::MappedAdmitStatus::kConflictHistoryRegion) {
        // prepare() is intentionally retried only after predecessor terminal
        // confirmation. The raw payload is immutable newest app truth; no
        // timer or pen-up condition participates.
        admit.retry_after_dependency_epoch = color_dependency_epoch_ + 1;
        std::lock_guard<std::mutex> lock(mutex_);
        color_lane_.insert(color_lane_.begin(), std::move(admit));
        break;
      }

      engine_completions_.push_back(admit.engine_frame_id);
      color_obligation_count_.fetch_sub(1, std::memory_order_release);
      set_color_fault("mapped admission rejected");
      break;
    }
    resolve_previously_latched_safe_fast_frames();
    return admitted_any;
  }

  bool drain_admissions() {
    // Strict present-order drain: tile records and large-lane markers share
    // the mailbox FIFO, so cross-lane admission order equals present()
    // order. The engine's newest-wins supersession is only correct
    // under that total order — draining the large lane out of band let an
    // older full-field flash be admitted AFTER newer tile content and
    // resurrect stale scenes on glass. Returns whether anything drained so
    // the engine loop can build IMMEDIATELY when the pipeline slot is free
    // (waiting for the next tick added up to a full scan period of
    // first-ink / first-frame latency).
    bool drained = false;
    while (mailbox_.pop(&mailbox_record_)) {
      drained = true;
      if ((mailbox_record_.request.flags & kAdmitFlagLargeLane) != 0) {
        LargeAdmit large;
        bool have = false;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          if (!large_lane_.empty()) {
            large = std::move(large_lane_.front());
            large_lane_.erase(large_lane_.begin());
            have = true;
          }
        }
        if (have) {
          AdmitRequest request;
          request.rect = large.rect;
          request.mode = large.mode;
          request.temp_bin = large.temp_bin;
          request.levels = large.levels.data();
          request.levels_stride = 0;
          request.frame_id = large.engine_frame_id;
          request.flags = large.admit_flags;
          admit_checked(request);
          // Return the levels buffer to the pool (bounded: the lane depth
          // is capped at large_lane_max).
          std::lock_guard<std::mutex> lock(mutex_);
          if (level_buffer_pool_.size() < config_.large_lane_max) {
            level_buffer_pool_.push_back(std::move(large.levels));
          }
        }
        continue;
      }
      admit_checked(mailbox_record_.request);
    }
    return drained;
  }

  void admit_checked(const AdmitRequest &request) {
    if (!engine_.admit(request)) {
      // Validated at present(); defensive so a rejected piece can never
      // strand its frame_id (counts as an immediately-complete piece).
      // Content is LOST here — dropped must stay 0 in the stats log.
      stat_dropped_pieces_.fetch_add(1, std::memory_order_relaxed);
      if (request.frame_id >= kEngineFrameIdBias) {
        engine_completions_.push_back(request.frame_id);
      }
    }
  }

  void build_frame() {
    // 1-deep pipeline: never build over a published-but-unscanned
    // plane — a tick that raced past the publish was a pause (HOLD flip,
    // counted by the scan); the plane flips on the NEXT tick and fnum
    // stays exactly one phase ahead of the glass, never more.
    if (!config_.dry_run && scan_loop_.ready_slot().pending()) {
      return;
    }
    const std::uint64_t rows_before = emitter_.stats().rows_emitted;
    const std::size_t mapped_event_begin = mapped_events_.size();
    const std::size_t completion_begin = engine_completions_.size();
    const std::uint64_t engine_frame = engine_.frame();
    const auto build_start = std::chrono::steady_clock::now();
    if (!emitter_.begin_frame(build_slot_, build_seq_ + 1)) {
      return; // structurally impossible after configure; defensive
    }
    // The slot's per-tile impulse summary is rebuilt alongside the plane by
    // the engine's fused sweep (impulse sink; double-scan recharges read
    // the summary, never the WC plane).
    summary_store_.begin_slot(build_slot_);
    engine_.set_impulse_sink(summary_store_.slot_impulse_sink(build_slot_),
                             summary_store_.slot_drive_sink(build_slot_));
    engine_.advance(&emitter_);
    engine_.set_impulse_sink(nullptr, nullptr);
    emitter_.end_frame();
    terminal_events_this_build_.clear();
    for (std::size_t i = mapped_event_begin; i < mapped_events_.size(); ++i) {
      if (mapped_events_[i].kind == swtcon::MappedEventKind::kTerminal) {
        terminal_events_this_build_.push_back(mapped_events_[i].token);
      }
    }
    // Build-latency telemetry (ring of recent builds; percentiles at log
    // time): the mission gate is p95 build < the 11.76 ms scan period.
    const auto build_us = std::chrono::duration_cast<std::chrono::microseconds>(
                              std::chrono::steady_clock::now() - build_start)
                              .count();
    build_us_ring_[build_count_ % build_us_ring_.size()] =
        static_cast<std::uint32_t>(std::min<long long>(build_us, 0xffffffffll));
    ++build_count_;
    active_px_peak_ =
        std::max<std::uint64_t>(active_px_peak_, engine_.total_active_px());
    const bool safe_fast_terminal =
        safe_fast_completion_needs_fence(completion_begin);
    if (emitter_.stats().rows_emitted == rows_before && !safe_fast_terminal) {
      capture_safe_fast_completions(completion_begin,
                                    /*terminal_build_seq=*/0);
      release_ready_noop_safe_fast_frames();
      resolve_previously_latched_safe_fast_frames();
      // Nothing driven this frame (e.g. bands still staggered): the slot
      // was not consumed and the scan keeps parking on HOLD — an all-hold
      // plane is never flipped as content.
      return;
    }
    ++build_seq_;
    last_published_content_seq_.store(build_seq_, std::memory_order_release);
    if (first_user_build_seq_ == 0 && engine_frame >= kEngineFrameIdBias &&
        first_user_admission_t_ns_.load(std::memory_order_acquire) != 0) {
      first_user_build_seq_ = build_seq_;
    }
    record_safe_fast_drive_build(engine_frame, build_seq_);
    capture_safe_fast_completions(completion_begin, build_seq_);
    release_ready_noop_safe_fast_frames();
    resolve_previously_latched_safe_fast_frames();
    if (!terminal_events_this_build_.empty()) {
      mapped_terminal_fences_.push_back(
          {build_seq_, terminal_events_this_build_});
      mapped_terminal_count_.fetch_add(1, std::memory_order_release);
    }
    if (!config_.dry_run) {
      scan_loop_.ready_slot().publish(static_cast<std::uint32_t>(build_slot_),
                                      build_seq_);
    } else {
      // Dry-run's completed build is its virtual scan boundary. Exact mapped
      // truth and safe Fast use the same post-boundary commit path as the
      // device; neither may seed while merely building a terminal plane.
      last_known_safe_scan_seq_ = build_seq_;
      (void)resolve_safe_fast_latch(build_seq_, true);
      resolve_previously_latched_safe_fast_frames();
      if (!terminal_events_this_build_.empty()) {
        finalize_terminal_fence(mapped_terminal_fences_.size() - 1, true);
      }
      last_resolved_content_seq_.store(build_seq_, std::memory_order_release);
      handoff_cv_.notify_all();
    }
    build_slot_ = (build_slot_ + 1) % kActivePhaseSlots;
  }

  void publish_engine_state() {
    engine_busy_flag_.store(engine_busy(), std::memory_order_release);
  }

  // Double-scan accounting — SUMMARY path, no plane reads:
  // the rescanned plane's exact per-tile impulse (accumulated at build
  // time by ImpulseSummaryEmitter) is charged x extra into the DC ledger's
  // aggregate rescan account, and every tile the plane drives takes
  // k_dscan x extra stress. The old path read the full 1.24 MB
  // write-combined dumb buffer back on the engine thread (tens of ms per
  // gap) and livelocked the device under vblank-sequence jitter. HOLD
  // rescans never reach here (impulse-free by construction; the scan
  // exempts them). Caller has already validated slot_seq == engine_seq.
  void recharge_double_scan(std::size_t slot, std::uint64_t extra) {
    auto &dc = engine_.dc_ledger();
    const std::int32_t *impulse = summary_store_.slot_impulse(slot);
    const std::uint8_t *drive = summary_store_.slot_drive(slot);
    const std::size_t tiles = dc.tile_count();
    for (std::size_t tile = 0; tile < tiles; ++tile) {
      if (drive[tile] == 0) {
        continue; // no drive ops in this tile on that plane
      }
      dc.charge_rescan(tile, static_cast<std::int64_t>(impulse[tile]) *
                                 static_cast<std::int64_t>(extra));
      dc.charge_double_scan(tile, extra);
    }
  }

  void flush_user_completions() {
    if (engine_completions_.empty()) {
      return;
    }
    fired_frames_.clear();
    bool idle_now = false;
    bool deliver_callbacks = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (const std::uint64_t engine_frame_id : engine_completions_) {
        if (engine_frame_id < kEngineFrameIdBias) {
          continue;
        }
        const std::uint64_t frame_id = engine_frame_id - kEngineFrameIdBias;
        PendingFrameSlot *slot = find_pending_frame_slot(frame_id);
        if (slot == nullptr) {
          continue; // stray (piece settled defensively elsewhere)
        }
        if (--slot->bookkeeping.remaining == 0) {
          ++stat_updates_;
          if (slot->bookkeeping.refresh_class == kPlutoRefreshFull) {
            ++stat_fulls_;
          }
          if (engine_.dc_ledger().balanced_mode(slot->bookkeeping.mode)) {
            ++stat_gc16_;
          }
          erase_pending_frame(slot);
          fired_frames_.push_back(frame_id);
        }
      }
      deliver_callbacks = callback_ != nullptr && !fired_frames_.empty();
      if (deliver_callbacks) {
        // Publish the callback fence in the same critical section that removes
        // the final pending frame. wait_idle can observe neither an untracked
        // gap nor a half-delivered completion.
        completion_callbacks_pending_ += fired_frames_.size();
      }
      idle_now =
          pending_frame_count_ == 0 && completion_callbacks_pending_ == 0;
    }
    engine_completions_.clear();
    // ABI contract: completion callbacks fire on an internal presenter
    // thread and the callee must only enqueue — never block.
    if (deliver_callbacks) {
      for (const std::uint64_t frame_id : fired_frames_) {
        deliver_fenced_completion(frame_id);
      }
    }
    const bool fired_any = !fired_frames_.empty();
    if (idle_now && fired_any) {
      idle_cv_.notify_all();
    }
    // This vector is delivery scratch, not durable outstanding work. Keeping
    // the last delivered ids until a later completion made the handoff audit
    // spuriously reject an otherwise settled engine.
    fired_frames_.clear();
  }

  void update_stats_snapshot() {
    const swtcon::PixelEngineStats &engine_stats = engine_.stats();
    swtcon::ScanLoopStats scan_stats{};
    if (!config_.dry_run && scan_loop_.configured()) {
      scan_stats = scan_loop_.stats();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    stats_snapshot_.struct_size = sizeof(stats_snapshot_);
    stats_snapshot_.admissions = engine_stats.admissions;
    stats_snapshot_.absorbed = engine_stats.tiles_absorbed;
    stats_snapshot_.parked = engine_stats.tiles_parked;
    stats_snapshot_.retargets = engine_stats.tiles_retargeted;
    stats_snapshot_.cancels = engine_stats.truncations;
    stats_snapshot_.neutral_frames = scan_stats.hold_flips;
    stats_snapshot_.double_scans = scan_stats.double_scans;
    stats_snapshot_.hold_rescans = scan_stats.hold_rescans;
    stats_snapshot_.dc_saturations = engine_.dc_ledger().saturations();
    stats_snapshot_.pauses = engine_stats.pauses;
    stats_snapshot_.active_px_peak = active_px_peak_;
    stats_snapshot_.cold_clear_mode = cold_clear_mode_;
    stats_snapshot_.pen_cross_mode_preemptions =
        engine_stats.pen_cross_mode_preemptions;
    stats_snapshot_.color_enabled = color_enabled_ ? 1u : 0u;
    stats_snapshot_.mapped_admissions = engine_stats.mapped_admissions;
    stats_snapshot_.mapped_started = engine_stats.mapped_started;
    stats_snapshot_.mapped_queued = engine_stats.mapped_queued;
    stats_snapshot_.mapped_terminals = engine_stats.mapped_terminals;
    stats_snapshot_.mapped_confirmed = engine_stats.mapped_confirmed;
    stats_snapshot_.mapped_discarded = engine_stats.mapped_discarded;
    stats_snapshot_.mapped_invalidated = engine_stats.mapped_invalidated;
    stats_snapshot_.mapped_poison_regions =
        engine_.mapped_poison_regions().size();
    stats_snapshot_.color_fast_bypasses = stat_color_fast_bypasses_;
    stats_snapshot_.color_fast_bypass_wait_max_us =
        stat_color_fast_bypass_wait_max_us_;
  }

  // One diagnostic line per stats_log_s seconds (engine thread; 0 = off):
  // enough to distinguish content loss (dropped != 0 — a bug), heavy
  // supersession/parking (rapid overlap), DC saturation and scan health
  // from a device journal without a debugger attached.
  void maybe_log_stats() {
    if (config_.stats_log_s <= 0) {
      return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (stats_log_next_ == std::chrono::steady_clock::time_point{}) {
      stats_log_next_ = now + std::chrono::seconds(config_.stats_log_s);
      return;
    }
    if (now < stats_log_next_) {
      return;
    }
    stats_log_next_ = now + std::chrono::seconds(config_.stats_log_s);
    const swtcon::PixelEngineStats &es = engine_.stats();
    swtcon::ScanLoopStats scan_stats{};
    if (!config_.dry_run && scan_loop_.configured()) {
      scan_stats = scan_loop_.stats();
    }
    std::uint64_t completions = 0;
    std::uint64_t color_queue_peak = 0;
    std::uint64_t color_fast_peak = 0;
    std::uint64_t color_truth_peak = 0;
    std::uint64_t color_fast_reserve_uses = 0;
    std::uint64_t color_fast_reserve_declines = 0;
    std::uint64_t pen_truth_input_rects = 0;
    std::uint64_t pen_truth_grouped_tiles = 0;
    std::uint64_t pen_truth_masked_lanes = 0;
    std::uint64_t pen_truth_groups_per_request_max = 0;
    std::array<std::uint32_t, 256> color_sorted{};
    std::size_t color_samples = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      completions = stat_updates_;
      color_queue_peak = stat_color_queue_peak_;
      color_fast_peak = stat_color_fast_obligation_peak_;
      color_truth_peak = stat_color_truth_obligation_peak_;
      color_fast_reserve_uses = stat_color_fast_reserve_uses_;
      color_fast_reserve_declines = stat_color_fast_reserve_declines_;
      pen_truth_input_rects = stat_pen_truth_input_rects_;
      pen_truth_grouped_tiles = stat_pen_truth_grouped_tiles_;
      pen_truth_masked_lanes = stat_pen_truth_masked_lanes_;
      pen_truth_groups_per_request_max = stat_pen_truth_groups_per_request_max_;
      color_samples = static_cast<std::size_t>(std::min<std::uint64_t>(
          color_preprocess_count_, color_preprocess_us_ring_.size()));
      std::copy_n(color_preprocess_us_ring_.begin(), color_samples,
                  color_sorted.begin());
    }
    // Build-latency percentiles over the recent-builds ring (engine-thread
    // state; computed only here — the hot path just stamps the ring).
    std::uint32_t build_p50_us = 0;
    std::uint32_t build_p95_us = 0;
    std::uint32_t build_max_us = 0;
    const std::size_t build_samples = static_cast<std::size_t>(
        std::min<std::uint64_t>(build_count_, build_us_ring_.size()));
    if (build_samples > 0) {
      std::array<std::uint32_t, 256> sorted{};
      std::copy_n(build_us_ring_.begin(), build_samples, sorted.begin());
      const auto nth = [&](std::size_t rank) {
        std::nth_element(
            sorted.begin(), sorted.begin() + static_cast<std::ptrdiff_t>(rank),
            sorted.begin() + static_cast<std::ptrdiff_t>(build_samples));
        return sorted[rank];
      };
      build_p50_us = nth(build_samples / 2);
      build_p95_us = nth((build_samples * 95) / 100);
      build_max_us = *std::max_element(
          sorted.begin(),
          sorted.begin() + static_cast<std::ptrdiff_t>(build_samples));
    }
    std::uint32_t color_p50_us = 0;
    std::uint32_t color_p95_us = 0;
    std::uint32_t color_max_us = 0;
    if (color_samples > 0) {
      std::sort(color_sorted.begin(),
                color_sorted.begin() +
                    static_cast<std::ptrdiff_t>(color_samples));
      color_p50_us = color_sorted[color_samples / 2];
      color_p95_us = color_sorted[(color_samples * 95) / 100];
      color_max_us = color_sorted[color_samples - 1];
    }
    const std::uint64_t color_total_current =
        color_obligation_count_.load(std::memory_order_acquire);
    const std::uint64_t color_fast_current =
        color_fast_obligation_count_.load(std::memory_order_acquire);
    const std::uint64_t color_truth_current =
        color_total_current >= color_fast_current
            ? color_total_current - color_fast_current
            : 0;
    std::fprintf(
        stderr,
        "swtcon stats: admissions=%llu absorbed=%llu parked=%llu "
        "re_admits=%llu superseded=%llu clipped=%llu dropped=%llu "
        "completions=%llu dc_saturations=%llu double_scans=%llu "
        "hold_rescans=%llu neutral_frames=%llu pauses=%llu "
        "active_px_peak=%llu pen_preempt=%llu builds=%llu "
        "build_p50_us=%u build_p95_us=%u "
        "build_max_us=%u color=%u mapped_admit=%llu mapped_start=%llu "
        "mapped_queue=%llu mapped_terminal=%llu mapped_confirm=%llu "
        "mapped_discard=%llu mapped_invalidate=%llu mapped_fast_park=%llu "
        "poison=%zu "
        "color_reconcile=%llu color_fault=%llu color_queue_peak=%llu "
        "color_fast=%llu color_truth=%llu color_fast_peak=%llu "
        "color_truth_peak=%llu fast_reserve_use=%llu "
        "fast_reserve_decline=%llu "
        "color_preprocess_p50_us=%u color_preprocess_p95_us=%u "
        "color_preprocess_max_us=%u pen_truth_rects=%llu "
        "pen_truth_tiles=%llu pen_truth_lanes=%llu "
        "pen_truth_group_max=%llu\n",
        static_cast<unsigned long long>(es.admissions),
        static_cast<unsigned long long>(es.tiles_absorbed),
        static_cast<unsigned long long>(es.tiles_parked),
        static_cast<unsigned long long>(es.parked_wakes),
        static_cast<unsigned long long>(es.pieces_superseded),
        static_cast<unsigned long long>(es.pieces_clipped),
        static_cast<unsigned long long>(
            stat_dropped_pieces_.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(completions),
        static_cast<unsigned long long>(engine_.dc_ledger().saturations()),
        static_cast<unsigned long long>(scan_stats.double_scans),
        static_cast<unsigned long long>(scan_stats.hold_rescans),
        static_cast<unsigned long long>(scan_stats.hold_flips),
        static_cast<unsigned long long>(es.pauses),
        static_cast<unsigned long long>(active_px_peak_),
        static_cast<unsigned long long>(es.pen_cross_mode_preemptions),
        static_cast<unsigned long long>(build_count_), build_p50_us,
        build_p95_us, build_max_us, color_enabled_ ? 1u : 0u,
        static_cast<unsigned long long>(es.mapped_admissions),
        static_cast<unsigned long long>(es.mapped_started),
        static_cast<unsigned long long>(es.mapped_queued),
        static_cast<unsigned long long>(es.mapped_terminals),
        static_cast<unsigned long long>(es.mapped_confirmed),
        static_cast<unsigned long long>(es.mapped_discarded),
        static_cast<unsigned long long>(es.mapped_invalidated),
        static_cast<unsigned long long>(es.mapped_fast_parks),
        engine_.mapped_poison_regions().size(),
        static_cast<unsigned long long>(
            stat_color_reconciles_.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            stat_color_faults_.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(color_queue_peak),
        static_cast<unsigned long long>(color_fast_current),
        static_cast<unsigned long long>(color_truth_current),
        static_cast<unsigned long long>(color_fast_peak),
        static_cast<unsigned long long>(color_truth_peak),
        static_cast<unsigned long long>(color_fast_reserve_uses),
        static_cast<unsigned long long>(color_fast_reserve_declines),
        color_p50_us, color_p95_us, color_max_us,
        static_cast<unsigned long long>(pen_truth_input_rects),
        static_cast<unsigned long long>(pen_truth_grouped_tiles),
        static_cast<unsigned long long>(pen_truth_masked_lanes),
        static_cast<unsigned long long>(pen_truth_groups_per_request_max));
  }

  void check_device_lost() {
    if (config_.dry_run || !scan_expected_.load(std::memory_order_acquire)) {
      return; // dry run, or open() has not started the scan yet
    }
    if (!scan_loop_.running()) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!stopping_ && !device_lost_) {
        device_lost_ = true;
        pen_focus_accepting_.store(false, std::memory_order_release);
        std::fprintf(stderr, "swtcon scan loop stopped: %s\n",
                     device_ != nullptr ? device_->last_error().c_str() : "");
      }
      idle_cv_.notify_all();
    }
  }

  Config config_;
  swtcon::RealRailsFs rails_fs_;
  swtcon::RealTemperatureFs temperature_fs_;
  swtcon::SwtconTemperatureMonitor temperature_{&temperature_fs_};
  // Producer-thread confined by present_mutex_. Every payload is legalized
  // and tagged with this sticky bin before crossing the mailbox.
  swtcon::TemperatureBinSelector admission_bin_selector_;
  swtcon::RealWaveformFileReader waveform_reader_;
  swtcon::SwtconWaveform waveform_;
  swtcon::XochitlColorPipeline color_pipeline_;
  bool color_enabled_ = false;
  // Content-target legalization maps, mode-major by temp bin (built once at
  // open(), immutable afterwards — safe to read from the scheduler thread).
  std::vector<std::array<std::uint8_t, 32>> legal_target_maps_;
  int legal_map_ntemp_ = 0;
  // Serialized producer-side conversion scratch, sized once in open().
  std::mutex present_mutex_;
  std::vector<std::uint8_t> piece_levels_scratch_;
  // Recycled LargeAdmit level buffers (guarded by mutex_): producer takes,
  // engine drain returns. Bounded by large_lane_max.
  std::vector<std::vector<std::uint8_t>> level_buffer_pool_;
  std::unique_ptr<swtcon::DrmSwtconDevice> device_;

  // Frame-path components. Engine/emitter state is engine-thread confined;
  // the mailbox push side and the scan-ready slot are the lock-free seams.
  PixelEngine engine_;
  PhaseEmitter emitter_;
  AdmissionMailbox mailbox_;
  ScanLoop scan_loop_;
  SteadyScanClock steady_clock_;

  // Presenter glue state (mutex_): wake signals, completion bookkeeping,
  // stats snapshot. NEVER holds the mutex across engine plane work.
  mutable std::mutex mutex_;
  std::condition_variable engine_cv_;
  std::condition_variable idle_cv_;
  std::condition_variable glass_cv_; // TEST-ONLY snapshot handshake
  std::condition_variable handoff_cv_;
  GlassRequest *glass_request_ = nullptr; // guarded by mutex_
  std::shared_ptr<HandoffCaptureRequest> handoff_capture_request_;
  bool stopping_ = false;
  bool device_lost_ = false;
  std::uint32_t ticks_pending_ = 0;
  bool admissions_signal_ = false;
  std::vector<LargeAdmit> large_lane_;
  std::vector<ColorAdmit> color_lane_;
  std::array<AtomicPenFocusSlot, kPenFocusMailboxCapacity> pen_focus_mailbox_{};
  std::atomic<std::uint64_t> pen_focus_mailbox_write_{0};
  std::atomic<std::uint64_t> pen_focus_mailbox_published_{0};
  std::atomic<bool> pen_focus_wake_{false};
  std::atomic<bool> pen_focus_accepting_{false};
  // Physical metadata only. Published lock-free from InkThread, then applied
  // by the engine under mutex_ before raw mapped preparation. No pixel or
  // damage is stored here.
  std::uint64_t applied_pen_focus_ticket_ = 0;
  bool pen_focus_active_ = false;
  bool pen_focus_contact_ = false;
  PlutoRect pen_focus_raw_rect_{};
  PlutoRect pen_focus_rect_{};
  std::uint64_t pen_focus_sequence_ = 0;
  std::uint64_t pen_focus_motion_generation_ = 0;
  std::uint64_t pen_focus_geometry_changed_ns_ = 0;
  std::vector<std::uint64_t> reserved_safe_fast_engine_ids_;
  std::uint64_t next_safe_fast_engine_id_ =
      std::numeric_limits<std::uint64_t>::max();
  std::vector<ScanFeedback> scan_feedback_events_;
  std::vector<DoubleScanEvent> double_scan_events_;
  std::array<PendingFrameSlot, kPendingFrameCapacity> pending_frames_{};
  std::size_t pending_frame_count_ = 0;
  // Guarded by mutex_. A frame leaves pending_frames_ before its callback runs,
  // so wait_idle must include this second half of the completion handoff.
  std::size_t completion_callbacks_pending_ = 0;
  PlutoGallery3DrmDebugStats stats_snapshot_{};
  std::uint64_t stat_updates_ = 0;
  std::uint64_t stat_gc16_ = 0;
  std::uint64_t stat_fulls_ = 0;

  std::atomic<bool> cold_clear_done_{false};
  std::atomic<bool> engine_busy_flag_{false};
  std::atomic<std::uint32_t> pending_pauses_{0};
  std::atomic<bool> scan_expected_{false};
  std::atomic<std::size_t> mapped_terminal_count_{0};
  std::atomic<std::size_t> color_obligation_count_{0};
  std::atomic<std::size_t> color_fast_obligation_count_{0};
  // Pieces whose content was LOST (mailbox/engine rejection with the
  // completion still settled). Must stay 0; logged by maybe_log_stats.
  std::atomic<std::uint64_t> stat_dropped_pieces_{0};
  std::atomic<std::uint64_t> stat_color_faults_{0};
  std::atomic<std::uint64_t> stat_color_reconciles_{0};

  // Engine-thread-only state.
  std::size_t build_slot_ = 0;
  std::uint64_t build_seq_ = 0;
  std::uint64_t active_px_peak_ = 0;
  std::chrono::steady_clock::time_point stats_log_next_{};
  std::vector<std::uint64_t> engine_completions_;
  std::vector<std::uint64_t> fired_frames_;
  std::vector<DoubleScanEvent> double_scan_scratch_;
  std::vector<ScanFeedback> scan_feedback_scratch_;
  std::vector<swtcon::MappedEvent> mapped_events_;
  std::vector<MappedTokenFrame> mapped_token_frames_;
  std::vector<MappedTerminalFence> mapped_terminal_fences_;
  std::vector<SafeFastFrame> safe_fast_frames_;
  std::vector<std::uint64_t> safe_fast_ready_scratch_;
  std::vector<const SafeFastPiece *> safe_fast_piece_order_scratch_;
  std::vector<std::uint8_t> safe_fast_levels_scratch_;
  std::vector<std::uint8_t> fast_filtered_scratch_;
  std::vector<std::uint8_t> fast_confirmed_scratch_;
  std::vector<std::uint8_t> fast_newer_coverage_scratch_;
  std::vector<std::uint64_t> fast_seed_seq_;
  std::uint64_t next_fast_present_seq_ = 1;   // producer-thread confined
  std::uint64_t next_fast_piece_seq_ = 1;     // producer-thread confined
  std::uint64_t next_color_retry_cookie_ = 1; // producer-thread confined
  std::uint64_t last_known_safe_scan_seq_ = 0;
  std::uint64_t bypass_fast_present_seq_ = 0;
  std::vector<swtcon::MappedOperationToken> terminal_events_this_build_;
  std::uint64_t color_dependency_epoch_ = 0;
  std::vector<std::uint8_t> cold_levels_;
  ColdClearPhase cold_clear_phase_ = ColdClearPhase::kIdle;
  int cold_clear_mode_ = -1;
  int cold_clear_temp_bin_ = 0;
  std::uint64_t cold_clear_completion_target_ = 0;
  bool cold_clear_waiting_latch_ = false;
  std::uint64_t cold_clear_latch_target_ = 0;
  AdmissionMailboxRecord mailbox_record_;
  // Per-slot per-tile impulse summaries (double-scan recharge source),
  // filled by the engine's fused sweep through set_impulse_sink.
  ImpulseSummaryStore summary_store_;
  // Build-latency telemetry: ring of recent build durations (us), cheap
  // percentiles computed only at stats-log time.
  std::array<std::uint32_t, 256> build_us_ring_{};
  std::uint64_t build_count_ = 0;
  std::array<std::uint32_t, 256> color_preprocess_us_ring_{};
  std::uint64_t color_preprocess_count_ = 0;
  std::uint64_t stat_color_queue_peak_ = 0;
  std::uint64_t stat_color_fast_bypasses_ = 0;
  std::uint64_t stat_color_fast_bypass_wait_max_us_ = 0;
  std::uint64_t stat_color_fast_obligation_peak_ = 0;
  std::uint64_t stat_color_truth_obligation_peak_ = 0;
  std::uint64_t stat_color_fast_reserve_uses_ = 0;
  std::uint64_t stat_color_fast_reserve_declines_ = 0;
  std::uint64_t stat_color_pen_focus_updates_ = 0;
  std::uint64_t stat_color_pen_focus_clears_ = 0;
  std::uint64_t stat_color_pen_focus_truth_deferrals_ = 0;
  std::uint64_t stat_color_pen_focus_disjoint_bypasses_ = 0;
  std::uint64_t stat_pen_truth_input_rects_ = 0;
  std::uint64_t stat_pen_truth_grouped_tiles_ = 0;
  std::uint64_t stat_pen_truth_masked_lanes_ = 0;
  std::uint64_t stat_pen_truth_groups_per_request_max_ = 0;

  // Transactional warm-display handoff. The incoming core is provisional
  // until renderer confirmation. Outgoing state is frozen and captured by
  // stage_handoff(), then atomically written only after close's final audit.
  HandoffExecutionBackend handoff_backend_ =
      HandoffExecutionBackend::kProductionDrm;
  GlassHandoffIdentity handoff_identity_{};
  GlassHandoffLease handoff_lease_{};
  bool handoff_identity_valid_ = false;
  bool handoff_core_seeded_ = false;
  bool handoff_unlinked_ = false;
  bool handoff_frozen_ = false;
  bool handoff_invalidation_failed_ = false; // guarded by mutex_
  HandoffDecision handoff_decision_ = HandoffDecision::kNone;
  std::uint32_t handoff_chain_next_ = 0;
  GlassHandoffClaim incoming_handoff_claim_{};
  GlassHandoffRendererInfo incoming_renderer_info_{};
  std::vector<std::uint8_t> incoming_renderer_payload_;
  std::optional<GlassHandoffBundle> staged_handoff_;
  std::atomic<std::uint64_t> last_published_content_seq_{0};
  std::atomic<std::uint64_t> last_resolved_content_seq_{0};
  std::uint64_t presenter_open_t_ns_ = 0;
  std::atomic<std::uint64_t> first_user_admission_t_ns_{0};
  std::uint64_t first_user_build_seq_ = 0;  // engine-thread confined
  bool first_visible_latch_logged_ = false; // engine-thread confined
  std::atomic<bool> warm_handoff_accepted_{false};

  // Snapshot mirror (CLI screenshots), on its own mutex.
  std::mutex snapshot_mutex_;
  std::vector<std::uint8_t> frame_;

  std::vector<std::vector<std::uint16_t>> host_slots_; // dry-run targets

  PlutoPresentCompleteCallback callback_ = nullptr;
  void *callback_user_data_ = nullptr;
  std::thread engine_thread_;
  std::thread mode_lab_thread_;
};

PlutoStatus gallery3_drm_open(const PlutoPresenterConfig *config,
                        PlutoPresenter **out_presenter) {
  if (out_presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  *out_presenter = nullptr;
  auto *presenter = new (std::nothrow) Gallery3DrmPresenter();
  if (presenter == nullptr) {
    return kPlutoStatusInternal;
  }
  try {
    const PlutoStatus status = presenter->open(config);
    if (status != kPlutoStatusOk) {
      delete presenter;
      return status;
    }
  } catch (...) {
    delete presenter;
    return kPlutoStatusInternal;
  }
  *out_presenter = reinterpret_cast<PlutoPresenter *>(presenter);
  return kPlutoStatusOk;
}

void gallery3_drm_close(PlutoPresenter *presenter) {
  auto *swtcon = reinterpret_cast<Gallery3DrmPresenter *>(presenter);
  delete swtcon;
}

PlutoStatus gallery3_drm_info(PlutoPresenter *presenter, PlutoDisplayInfo *out_info) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->info(out_info);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus gallery3_drm_present(PlutoPresenter *presenter,
                           const PlutoPresentRequest *request) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->present(request);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

bool gallery3_drm_ready(PlutoPresenter *presenter, PlutoRefreshClass refresh_class) {
  if (presenter == nullptr) {
    return false;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->ready(
        refresh_class);
  } catch (...) {
    return false;
  }
}

PlutoStatus gallery3_drm_wait_idle(PlutoPresenter *presenter,
                             std::uint32_t timeout_ms) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->wait_idle(
        timeout_ms);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus gallery3_drm_snapshot(PlutoPresenter *presenter,
                            PlutoSurface *out_surface) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->snapshot(
        out_surface);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus gallery3_drm_set_pen_focus(PlutoPresenter *presenter,
                                 const PlutoPenFocus *focus) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->set_pen_focus(
        focus);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus gallery3_drm_stage_handoff(PlutoPresenter *presenter,
                                 const PlutoHandoffPayload *payload,
                                 std::uint32_t timeout_ms) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->stage_handoff(
        payload, timeout_ms);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus gallery3_drm_get_handoff(PlutoPresenter *presenter,
                               PlutoHandoffPayload *out_payload) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->get_handoff(
        out_payload);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus gallery3_drm_confirm_handoff(PlutoPresenter *presenter, bool accepted) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->confirm_handoff(
        accepted);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

const PlutoPresenterOps kGallery3DrmOps{
    sizeof(PlutoPresenterOps),
    "gallery3_drm",
    gallery3_drm_open,
    gallery3_drm_close,
    gallery3_drm_info,
    gallery3_drm_present,
    gallery3_drm_ready,
    gallery3_drm_wait_idle,
    gallery3_drm_snapshot,
    gallery3_drm_set_pen_focus,
    gallery3_drm_stage_handoff,
    gallery3_drm_get_handoff,
    gallery3_drm_confirm_handoff,
};

} // namespace

namespace swtcon {

void set_drm_interface_for_testing(std::unique_ptr<DrmInterface> drm) {
  test_drm_interface_slot() = std::move(drm);
}

bool color_handoff_profile_matches_for_testing(
    int width, int height, int engine_stride, std::uint32_t tile_px,
    int history_stride, int history_rows, std::string_view machine,
    std::string_view soc) {
  return find_color_handoff_profile(width, height, engine_stride, tile_px,
                                    history_stride, history_rows, machine, soc,
                                    true) != nullptr;
}

bool production_handoff_path_is_secure_tmpfs_for_testing(
    const std::string &path) {
  return production_handoff_path_is_secure_tmpfs(path);
}

bool debug_glass_for_testing(PlutoPresenter *presenter,
                             std::vector<std::uint8_t> *out_levels,
                             int *out_width, int *out_height, int *out_stride) {
  if (presenter == nullptr) {
    return false;
  }
  return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->debug_glass(
      out_levels, out_width, out_height, out_stride);
}

bool debug_dc_for_testing(PlutoPresenter *presenter,
                          std::vector<std::int32_t> *out_rescan,
                          std::vector<std::uint16_t> *out_stress,
                          std::uint32_t *out_tile_cols) {
  if (presenter == nullptr) {
    return false;
  }
  return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->debug_dc(
      out_rescan, out_stress, out_tile_cols);
}

bool debug_color_history_for_testing(PlutoPresenter *presenter, int x, int y,
                                     std::uint16_t *out_a,
                                     std::uint16_t *out_b) {
  if (presenter == nullptr) {
    return false;
  }
  return reinterpret_cast<Gallery3DrmPresenter *>(presenter)->debug_color_history(
      x, y, out_a, out_b);
}

} // namespace swtcon

} // namespace pluto

extern "C" {

const PlutoPresenterOps *pluto_gallery3_drm_presenter_ops(void) {
  return &pluto::kGallery3DrmOps;
}

PlutoStatus
pluto_gallery3_drm_presenter_debug_stats(PlutoPresenter *presenter,
                                   PlutoGallery3DrmDebugStats *out_stats) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<pluto::Gallery3DrmPresenter *>(presenter)
        ->debug_stats(out_stats);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

} // extern "C"
