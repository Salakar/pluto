#include "compositor/software_compositor.h"

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>

#include "compositor/frame_recording.h"
#include "presenter/presenter_contract.h"
#include "renderer/quantize.h"
#include "renderer/rect_utils.h"
#include "runtime/health_file.h"

namespace pluto {
namespace {

static_assert(sizeof(PlutoRect) == 16,
              "frame recording requires four packed 32-bit rectangle fields");

uint64_t monotonic_us() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(
             clock::now().time_since_epoch())
      .count();
}

constexpr uint32_t kBlinkRailCycles = 1;
constexpr uint32_t kBleachRailCycles = 2;
constexpr uint32_t kBlinkThenBleachRailCycles =
    kBlinkRailCycles + kBleachRailCycles;
constexpr uint32_t kFactoryResetRailCycles = 5;
constexpr uint64_t kPixelResetTimeoutUs = 15'000'000;
constexpr uint64_t kPixelResetAbortTimeoutUs = 5'000'000;
constexpr uint32_t kPixelResetShutdownTimeoutMs = 25'000;

// Publish in the target directory so rename(2) is atomic. The temporary file
// is never observed at |path|, and a stale marker from an interrupted prior
// session is replaced as one namespace operation.
bool atomic_publish_ready_file(const std::string &path, int *error_code) {
  std::string temporary = path + ".tmp.XXXXXX";
  std::vector<char> mutable_path(temporary.begin(), temporary.end());
  mutable_path.push_back('\0');

  const int fd = ::mkstemp(mutable_path.data());
  if (fd < 0) {
    if (error_code != nullptr) {
      *error_code = errno;
    }
    return false;
  }
  (void)::fcntl(fd, F_SETFD, FD_CLOEXEC);

  static constexpr char k_marker[] = "ready\n";
  size_t written = 0;
  int saved_errno = 0;
  while (written < sizeof(k_marker) - 1) {
    const ssize_t count =
        ::write(fd, k_marker + written, sizeof(k_marker) - 1 - written);
    if (count > 0) {
      written += static_cast<size_t>(count);
      continue;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    saved_errno = count == 0 ? EIO : errno;
    break;
  }
  if (saved_errno == 0 && ::fsync(fd) != 0) {
    saved_errno = errno;
  }
  if (::close(fd) != 0 && saved_errno == 0) {
    saved_errno = errno;
  }
  if (saved_errno == 0 && ::rename(mutable_path.data(), path.c_str()) != 0) {
    saved_errno = errno;
  }
  if (saved_errno != 0) {
    (void)::unlink(mutable_path.data());
    if (error_code != nullptr) {
      *error_code = saved_errno;
    }
    return false;
  }
  return true;
}

PlutoRect flutter_rect_to_pluto(const FlutterRect &rect) {
  // floor the origin and ceil the extent: truncating fractional paint bounds
  // under-covers the painted pixels and the damage diff then misses them.
  const int32_t left = static_cast<int32_t>(std::floor(rect.left));
  const int32_t top = static_cast<int32_t>(std::floor(rect.top));
  const int32_t right = static_cast<int32_t>(std::ceil(rect.right));
  const int32_t bottom = static_cast<int32_t>(std::ceil(rect.bottom));
  return PlutoRect{left, top, right - left, bottom - top};
}

bool layer_is_root_backing_store(const FlutterLayer *layer) {
  if (layer == nullptr || layer->struct_size < sizeof(FlutterLayer) ||
      layer->type != kFlutterLayerContentTypeBackingStore ||
      layer->backing_store == nullptr ||
      layer->backing_store->type != kFlutterBackingStoreTypeSoftware2) {
    return false;
  }
  return layer->offset.x == 0.0 && layer->offset.y == 0.0;
}

bool env_flag_enabled(const char *name) {
  const char *value = std::getenv(name);
  return value != nullptr && value[0] != '\0' && value[0] != '0';
}

// ---- PLUTO_RECORD_FRAMES stream ----------------------------------------
// Simple binary capture of every submitted PlutoFramePacket for the replay
// harness (tools/renderer_replay). Host-endian (little-endian on every
// supported host), tightly packed:
//
//   file   := "PLFR" u32 | frame*
//   frame  := "FRM0" u32 | frame_bytes u32
//           | presentation_time_ns u64
//           | width u32 | height u32
//           | format u32 (PlutoPixelFormat)
//           | did_update u32 (0|1)
//           | paint_bounds_count u32
//           | payload_bytes u32 (width*bpp*height when did_update, else 0)
//           | paint_bounds: count x (x i32, y i32, w i32, h i32)
//           | payload bytes (tight rows of width*bpp)
//           | crc32 u32 (all frame bytes preceding this field)
//
// Idle frames (did_update == false) are recorded header-only so replay
// preserves the settle/idle cadence.

bool record_write(std::FILE *file, const void *data, size_t size) {
  return std::fwrite(data, 1, size, file) == size;
}

bool record_write_u32(std::FILE *file, uint32_t value) {
  return record_write(file, &value, sizeof(value));
}

bool record_write_crc(std::FILE *file, const void *data, size_t size,
                      uint32_t *crc) {
  *crc = frame_recording::crc32_update(*crc, data, size);
  return record_write(file, data, size);
}

bool record_write_u32_crc(std::FILE *file, uint32_t value, uint32_t *crc) {
  return record_write_crc(file, &value, sizeof(value), crc);
}

bool record_write_u64_crc(std::FILE *file, uint64_t value, uint32_t *crc) {
  return record_write_crc(file, &value, sizeof(value), crc);
}

// Damage-merge policy for the scheduler feed: union when overlap makes
// merging free or the gap is small, then merge the cheapest pairs down to
// the cap. Rects stay exact post-quantize (no alignment padding).
constexpr int32_t k_merge_gap_px = 16;
constexpr size_t k_max_damage_rects = 256;
constexpr uint32_t k_rotation_wait_idle_timeout_ms = 5000;
constexpr uint64_t k_terminal_pen_hint_retention_us = 250'000;
// One short scan/frame bridge after range exit. Active hover/contact is held
// explicitly until its terminal hint; this finite tail only protects the
// app-rendered cursor erase from a completion-driven mapped-truth race.
constexpr uint64_t k_pen_focus_release_lease_us = 24'000;

bool rect_contains(const PlutoRect &outer, const PlutoRect &inner) {
  return inner.x >= outer.x && inner.y >= outer.y &&
         pluto::rect_right(inner) <= pluto::rect_right(outer) &&
         pluto::rect_bottom(inner) <= pluto::rect_bottom(outer);
}

bool quality_class(PlutoRefreshClass cls) {
  return cls == kPlutoRefreshText || cls == kPlutoRefreshFull;
}

uint64_t pack_pen_point(int32_t x, int32_t y) {
  return static_cast<uint64_t>(static_cast<uint32_t>(x)) |
         (static_cast<uint64_t>(static_cast<uint32_t>(y)) << 32u);
}

void unpack_pen_point(uint64_t packed, int32_t *x, int32_t *y) {
  *x = static_cast<int32_t>(static_cast<uint32_t>(packed));
  *y = static_cast<int32_t>(static_cast<uint32_t>(packed >> 32u));
}

constexpr uint64_t kPenHintInRangeFlag = uint64_t{1} << 0u;
constexpr uint64_t kPenHintContactFlag = uint64_t{1} << 1u;

uint64_t pen_focus_wake_signature(const PenRenderHintSnapshot &hint) {
  const auto bin = [](int32_t coordinate) {
    return static_cast<uint64_t>(
        std::clamp(coordinate, int32_t{0}, int32_t{65535}) >> 4u);
  };
  uint64_t signature = hint.in_range ? 1u : 0u;
  signature |= hint.contact ? 2u : 0u;
  signature |= bin(hint.current_x) << 2u;
  signature |= bin(hint.current_y) << 14u;
  signature |= bin(hint.predicted_x) << 26u;
  signature |= bin(hint.predicted_y) << 38u;
  return signature;
}

bool presenter_binding_is_current(const PlutoPresenterOps *ops,
                                  PlutoPresenter *presenter) {
  return (ops == nullptr && presenter == nullptr) ||
         (presenter != nullptr && presenter_ops_are_current(ops));
}

PlutoRect presenter_focus_rect(const PlutoRect &logical, uint32_t logical_width,
                               uint32_t logical_height, uint32_t rotation) {
  switch (rotation) {
  case 90:
    return PlutoRect{static_cast<int32_t>(logical_height) - logical.y -
                         logical.height,
                     logical.x, logical.height, logical.width};
  case 180:
    return PlutoRect{
        static_cast<int32_t>(logical_width) - logical.x - logical.width,
        static_cast<int32_t>(logical_height) - logical.y - logical.height,
        logical.width, logical.height};
  case 270:
    return PlutoRect{logical.y,
                     static_cast<int32_t>(logical_width) - logical.x -
                         logical.width,
                     logical.height, logical.width};
  default:
    return logical;
  }
}

void advance_atomic_floor(std::atomic<uint64_t> *floor, uint64_t value) {
  uint64_t observed = floor->load(std::memory_order_relaxed);
  while (observed < value && !floor->compare_exchange_weak(
                                 observed, value, std::memory_order_release,
                                 std::memory_order_relaxed)) {
  }
}

} // namespace

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "pen hint mailbox requires lock-free 64-bit atomics");

bool PenRenderHintMailbox::publish(const PenRenderHintSnapshot &hint) {
  return publish(hint, expected_generation_.load(std::memory_order_acquire));
}

bool PenRenderHintMailbox::publish(const PenRenderHintSnapshot &hint,
                                   uint64_t generation) {
  if (generation != expected_generation_.load(std::memory_order_acquire)) {
    return false;
  }
  // Episode edges invalidate the preceding path. On exit this leaves exactly
  // the terminal point in the new epoch, allowing a real app cursor erase to
  // correlate without retaining an entire old stroke. On re-entry it retires
  // that terminal ROI before the new hover episode begins.
  const bool was_in_range =
      publisher_in_range_.exchange(hint.in_range, std::memory_order_acq_rel);
  if (!hint.in_range && !was_in_range) {
    // A fresh-session EVIOCGKEY snapshot with no pen present carries stale
    // last-known ABS coordinates. It is not a terminal hover ROI because no
    // active episode exists to erase.
    return false;
  }
  if (was_in_range != hint.in_range) {
    clear_epoch_.fetch_add(1, std::memory_order_acq_rel);
    advance_atomic_floor(&overwrite_accounting_floor_,
                         published_ticket_.load(std::memory_order_acquire));
  }
  const uint64_t epoch = clear_epoch_.load(std::memory_order_acquire);

  // Acquire the odd seqlock version. Production has one publisher (the ink
  // thread); CAS keeps accidental extra publishers coherent without a mutex.
  uint64_t even = version_.load(std::memory_order_acquire);
  for (;;) {
    if ((even & 1u) != 0) {
      even = version_.load(std::memory_order_acquire);
      continue;
    }
    if (version_.compare_exchange_weak(even, even + 1,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
      break;
    }
  }

  const uint64_t ticket =
      next_ticket_.fetch_add(1, std::memory_order_relaxed) + 1;
  const uint64_t consumed = consumed_ticket_.load(std::memory_order_relaxed);
  const uint64_t accounted = std::max(
      consumed, overwrite_accounting_floor_.load(std::memory_order_relaxed));
  if (ticket > kCapacity && accounted < ticket - kCapacity) {
    overwritten_unconsumed_.fetch_add(1, std::memory_order_relaxed);
  }
  AtomicEntry &entry = entries_[(ticket - 1) % kCapacity];
  entry.timestamp_us.store(hint.timestamp_us, std::memory_order_relaxed);
  entry.previous.store(pack_pen_point(hint.previous_x, hint.previous_y),
                       std::memory_order_relaxed);
  entry.current.store(pack_pen_point(hint.current_x, hint.current_y),
                      std::memory_order_relaxed);
  entry.predicted.store(pack_pen_point(hint.predicted_x, hint.predicted_y),
                        std::memory_order_relaxed);
  entry.sequence.store(hint.sequence, std::memory_order_relaxed);
  uint64_t flags = 0;
  if (hint.in_range) {
    flags |= kPenHintInRangeFlag;
  }
  if (hint.contact) {
    flags |= kPenHintContactFlag;
  }
  entry.flags.store(flags, std::memory_order_relaxed);
  entry.generation.store(generation, std::memory_order_relaxed);
  entry.epoch.store(epoch, std::memory_order_relaxed);
  entry.ticket.store(ticket, std::memory_order_relaxed);
  published_ticket_.store(ticket, std::memory_order_relaxed);
  active_ticket_.store(hint.in_range ? ticket : 0, std::memory_order_relaxed);
  std::atomic_thread_fence(std::memory_order_release);
  version_.store(even + 2, std::memory_order_release);
  // clear() is intentionally lock-free and may retire this publication after
  // it sampled the old epoch but before `published_ticket_` became visible.
  // Such a ticket is unroutable by construction; advance the telemetry floor
  // so a later capacity wrap cannot report that intentional retirement as an
  // input loss. The atomic-max helper also prevents a delayed clear from
  // regressing a newer accounting floor.
  if (epoch != clear_epoch_.load(std::memory_order_acquire)) {
    advance_atomic_floor(&overwrite_accounting_floor_, ticket);
  }
  return true;
}

PenRenderHintMailbox::Batch PenRenderHintMailbox::snapshot() const {
  for (;;) {
    Batch batch;
    const uint64_t epoch_before = clear_epoch_.load(std::memory_order_acquire);
    const uint64_t generation_before =
        expected_generation_.load(std::memory_order_acquire);
    const uint64_t version_before = version_.load(std::memory_order_acquire);
    if ((version_before & 1u) != 0) {
      continue;
    }

    const uint64_t published =
        published_ticket_.load(std::memory_order_relaxed);
    const uint64_t consumed = consumed_ticket_.load(std::memory_order_relaxed);
    const uint64_t active = active_ticket_.load(std::memory_order_relaxed);
    const auto append_entry = [&](const AtomicEntry &slot, uint64_t ticket,
                                  uint64_t output_ticket,
                                  bool require_in_range) {
      if (batch.count >= batch.entries.size() ||
          slot.ticket.load(std::memory_order_relaxed) != ticket ||
          slot.epoch.load(std::memory_order_relaxed) != epoch_before ||
          slot.generation.load(std::memory_order_relaxed) !=
              generation_before) {
        return false;
      }
      const uint64_t flags = slot.flags.load(std::memory_order_relaxed);
      if (require_in_range && (flags & kPenHintInRangeFlag) == 0) {
        return false;
      }
      Entry &out = batch.entries[batch.count++];
      out.ticket = output_ticket;
      out.hint.timestamp_us = slot.timestamp_us.load(std::memory_order_relaxed);
      unpack_pen_point(slot.previous.load(std::memory_order_relaxed),
                       &out.hint.previous_x, &out.hint.previous_y);
      unpack_pen_point(slot.current.load(std::memory_order_relaxed),
                       &out.hint.current_x, &out.hint.current_y);
      unpack_pen_point(slot.predicted.load(std::memory_order_relaxed),
                       &out.hint.predicted_x, &out.hint.predicted_y);
      out.hint.sequence = slot.sequence.load(std::memory_order_relaxed);
      out.hint.in_range = (flags & kPenHintInRangeFlag) != 0;
      out.hint.contact = (flags & kPenHintContactFlag) != 0;
      return true;
    };
    uint64_t first = consumed + 1;
    if (published > kCapacity) {
      first = std::max(first, published - kCapacity + 1);
    }
    if (first <= published) {
      for (uint64_t ticket = first; ticket <= published; ++ticket) {
        const AtomicEntry &slot = entries_[(ticket - 1) % kCapacity];
        (void)append_entry(slot, ticket, ticket,
                           /*require_in_range=*/false);
      }
    }
    bool active_already_present = false;
    for (size_t i = 0; i < batch.count; ++i) {
      active_already_present =
          active_already_present || batch.entries[i].ticket == active;
    }
    if (active != 0 && !active_already_present &&
        batch.count < batch.entries.size()) {
      const AtomicEntry &slot = entries_[(active - 1) % kCapacity];
      // Ticket zero makes this a sticky scheduling position, not new history;
      // route acknowledgement must not consume or duplicate it.
      (void)append_entry(slot, active, /*output_ticket=*/0,
                         /*require_in_range=*/true);
    }

    std::atomic_thread_fence(std::memory_order_acquire);
    const uint64_t version_after = version_.load(std::memory_order_acquire);
    const uint64_t epoch_after = clear_epoch_.load(std::memory_order_acquire);
    const uint64_t generation_after =
        expected_generation_.load(std::memory_order_acquire);
    if (version_before == version_after && (version_after & 1u) == 0 &&
        epoch_before == epoch_after && generation_before == generation_after) {
      batch.epoch = epoch_after;
      return batch;
    }
  }
}

void PenRenderHintMailbox::acknowledge(uint64_t ticket, uint64_t epoch) {
  if (ticket == 0 || epoch != clear_epoch_.load(std::memory_order_acquire)) {
    return;
  }
  uint64_t consumed = consumed_ticket_.load(std::memory_order_relaxed);
  while (consumed < ticket && !consumed_ticket_.compare_exchange_weak(
                                  consumed, ticket, std::memory_order_release,
                                  std::memory_order_relaxed)) {
  }
}

void PenRenderHintMailbox::clear() {
  // Snapshot the last ticket belonging to the epoch being retired before
  // publishing the new epoch. A publisher which observes the new epoch must
  // not be hidden below this floor; an old-epoch publisher which allocates
  // after the snapshot is covered by publish()'s final mismatch check.
  const uint64_t retire_through = next_ticket_.load(std::memory_order_acquire);
  clear_epoch_.fetch_add(1, std::memory_order_acq_rel);
  publisher_in_range_.store(false, std::memory_order_release);
  active_ticket_.store(0, std::memory_order_release);
  advance_atomic_floor(&overwrite_accounting_floor_, retire_through);
}

void PenRenderHintMailbox::set_generation(uint64_t generation) {
  if (expected_generation_.exchange(generation, std::memory_order_acq_rel) !=
      generation) {
    clear();
  }
}

// Bounded MPSC ring (Vyukov-style): producers claim a ticket with a CAS and
// publish via the slot's sequence number, so push never blocks and the
// single consumer observes completions in ticket (arrival) order.
CompletionQueue::CompletionQueue() {
  for (size_t i = 0; i < k_capacity; ++i) {
    slots_[i].sequence.store(i, std::memory_order_relaxed);
  }
}

bool CompletionQueue::push(uint64_t frame_id) {
  uint64_t pos = enqueue_pos_.load(std::memory_order_relaxed);
  for (;;) {
    Slot &slot = slots_[pos % k_capacity];
    const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
    const int64_t diff =
        static_cast<int64_t>(sequence) - static_cast<int64_t>(pos);
    if (diff == 0) {
      if (enqueue_pos_.compare_exchange_weak(pos, pos + 1,
                                             std::memory_order_relaxed)) {
        slot.frame_id = frame_id;
        slot.sequence.store(pos + 1, std::memory_order_release);
        return true;
      }
    } else if (diff < 0) {
      return false; // full
    } else {
      pos = enqueue_pos_.load(std::memory_order_relaxed);
    }
  }
}

bool CompletionQueue::pop(uint64_t *out_frame_id) {
  Slot &slot = slots_[dequeue_pos_ % k_capacity];
  const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
  if (static_cast<int64_t>(sequence) - static_cast<int64_t>(dequeue_pos_ + 1) <
      0) {
    return false; // empty
  }
  *out_frame_id = slot.frame_id;
  slot.sequence.store(dequeue_pos_ + k_capacity, std::memory_order_release);
  ++dequeue_pos_;
  return true;
}

size_t CompletionQueue::size_approx_for_testing() const {
  const uint64_t tail = enqueue_pos_.load(std::memory_order_acquire);
  return tail >= dequeue_pos_ ? static_cast<size_t>(tail - dequeue_pos_) : 0;
}

FrameRenderer::FrameRenderer(const FrameRendererConfig &config)
    : config_(config) {
  if (!config_.health_file_path.empty()) {
    health_file_ =
        std::make_unique<HealthFilePublisher>(config_.health_file_path);
  }
  open_frame_recorder();
  if (!presenter_binding_is_current(config_.presenter_ops, config_.presenter)) {
    return;
  }
  configure(config.width, config.height, config.format);
  valid_ = components_valid();
  if (valid_ && config_.start_presenter_thread) {
    thread_ = std::thread(&FrameRenderer::run_presenter_loop, this);
  }
}

bool FrameRenderer::components_valid() const {
  const bool health_contract_valid =
      config_.health_file_path.empty() ||
      (std::filesystem::path(config_.health_file_path).is_absolute() &&
       health_file_ != nullptr && presenter_supports_health_contract_);
  return presenter_binding_is_current(config_.presenter_ops,
                                      config_.presenter) &&
         !presenter_focus_clear_fault_ && scheduler_ != nullptr &&
         scheduler_->valid() && ledger_.valid() && ladder_.valid() &&
         scroll_detect_.valid() && guard_band_.valid() &&
         settle_planner_.valid() && pen_render_policy_.valid() &&
         (!config_.enable_auto_ghostbuster || auto_ghostbuster_.valid()) &&
         health_contract_valid;
}

FrameRenderer::~FrameRenderer() { shutdown(); }

void FrameRenderer::configure(uint32_t width, uint32_t height,
                              PlutoPixelFormat format) {
  // Callers must never rebuild scheduler/presenter state around a live rail.
  // set_rotation rejects that case; detach_presenter serializes recovery.
  if (pixel_reset_phase_ != PixelResetPhase::kIdle) {
    std::fprintf(stderr,
                 "pluto: refusing renderer reconfigure during pixel reset\n");
    return;
  }
  presenter_completion_count_ = 0;
  health_published_completion_count_ = 0;
  presenter_supports_health_contract_ = false;
  next_health_publish_us_ = 0;
  // Never forget a fallback reservation owned by the previous geometry. In
  // production host-direct mode native-panel coordinates survive logical
  // reconfiguration and EngineHost owns the lifecycle terminal edge. A failed
  // fallback clear leaves the old renderer intact but invalid.
  if (!clear_presenter_pen_focus_locked()) {
    presenter_focus_clear_fault_ = true;
    std::fprintf(stderr, "pluto: renderer reconfigure refused; presenter pen "
                         "focus clear failed\n");
    return;
  }
  presenter_focus_clear_fault_ = false;
  set_pixel_reset_render_hold_locked(false);
  pixel_reset_restore_generation_ = 0;
  pen_hint_mailbox_.clear();
  pen_focus_clear_requested_.store(false, std::memory_order_release);
  pen_focus_wake_signature_.store(UINT64_MAX, std::memory_order_release);
  pen_focus_wakes_.store(0, std::memory_order_release);
  last_pen_focus_hint_sequence_ = 0;
  pen_focus_expires_us_ = 0;
  presenter_pen_focus_sequence_ = 0;
  // A newly attached presenter may have seeded the ledger from another warm
  // app's currently visible glass. Preserved debt and submitted-frame counts
  // therefore cannot authorize a reset until this app supplies one accepted
  // post-configure Flutter frame and reconciles its retained truth.
  retained_content_ready_ = false;
  seeded_physical_baseline_valid_ = false;
  const size_t new_stride =
      static_cast<size_t>(width) * bytes_per_pixel(format);
  width_ = width;
  height_ = height;
  format_ = format;
  trace_enabled_ = env_flag_enabled("PLUTO_RENDERER_TRACE");
  stride_ = new_stride;
  // Reconfiguration starts cold unless the attached presenter offers one
  // complete correlated handoff below. Retaining a same-sized old vector is
  // not evidence that a newly opened panel owner preserved those pixels.
  retained_frame_.assign(stride_ * height_, 0);

  FrameLedgerConfig ledger_config{};
  ledger_config.width = width_;
  ledger_config.height = height_;
  ledger_config.tile_px = config_.renderer_config.tile_px;
  ledger_.configure(ledger_config);
  tile_pass_.set_config(config_.renderer_config);
  damage_rects_.clear();
  damage_rects_.reserve(ledger_.tile_count());
  submit_rects_.clear();
  submit_rects_.reserve(ledger_.tile_count());
  submit_classes_.clear();
  submit_classes_.reserve(ledger_.tile_count());
  packaged_rects_.clear();
  packaged_rects_.reserve(ledger_.tile_count());
  packaged_classes_.clear();
  packaged_classes_.reserve(ledger_.tile_count());
  pen_only_damage_rects_.clear();
  pen_only_damage_rects_.reserve(
      std::max<size_t>(ledger_.tile_count(), k_max_damage_rects * 4));
  pen_preview_rects_.clear();
  pen_preview_rects_.reserve(ledger_.tile_count());
  pen_truth_rects_.clear();
  pen_truth_rects_.reserve(ledger_.tile_count());
  pen_truth_classes_.clear();
  pen_truth_classes_.reserve(ledger_.tile_count());
  scroll_pending_px_ = 0;
  scroll_ledger_shift_px_ = 0;

  RegionPresenterHooks presenter{};
  presenter.user_data = this;
  presenter.ready = &FrameRenderer::presenter_ready;
  presenter.present = &FrameRenderer::presenter_present;

  RegionSchedulerConfig scheduler_config{};
  scheduler_config.width = static_cast<int32_t>(width_);
  scheduler_config.height = static_cast<int32_t>(height_);
  scheduler_config.presenter_rotation = config_.rotation;
  scheduler_config.pen_collision_tile_px = config_.renderer_config.tile_px;
  scheduler_config.cbs_settle_budget_pct =
      config_.renderer_config.cbs_settle_budget_pct;
  scheduler_config.debt_promote_threshold =
      config_.renderer_config.ghost_debt_promote_threshold;
  scheduler_config.debt_promote_min_gap_us =
      config_.renderer_config.ghost_promote_min_gap_ms * 1000u;
  // panel_is_color is wired below once display info is read (the scheduler
  // is constructed after that block).
  scheduler_config.surface = PlutoSurface{
      retained_frame_.data(), stride_, static_cast<int32_t>(width_),
      static_cast<int32_t>(height_), format_};

  PlutoPixelFormat target_format = format_;
  panel_is_color_ = false;
  backend_quantizes_color_ = false;
  presenter_controls_refresh_class_ = false;
  bool have_display_info = false;

  if (config_.presenter_ops != nullptr && config_.presenter != nullptr) {
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    if (config_.presenter_ops->info(config_.presenter, &info) ==
        kPlutoStatusOk) {
      have_display_info = true;
      scheduler_config.presenter_reports_completion = info.reports_completion;
      scheduler_config.align_px =
          info.rect_alignment > 0 ? static_cast<uint32_t>(info.rect_alignment)
                                  : scheduler_config.align_px;
      for (size_t i = 0; i < k_refresh_class_count; ++i) {
        if (info.nominal_latency_ms[i] >= 0) {
          scheduler_config.latency_model_us[i] =
              static_cast<uint32_t>(info.nominal_latency_ms[i]) * 1000u;
        }
      }
      target_format = info.preferred_format;
      panel_is_color_ = info.is_color;
      backend_quantizes_color_ = info.backend_quantizes_color;
      presenter_controls_refresh_class_ = info.controls_refresh_class;
      scheduler_config.presenter_collision_safe =
          info.supports_overlap_supersession;
      scheduler_config.serialize_pen_truth_by_tile =
          panel_is_color_ && backend_quantizes_color_ &&
          !scheduler_config.presenter_collision_safe;
    }
  }
  display_info_available_ = have_display_info;
  presenter_supports_health_contract_ =
      have_display_info && scheduler_config.presenter_reports_completion &&
      presenter_ops_are_current(config_.presenter_ops) &&
      config_.start_presenter_thread;

  AbiPresentBridgeConfig bridge_config{};
  bridge_config.width = width_;
  bridge_config.height = height_;
  bridge_config.rotation = config_.rotation;
  bridge_config.source_format = format_;
  bridge_config.target_format = target_format;
  bridge_config.panel_is_color = panel_is_color_;
  bridge_config.backend_quantizes_color = backend_quantizes_color_;
  if (config_.enable_present_bridge && have_display_info) {
    bridge_.configure(bridge_config);
    if (!bridge_.valid()) {
      std::fprintf(stderr,
                   "pluto: present bridge disabled (unsupported target "
                   "format %d); presenting raw engine pixels\n",
                   static_cast<int>(bridge_config.target_format));
    }
  } else {
    // Without a presenter (tests) or when explicitly disabled, present raw
    // mirror bytes untouched ("tests that inspect raw engine bytes").
    bridge_config.width = 0;
    bridge_.configure(bridge_config);
  }
  presenter_format_ = target_format;
  // Keep source-format truth for screenshots on every backend. RGB565 also
  // needs this mirror for same-luma color damage and delegated color output;
  // the other formats pay only the changed-rect copy cost.
  mirror_enabled_ = true;

  // Per-tile ledgers on the FrameLedger tile grid; the scheduler accrues/
  // clears them at dispatch and the settle planner reads them.
  TileGrid ledger_grid;
  ledger_grid.configure(static_cast<int32_t>(width_),
                        static_cast<int32_t>(height_),
                        config_.renderer_config.tile_px);
  ghost_ledger_.configure(ledger_grid, config_.renderer_config.ghost_tau_ms,
                          config_.renderer_config.ghost_debt_settle_threshold);
  stress_ledger_.configure(ledger_grid);
  chroma_pending_.configure(ledger_grid);
  AutoGhostbusterConfig ghostbuster_config = config_.auto_ghostbuster_config;
  ghostbuster_config.pigment_hygiene_supported =
      config_.pigment_hygiene_supported;
  auto_ghostbuster_.configure(ledger_grid, ghostbuster_config);
  const uint8_t input_mask = active_input_mask_.load(std::memory_order_acquire);
  auto_ghostbuster_.note_input_state(
      (input_mask & kTouchInputBit) != 0, (input_mask & kPenInputBit) != 0,
      last_input_change_us_.load(std::memory_order_acquire));

  SettlePlannerConfig planner_config{};
  planner_config.width = static_cast<int32_t>(width_);
  planner_config.height = static_cast<int32_t>(height_);
  planner_config.tile_px = config_.renderer_config.tile_px;
  planner_config.align_px = scheduler_config.align_px;
  planner_config.panel_is_color = panel_is_color_;
  planner_config.enable_sparkle_topoff =
      !ghostbuster_config.pigment_hygiene_supported;
  planner_config.perception = PerceptionConstants(config_.renderer_config);
  settle_planner_.configure(planner_config, &ghost_ledger_, &stress_ledger_,
                            &chroma_pending_);

  // Stage-6 classification stack: scroll detector on the
  // ledger's row-hash ping-pong, the TileStats-only classify ladder, and
  // the guard-band/word-box packager.
  ClassifyLadderConfig ladder_config{};
  ladder_config.width = static_cast<int32_t>(width_);
  ladder_config.height = static_cast<int32_t>(height_);
  ladder_config.tile_px = config_.renderer_config.tile_px;
  ladder_config.nas_enabled = config_.renderer_config.nas_enabled;
  ladder_.configure(ladder_config);
  scenecut_full_screen_percent_ = ladder_config.full_screen_area_percent;

  ScrollDetectConfig scroll_config{};
  scroll_config.width = static_cast<int32_t>(width_);
  scroll_config.height = static_cast<int32_t>(height_);
  scroll_config.min_band_rows =
      static_cast<int32_t>(config_.renderer_config.scroll_min_band_rows);
  // Area gate scales with the panel: a band is worth a vote when it spans
  // min_band_rows worth of full-width pixels (x11vnc scr_area shape).
  scroll_config.min_band_area_px =
      static_cast<int64_t>(config_.renderer_config.scroll_min_band_rows) *
      static_cast<int64_t>(width_);
  scroll_config.max_dy =
      static_cast<int32_t>(config_.renderer_config.scroll_max_dy);
  scroll_detect_.configure(scroll_config);

  GuardBandConfig guard_config{};
  guard_config.width = static_cast<int32_t>(width_);
  guard_config.height = static_cast<int32_t>(height_);
  guard_config.guard_px = config_.renderer_config.guard_px;
  guard_config.word_box_align_px =
      std::max<uint32_t>(8u, scheduler_config.align_px);
  guard_config.flag_map_enabled = config_.renderer_config.flag_map_enabled;
  guard_band_.configure(guard_config);

  PenRenderPolicyConfig pen_policy_config{};
  pen_policy_config.width = static_cast<int32_t>(width_);
  pen_policy_config.height = static_cast<int32_t>(height_);
  pen_policy_config.tile_px = config_.renderer_config.tile_px;
  pen_policy_config.hover_radius_px =
      config_.renderer_config.pen_hover_radius_px;
  pen_policy_config.contact_radius_px =
      config_.renderer_config.pen_contact_radius_px;
  pen_policy_config.changed_pixel_area_scale =
      config_.renderer_config.pen_changed_pixel_area_scale;
  pen_policy_config.max_preview_area_percent =
      config_.renderer_config.pen_max_preview_area_percent;
  pen_render_policy_.configure(pen_policy_config);

  scheduler_config.text_settle_nonintrusive = presenter_controls_refresh_class_;
  scheduler_ = std::make_unique<RegionScheduler>(
      scheduler_config, presenter, &ghost_ledger_, &stress_ledger_,
      &chroma_pending_);
  if (components_valid()) {
    try_admit_handoff_locked();
  }
}

// The frame path: one fused consume->quantize->dither->diff->stats pass
// over the damaged tiles, exact post-quantize rects into the scheduler.
// Phantom damage (sub-quantum RGB change) quantizes identical and produces
// zero scheduler activity by construction.
bool FrameRenderer::submit_frame(const PlutoFramePacket &packet) {
  std::lock_guard<std::mutex> lock(mutex_);
  ++submitted_frames_;
  if (!valid_ || packet.pixels == nullptr || packet.row_bytes == 0 ||
      packet.width == 0 || packet.height == 0) {
    return false;
  }
  record_frame(packet);
  if (!packet.did_update) {
    ++idle_frames_;
    last_damage_count_ = 0;
    maybe_resume_presentation_locked();
    return true;
  }
  if (packet.width != width_ || packet.height != height_ ||
      packet.format != format_) {
    if (logical_geometry_locked_) {
      ++stale_geometry_frames_;
      if (trace_enabled_) {
        std::fprintf(stderr,
                     "renderer: ignored stale geometry frame %ux%u/%d; "
                     "expected %ux%u/%d after rotation\n",
                     packet.width, packet.height,
                     static_cast<int>(packet.format), width_, height_,
                     static_cast<int>(format_));
      }
      return true;
    }
    configure(packet.width, packet.height, packet.format);
    valid_ = components_valid();
    if (!valid_ || packet.width != width_ || packet.height != height_ ||
        packet.format != format_) {
      return false;
    }
  }

  const PlutoSurface src{static_cast<const uint8_t *>(packet.pixels),
                         packet.row_bytes, static_cast<int32_t>(packet.width),
                         static_cast<int32_t>(packet.height), packet.format};
  const bool establishing_retained_content = !retained_content_ready_;
  // The ledger may have been seeded from another warm app's current glass.
  // Flutter paint bounds describe what this frame repainted, not everything
  // this app owns. Reconcile the complete first post-configure surface so an
  // immediate Full reset cannot restore untouched pixels from the other app.
  // Color-capable presenters always need exact raw truth. The attached direct
  // backend currently emits luma, but still enable raw comparison for a frame
  // that actually changes old/new chromatic content so same-luma recolors are
  // not lost. Achromatic sub-quantum RGB noise remains post-quantize-clean.
  const bool compare_rgb565 = mirror_enabled_ &&
                              packet.format == kPlutoPixelFormatRgb565 &&
                              (panel_is_color_ || backend_quantizes_color_ ||
                               has_chroma_sensitive_rgb565_change(packet));
  const uint8_t *const previous_rgb565 =
      compare_rgb565 &&
              (retained_content_ready_ || seeded_physical_baseline_valid_)
          ? retained_frame_.data()
          : nullptr;
  tile_pass_.run(src,
                 establishing_retained_content ? nullptr : packet.paint_bounds,
                 establishing_retained_content ? 0 : packet.paint_bounds_count,
                 &ledger_, previous_rgb565, stride_, compare_rgb565);
  const size_t count = merge_damage();
  last_damage_count_ = count;
  if (mirror_enabled_) {
    if (establishing_retained_content) {
      copy_rect_from_packet(packet,
                            PlutoRect{0, 0, static_cast<int32_t>(width_),
                                      static_cast<int32_t>(height_)});
    } else {
      for (const PlutoRect &rect : damage_rects_) {
        copy_rect_from_packet(packet, rect);
      }
    }
  }
  // Even a zero-damage updated packet now proves the complete configured
  // ledger and retained mirror describe this Flutter surface.
  retained_content_ready_ = true;
  seeded_physical_baseline_valid_ = false;
  if (count == 0) {
    maybe_resume_presentation_locked();
    return true;
  }
  ++diffed_frames_;
  if (trace_enabled_) {
    std::fprintf(stderr, "renderer frame tiles=%zu damage=%zu\n",
                 tile_pass_.dirty_tiles().size(), count);
  }
  // ONE monotonic timebase: the scheduler and settle planner
  // only ever see steady-clock time. The engine's presentation_time_ns is a
  // different clock domain and is recorded, never scheduled against.
  const uint64_t now_us = decision_now_us();
  for (const PlutoRect &rect : damage_rects_) {
    // Quiescence re-arm on the REAL damage (ARC scan resistance) — the
    // scroll path may suppress body presents below, but the content still
    // changed, so settles must keep waiting. Engine space == panel space
    // while the rotate stage is absent (rotation != 0 warns above).
    settle_planner_.note_damage(rect, now_us);
  }

  // Stage-6 classification: TilePass stats -> ScrollDetector
  // -> ClassifyLadder -> GuardBandPackager -> RegionScheduler.
  classify_damage(now_us);
  mark_chroma_tiles();
  route_pen_damage(now_us);

  // A pixel reset owns the panel until its black, white, and restore stages
  // have actually completed. Keep ingesting Flutter frames into the ledger,
  // but do not let ordinary damage interleave with those optical rails; the
  // final stage reads the newest retained truth.
  if (pixel_reset_phase_ != PixelResetPhase::kIdle) {
    tick_locked(now_us);
    wake_.store(true, std::memory_order_release);
    cv_.notify_one();
    return true;
  }

  guard_band_.package(submit_rects_.data(), submit_classes_.data(),
                      submit_rects_.size());
  packaged_rects_.clear();
  packaged_classes_.clear();
  for (const GuardedRegion &region : guard_band_.regions()) {
    // Content rects only: the guard-null fringe geometry rides in the
    // package for consumers that can express null transitions (see
    // guard_band.h — the ABI present path cannot).
    packaged_rects_.push_back(region.content);
    packaged_classes_.push_back(region.cls);
  }
  if (!packaged_rects_.empty()) {
    scheduler_->submit_damage(packaged_rects_.data(), packaged_classes_.data(),
                              packaged_rects_.size(), now_us);
  }
  for (size_t i = 0; i < pen_preview_rects_.size(); ++i) {
    scheduler_->submit_pen_damage(pen_preview_rects_[i], pen_truth_rects_[i],
                                  pen_truth_classes_[i], now_us);
  }
  tick_locked(now_us);
  maybe_resume_presentation_locked();
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
  return true;
}

void FrameRenderer::route_pen_damage(uint64_t now_us) {
  pen_preview_rects_.clear();
  pen_truth_rects_.clear();
  pen_truth_classes_.clear();
  if ((submit_rects_.empty() && pen_only_damage_rects_.empty()) ||
      !pen_render_policy_.valid()) {
    return;
  }
  // Establish the physical tile reservation before this frame can consume a
  // terminal hint ticket. The same helper runs on completion-only ticks, so
  // stationary hover is protected even when Flutter has no new frame yet.
  sync_pen_focus_locked(now_us);
  const PenRenderHintMailbox::Batch hints = pen_hint_mailbox_.snapshot();
  if (hints.count == 0) {
    return;
  }

  // Reuse the packaging vectors as preallocated normal-damage scratch. They
  // are cleared again immediately before GuardBandPackager output is copied.
  packaged_rects_.clear();
  packaged_classes_.clear();
  const auto &records = tile_pass_.dirty_tiles();
  uint64_t consumed_ticket = 0;
  uint64_t routed_changed_pixels = 0;
  int64_t routed_oldest_timestamp_us = 0;
  int64_t routed_newest_timestamp_us = 0;
  bool routed_in_range = false;
  bool routed_contact = false;
  const auto route_with_hint = [&](const PlutoRect &region, size_t h,
                                   PenRenderRoute *route,
                                   uint64_t *route_ticket,
                                   PenRenderHintSnapshot *route_hint) {
    if (h >= hints.count || route == nullptr || route_ticket == nullptr ||
        route_hint == nullptr) {
      return false;
    }
    *route_hint = hints.entries[h].hint;
    if (!route_hint->in_range) {
      if (route_hint->timestamp_us > 0 &&
          now_us > static_cast<uint64_t>(route_hint->timestamp_us) &&
          now_us - static_cast<uint64_t>(route_hint->timestamp_us) >
              k_terminal_pen_hint_retention_us) {
        consumed_ticket = std::max(consumed_ticket, hints.entries[h].ticket);
        return false;
      }
      // Range exit is a scheduling-only terminal ROI. Treat its final point
      // as hover solely while correlating an already-rendered app erase;
      // publishing it still creates no pixels, damage, or present request.
      route_hint->in_range = true;
      route_hint->contact = false;
    }
    const PlutoRect focus = pen_render_policy_.focus_rect(*route_hint);
    bool has_candidate_pixels = false;
    if (!rect_is_empty(focus) && rect_intersects(region, focus)) {
      const PlutoRect focused_region = rect_intersection(region, focus);
      for (const DirtyTileRecord &record : records) {
        if (rect_intersects(record.dirty, focused_region)) {
          has_candidate_pixels = true;
          break;
        }
      }
    }
    if (!has_candidate_pixels) {
      return false;
    }
    *route = pen_render_policy_.route_region(
        region, *route_hint, records.data(), records.size(), panel_is_color_);
    if (!route->associated) {
      return false;
    }
    *route_ticket = hints.entries[h].ticket;
    return true;
  };
  const auto record_route = [&](const PenRenderRoute &route,
                                uint64_t route_ticket,
                                const PenRenderHintSnapshot &route_hint) {
    pen_preview_rects_.push_back(route.preview);
    pen_truth_rects_.push_back(route.truth);
    pen_truth_classes_.push_back(route.truth_class);
    ++pen_priority_regions_;
    pen_priority_changed_pixels_ += route.changed_pixels;
    pen_priority_preview_pixels_ +=
        static_cast<uint64_t>(rect_area(route.preview));
    routed_changed_pixels += route.changed_pixels;
    consumed_ticket = std::max(consumed_ticket, route_ticket);
    if (route_hint.timestamp_us > 0) {
      routed_oldest_timestamp_us =
          routed_oldest_timestamp_us == 0
              ? route_hint.timestamp_us
              : std::min(routed_oldest_timestamp_us, route_hint.timestamp_us);
      routed_newest_timestamp_us =
          std::max(routed_newest_timestamp_us, route_hint.timestamp_us);
    }
    routed_in_range = route_hint.in_range;
    routed_contact = route_hint.contact;
  };

  for (size_t i = 0; i < submit_rects_.size(); ++i) {
    const PlutoRect &region = submit_rects_[i];
    // A single Flutter frame may coalesce several queued pen samples into one
    // connected dirty region. Route oldest-first to preserve delayed-frame
    // correlation, but subtract each verified hot corridor and then let later
    // hints claim only residual changed pixels. This accelerates the current
    // tip without consuming a later hint that contributed no new pixels.
    constexpr size_t kMaxResiduals = 1 + 3 * PenRenderHintMailbox::kCapacity;
    std::array<PlutoRect, kMaxResiduals> residuals{};
    size_t residual_count = 1;
    residuals[0] = region;
    for (size_t h = 0; h < hints.count && residual_count != 0; ++h) {
      for (size_t r = 0; r < residual_count; ++r) {
        PenRenderRoute route;
        uint64_t route_ticket = 0;
        PenRenderHintSnapshot route_hint;
        if (!route_with_hint(residuals[r], h, &route, &route_ticket,
                             &route_hint)) {
          continue;
        }
        record_route(route, route_ticket, route_hint);
        PlutoRect fragments[4]{};
        const size_t fragment_count = PenRenderPolicy::subtract_rect(
            residuals[r], route.truth, fragments);
        const size_t tail_count = residual_count - r - 1;
        const size_t next_count = residual_count - 1 + fragment_count;
        assert(next_count <= residuals.size());
        std::memmove(residuals.data() + r + fragment_count,
                     residuals.data() + r + 1, tail_count * sizeof(PlutoRect));
        for (size_t f = 0; f < fragment_count; ++f) {
          residuals[r + f] = fragments[f];
        }
        residual_count = next_count;
        break; // one contiguous focus corridor per hint
      }
    }
    for (size_t r = 0; r < residual_count; ++r) {
      packaged_rects_.push_back(residuals[r]);
      packaged_classes_.push_back(submit_classes_[i]);
    }
  }
  submit_rects_.swap(packaged_rects_);
  submit_classes_.swap(packaged_classes_);

  // Interaction classifiers may deliberately omit real app damage (scroll
  // body pacing). Give only those omitted pixels a chance to enter the pen
  // lane. There is intentionally no ordinary residual here: an unmatched
  // candidate stays suppressed under the classifier's original policy.
  for (const PlutoRect &region : pen_only_damage_rects_) {
    for (size_t h = 0; h < hints.count; ++h) {
      PenRenderRoute route;
      uint64_t route_ticket = 0;
      PenRenderHintSnapshot route_hint;
      if (!route_with_hint(region, h, &route, &route_ticket, &route_hint)) {
        continue;
      }
      bool already_covered = false;
      for (const PlutoRect &truth : pen_truth_rects_) {
        if (rect_contains(truth, route.truth)) {
          already_covered = true;
          break;
        }
      }
      if (!already_covered) {
        record_route(route, route_ticket, route_hint);
      }
    }
  }
  if (consumed_ticket != 0) {
    pen_hint_mailbox_.acknowledge(consumed_ticket, hints.epoch);
  }
  if (!pen_preview_rects_.empty()) {
    const uint64_t oldest_hint_to_frame_us =
        routed_oldest_timestamp_us > 0 &&
                now_us >= static_cast<uint64_t>(routed_oldest_timestamp_us)
            ? now_us - static_cast<uint64_t>(routed_oldest_timestamp_us)
            : 0;
    const uint64_t newest_hint_to_frame_us =
        routed_newest_timestamp_us > 0 &&
                now_us >= static_cast<uint64_t>(routed_newest_timestamp_us)
            ? now_us - static_cast<uint64_t>(routed_newest_timestamp_us)
            : 0;
    last_pen_hint_to_frame_us_ = newest_hint_to_frame_us;
    if (!trace_enabled_) {
      return;
    }
    std::fprintf(stderr,
                 "renderer pen-route regions=%zu changed_px_frame=%llu "
                 "changed_px_total=%llu hover=%d contact=%d "
                 "hint_oldest_to_frame_us=%llu "
                 "hint_newest_to_frame_us=%llu\n",
                 pen_preview_rects_.size(),
                 static_cast<unsigned long long>(routed_changed_pixels),
                 static_cast<unsigned long long>(pen_priority_changed_pixels_),
                 routed_in_range ? 1 : 0, routed_contact ? 1 : 0,
                 static_cast<unsigned long long>(oldest_hint_to_frame_us),
                 static_cast<unsigned long long>(newest_hint_to_frame_us));
  }
}

void FrameRenderer::notify_idle_frame() {
  std::lock_guard<std::mutex> lock(mutex_);
  ++submitted_frames_;
  ++idle_frames_;
  last_damage_count_ = 0;
  maybe_resume_presentation_locked();
}

bool FrameRenderer::set_rotation(uint32_t rotation, uint32_t logical_width,
                                 uint32_t logical_height) {
  if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270) {
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (pixel_reset_phase_ != PixelResetPhase::kIdle) {
    std::fprintf(stderr,
                 "pluto: rotation deferred until optical restore completes\n");
    return false;
  }
  // Standalone fallback focus is derived from logical coordinates, so clear
  // it before the geometry fence. Production host-direct focus is already in
  // native panel coordinates and does not need to pause through rotation.
  if (!clear_presenter_pen_focus_locked()) {
    std::fprintf(stderr, "pluto: rotation refused; presenter pen focus clear "
                         "failed\n");
    return false;
  }
  if (scheduler_ != nullptr) {
    scheduler_->clear_pen_focus();
  }
  // Freeze scheduler dispatch under the renderer mutex, then prove the
  // physical presenter idle before rebuilding scheduler and bridge geometry.
  // Completion callbacks are enqueue-only and therefore cannot deadlock this
  // wait.
  if (config_.presenter_ops != nullptr && config_.presenter != nullptr) {
    const PlutoStatus status = config_.presenter_ops->wait_idle(
        config_.presenter, k_rotation_wait_idle_timeout_ms);
    if (status != kPlutoStatusOk) {
      std::fprintf(stderr,
                   "pluto: rotation refused; presenter did not become "
                   "idle (status=%d)\n",
                   static_cast<int>(status));
      return false;
    }
    drain_completions_locked();
  }
  // Debt is tracked in the renderer/panel coordinate grid. Even a 180-degree
  // rotation keeps the same dimensions while moving every physical tile, so
  // geometry-only preservation would let later Text work repay the wrong
  // locations. Reset spatial/temporal automatic state on every rotation until
  // a rotation-aware remap/persistent supervisor ledger exists.
  auto_ghostbuster_ = AutoGhostbuster{};
  pen_hint_mailbox_.clear();
  config_.rotation = rotation;
  configure(logical_width, logical_height, format_);
  valid_ = components_valid();
  if (valid_) {
    logical_geometry_locked_ = true;
  }
  return valid_;
}

bool FrameRenderer::request_full_refresh() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!valid_ || scheduler_ == nullptr || !retained_content_ready_ ||
      width_ == 0 || height_ == 0) {
    return false;
  }
  const PlutoRect full{0, 0, static_cast<int32_t>(width_),
                       static_cast<int32_t>(height_)};
  const PlutoRefreshClass quality = kPlutoRefreshFull;
  const uint64_t now_us = decision_now_us();
  scheduler_->submit_damage(&full, &quality, 1, now_us);
  tick_locked(now_us);
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
  return true;
}

bool FrameRenderer::request_pixel_reset() {
  return request_ghost_control(GhostControlMode::kBlinkNow);
}

void FrameRenderer::set_input_active(uint8_t bit, bool active) {
  uint8_t observed = active_input_mask_.load(std::memory_order_acquire);
  for (;;) {
    const uint8_t desired = active ? static_cast<uint8_t>(observed | bit)
                                   : static_cast<uint8_t>(observed & ~bit);
    if (desired == observed) {
      return; // state edges only; no high-rate input-thread lock traffic
    }
    uint64_t last = last_input_change_us_.load(std::memory_order_relaxed);
    const uint64_t now_us = decision_now_us();
    while (last < now_us && !last_input_change_us_.compare_exchange_weak(
                                last, now_us, std::memory_order_release,
                                std::memory_order_relaxed)) {
    }
    if (active_input_mask_.compare_exchange_weak(observed, desired,
                                                 std::memory_order_release,
                                                 std::memory_order_acquire)) {
      wake_.store(true, std::memory_order_release);
      cv_.notify_one();
      return;
    }
  }
}

void FrameRenderer::set_touch_active(bool active) {
  set_input_active(kTouchInputBit, active);
}

void FrameRenderer::set_pen_active(bool active) {
  set_input_active(kPenInputBit, active);
}

void FrameRenderer::note_pen_render_hint(const PenRenderHintSnapshot &hint) {
  if (!pen_hint_mailbox_.publish(hint)) {
    return;
  }
  pen_focus_clear_requested_.store(false, std::memory_order_release);
  const uint64_t signature = pen_focus_wake_signature(hint);
  if (pen_focus_wake_signature_.exchange(
          signature, std::memory_order_acq_rel) == signature) {
    return;
  }
  pen_focus_wakes_.fetch_add(1, std::memory_order_relaxed);
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
}

void FrameRenderer::note_pen_render_hint(const PenRenderHintSnapshot &hint,
                                         uint64_t generation) {
  if (!pen_hint_mailbox_.publish(hint, generation)) {
    return;
  }
  pen_focus_clear_requested_.store(false, std::memory_order_release);
  const uint64_t signature = pen_focus_wake_signature(hint);
  if (pen_focus_wake_signature_.exchange(
          signature, std::memory_order_acq_rel) == signature) {
    return;
  }
  pen_focus_wakes_.fetch_add(1, std::memory_order_relaxed);
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
}

void FrameRenderer::clear_pen_render_hints() {
  pen_hint_mailbox_.clear();
  pen_focus_clear_requested_.store(true, std::memory_order_release);
  pen_focus_wake_signature_.store(UINT64_MAX, std::memory_order_release);
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
}

void FrameRenderer::set_pen_render_hint_generation(uint64_t generation) {
  pen_hint_mailbox_.set_generation(generation);
  pen_focus_clear_requested_.store(true, std::memory_order_release);
  pen_focus_wake_signature_.store(UINT64_MAX, std::memory_order_release);
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
}

void FrameRenderer::set_auto_maintenance_allowed(bool allowed) {
  if (auto_maintenance_allowed_.exchange(allowed, std::memory_order_acq_rel) !=
      allowed) {
    wake_.store(true, std::memory_order_release);
    cv_.notify_one();
  }
}

bool FrameRenderer::request_ghost_control(GhostControlMode mode) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!valid_ || scheduler_ == nullptr || !retained_content_ready_ ||
      width_ == 0 || height_ == 0 || presentation_suspended_) {
    return false;
  }
  if (pixel_reset_phase_ != PixelResetPhase::kIdle) {
    return true; // coalesce repeated requests into the active reset
  }
  const uint64_t now_us = decision_now_us();
  uint32_t cycles = 0;
  uint64_t not_before_us = now_us;
  switch (mode) {
  case GhostControlMode::kBlinkNow:
    cycles = kBlinkThenBleachRailCycles;
    break;
  case GhostControlMode::kBlinkLater:
    cycles = kBlinkThenBleachRailCycles;
    not_before_us = now_us + 250000;
    break;
  case GhostControlMode::kBleachNow:
    cycles = kBleachRailCycles;
    break;
  case GhostControlMode::kFactoryReset:
    cycles = kFactoryResetRailCycles;
    break;
  }
  if (!begin_pixel_reset_locked(mode, cycles, not_before_us,
                                AutoGhostbusterDecision::kNone)) {
    return false;
  }
  tick_locked(now_us);
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
  return true;
}

bool FrameRenderer::begin_pixel_reset_locked(
    GhostControlMode mode, uint32_t cycles, uint64_t not_before_us,
    AutoGhostbusterDecision automatic_decision) {
  if (cycles == 0 || pixel_reset_phase_ != PixelResetPhase::kIdle) {
    return false;
  }
  pixel_reset_mode_ = mode;
  pixel_reset_auto_decision_ = automatic_decision;
  pixel_reset_interrupted_ = false;
  pixel_reset_cycles_remaining_ = cycles;
  pixel_reset_not_before_us_ = not_before_us;
  const uint64_t now_us = decision_now_us();
  pixel_reset_started_us_ = now_us;
  pixel_reset_deadline_us_ = now_us + kPixelResetTimeoutUs;
  pixel_reset_abort_deadline_us_ =
      pixel_reset_deadline_us_ + kPixelResetAbortTimeoutUs;
  pixel_reset_phase_ = PixelResetPhase::kPending;
  return true;
}

bool FrameRenderer::begin_auto_ghost_control_locked(
    AutoGhostbusterDecision decision, uint64_t now_us) {
  GhostControlMode mode = GhostControlMode::kBlinkNow;
  uint32_t cycles = 0;
  switch (decision) {
  case AutoGhostbusterDecision::kNone:
    return false;
  case AutoGhostbusterDecision::kBlink:
    // Internal-only cheap ghost cleanup. Public BlinkNow remains the proven
    // composed blink+bleach policy used by the bezel gesture.
    cycles = kBlinkRailCycles;
    break;
  case AutoGhostbusterDecision::kBleach:
    mode = GhostControlMode::kBleachNow;
    cycles = kBleachRailCycles;
    break;
  case AutoGhostbusterDecision::kBoth:
    cycles = kBlinkThenBleachRailCycles;
    break;
  }
  if (!begin_pixel_reset_locked(mode, cycles, now_us, decision)) {
    return false;
  }
  automatic_ghost_actions_.fetch_add(1, std::memory_order_release);
  const char *action = decision == AutoGhostbusterDecision::kBlink ? "blink"
                       : decision == AutoGhostbusterDecision::kBleach
                           ? "bleach"
                           : "blink+bleach";
  std::fprintf(stderr, "auto-ghostbuster: %s accepted cycles=%u\n", action,
               cycles);
  return true;
}

void FrameRenderer::set_presentation_suspended(bool suspended) {
  std::lock_guard<std::mutex> lock(mutex_);
  presentation_suspended_ = suspended;
  presentation_resume_requested_ = false;
  resume_after_submitted_frames_ = submitted_frames_;
}

bool FrameRenderer::arm_presentation_resume() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!presentation_suspended_) {
    return false;
  }
  presentation_resume_requested_ = true;
  resume_after_submitted_frames_ = submitted_frames_;
  return true;
}

bool FrameRenderer::force_presentation_resume() {
  std::lock_guard<std::mutex> lock(mutex_);
  const bool revealed = reveal_suspended_presentation_locked();
  if (revealed) {
    wake_.store(true, std::memory_order_release);
    cv_.notify_one();
  }
  return revealed;
}

bool FrameRenderer::presentation_suspended() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return presentation_suspended_;
}

bool FrameRenderer::snapshot(RendererSnapshotSurface surface,
                             RendererSnapshot *out) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (out == nullptr || !retained_content_ready_ || width_ == 0 ||
      height_ == 0) {
    return false;
  }

  RendererSnapshot next;
  next.width = width_;
  next.height = height_;
  switch (surface) {
  case RendererSnapshotSurface::kLogical:
    if (stride_ == 0 || retained_frame_.size() != stride_ * height_) {
      return false;
    }
    next.stride_bytes = stride_;
    next.format = format_;
    next.pixels = retained_frame_;
    break;
  case RendererSnapshotSurface::kPostDither:
    if (!ledger_.valid() || ledger_.width() != width_ ||
        ledger_.height() != height_ ||
        static_cast<size_t>(height_) >
            std::numeric_limits<size_t>::max() / static_cast<size_t>(width_)) {
      return false;
    }
    next.stride_bytes = width_;
    next.format = kPlutoPixelFormatGray8;
    next.pixels.resize(static_cast<size_t>(width_) * height_);
    for (uint32_t y = 0; y < height_; ++y) {
      levels_to_gray8_span(
          ledger_.l_cur() + static_cast<size_t>(y) * ledger_.stride(), width_,
          next.pixels.data() + static_cast<size_t>(y) * next.stride_bytes);
    }
    break;
  default:
    return false;
  }

  *out = std::move(next);
  return true;
}

void FrameRenderer::maybe_resume_presentation_locked() {
  if (!presentation_suspended_ || !presentation_resume_requested_ ||
      submitted_frames_ <= resume_after_submitted_frames_) {
    return;
  }
  (void)reveal_suspended_presentation_locked();
}

bool FrameRenderer::reveal_suspended_presentation_locked() {
  if (!presentation_suspended_ || !valid_ || scheduler_ == nullptr ||
      width_ == 0 || height_ == 0 || !scheduler_->discard_pending()) {
    return false;
  }
  presentation_suspended_ = false;
  presentation_resume_requested_ = false;
  const PlutoRect full{0, 0, static_cast<int32_t>(width_),
                       static_cast<int32_t>(height_)};
  const PlutoRefreshClass quality = kPlutoRefreshFull;
  const uint64_t now_us = decision_now_us();
  scheduler_->submit_damage(&full, &quality, 1, now_us);
  tick_locked(now_us);
  return true;
}

bool FrameRenderer::write_preview_bmp(const std::string &path,
                                      uint32_t max_long_edge_px) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (path.empty() || submitted_frames_ == 0 || retained_frame_.empty() ||
      width_ == 0 || height_ == 0 || max_long_edge_px == 0) {
    return false;
  }
  const uint32_t long_edge = std::max(width_, height_);
  const double scale =
      std::min(1.0, static_cast<double>(max_long_edge_px) / long_edge);
  const uint32_t out_width =
      std::max(1u, static_cast<uint32_t>(std::lround(width_ * scale)));
  const uint32_t out_height =
      std::max(1u, static_cast<uint32_t>(std::lround(height_ * scale)));
  const uint32_t row_bytes = (out_width * 3u + 3u) & ~3u;
  const uint32_t pixel_bytes = row_bytes * out_height;
  std::vector<uint8_t> bmp(54u + pixel_bytes, 0);
  const auto put_u16 = [&bmp](size_t offset, uint16_t value) {
    bmp[offset] = static_cast<uint8_t>(value & 0xffu);
    bmp[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xffu);
  };
  const auto put_u32 = [&bmp](size_t offset, uint32_t value) {
    for (size_t i = 0; i < 4; ++i) {
      bmp[offset + i] = static_cast<uint8_t>((value >> (8u * i)) & 0xffu);
    }
  };
  bmp[0] = 'B';
  bmp[1] = 'M';
  put_u32(2, static_cast<uint32_t>(bmp.size()));
  put_u32(10, 54);
  put_u32(14, 40);
  put_u32(18, out_width);
  put_u32(22, out_height); // positive => bottom-up rows
  put_u16(26, 1);
  put_u16(28, 24);
  put_u32(34, pixel_bytes);

  for (uint32_t out_y = 0; out_y < out_height; ++out_y) {
    const uint32_t source_y =
        std::min(height_ - 1,
                 static_cast<uint32_t>(
                     (static_cast<uint64_t>(out_y) * height_) / out_height));
    uint8_t *dst = bmp.data() + 54u +
                   static_cast<size_t>(out_height - 1 - out_y) * row_bytes;
    for (uint32_t out_x = 0; out_x < out_width; ++out_x) {
      const uint32_t source_x = std::min(
          width_ - 1, static_cast<uint32_t>(
                          (static_cast<uint64_t>(out_x) * width_) / out_width));
      const uint8_t level =
          ledger_.l_cur()[static_cast<size_t>(source_y) * ledger_.stride() +
                          source_x];
      const uint8_t gray = level5_to_gray8(level);
      dst[out_x * 3] = gray;
      dst[out_x * 3 + 1] = gray;
      dst[out_x * 3 + 2] = gray;
    }
  }

  const std::filesystem::path target(path);
  std::error_code ec;
  std::filesystem::create_directories(target.parent_path(), ec);
  if (ec) {
    return false;
  }
  std::string temporary = path + ".tmp.XXXXXX";
  std::vector<char> mutable_path(temporary.begin(), temporary.end());
  mutable_path.push_back('\0');
  const int fd = ::mkstemp(mutable_path.data());
  if (fd < 0) {
    return false;
  }
  (void)::fcntl(fd, F_SETFD, FD_CLOEXEC);
  size_t written = 0;
  while (written < bmp.size()) {
    const ssize_t count =
        ::write(fd, bmp.data() + written, bmp.size() - written);
    if (count > 0) {
      written += static_cast<size_t>(count);
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      break;
    }
  }
  const bool ok = written == bmp.size() && ::fsync(fd) == 0 &&
                  ::close(fd) == 0 &&
                  ::rename(mutable_path.data(), path.c_str()) == 0;
  if (!ok) {
    (void)::close(fd);
    (void)::unlink(mutable_path.data());
  }
  return ok;
}

bool FrameRenderer::export_handoff_state_locked(
    RendererHandoffState *out) const {
  if (out == nullptr || scheduler_ == nullptr || !components_valid()) {
    return false;
  }
  RendererHandoffState state;
  state.width = width_;
  state.height = height_;
  state.rotation = config_.rotation;
  state.pixel_format = format_;
  state.presenter_format = presenter_format_;
  state.retained_stride = stride_;
  state.renderer_config = config_.renderer_config;
  state.start_presenter_thread = config_.start_presenter_thread;
  state.presenter_pen_focus_from_host = config_.presenter_pen_focus_from_host;
  state.enable_present_bridge = config_.enable_present_bridge;
  state.display_info_available = display_info_available_;
  state.present_bridge_active = bridge_.valid();
  state.mirror_enabled = mirror_enabled_;
  state.enable_auto_ghostbuster = config_.enable_auto_ghostbuster;
  state.pigment_hygiene_supported = config_.pigment_hygiene_supported;
  state.panel_is_color = panel_is_color_;
  state.backend_quantizes_color = backend_quantizes_color_;
  state.presenter_controls_refresh_class = presenter_controls_refresh_class_;
  state.retained_frame = retained_frame_;
  state.scroll_pending_px = scroll_pending_px_;
  state.scroll_ledger_shift_px = scroll_ledger_shift_px_;
  state.scroll_moves = scroll_moves_;
  state.active_input_mask = active_input_mask_.load(std::memory_order_acquire);
  state.last_input_change_us =
      last_input_change_us_.load(std::memory_order_acquire);
  state.automatic_ghost_actions =
      automatic_ghost_actions_.load(std::memory_order_acquire);
  if (!ledger_.export_state(&state.frame_ledger) ||
      !ladder_.export_state(&state.classify_ladder) ||
      !ghost_ledger_.export_state(&state.ghost_ledger) ||
      !stress_ledger_.export_state(&state.stress_ledger) ||
      !chroma_pending_.export_state(&state.chroma_pending) ||
      !settle_planner_.export_state(&state.settle_planner) ||
      !auto_ghostbuster_.export_state(&state.auto_ghostbuster) ||
      !scheduler_->export_state(&state.region_scheduler)) {
    return false;
  }
  *out = std::move(state);
  return true;
}

void FrameRenderer::restore_handoff_state_locked(
    const RendererHandoffState &state) {
  // A failed correlated import must never leave TilePass trusting the
  // rejected mirror/ledger pair. The restored state remains correct, but one
  // complete traversal must re-establish its optimization proof.
  tile_pass_.invalidate_exact_rgb565_baseline();
  // This is rollback-only state exported from these exact live components;
  // imports therefore cannot fail unless a component violates its own
  // export/import contract. Keep attempting every correlated plane so a
  // single unexpected failure cannot leave later mirrors stale.
  (void)ledger_.import_state(state.frame_ledger);
  (void)ladder_.import_state(state.classify_ladder);
  (void)ghost_ledger_.import_state(state.ghost_ledger);
  (void)stress_ledger_.import_state(state.stress_ledger);
  (void)chroma_pending_.import_state(state.chroma_pending);
  (void)settle_planner_.import_state(state.settle_planner);
  (void)auto_ghostbuster_.import_state(state.auto_ghostbuster);
  (void)scheduler_->import_state(state.region_scheduler);
  if (retained_frame_.size() == state.retained_frame.size()) {
    std::copy(state.retained_frame.begin(), state.retained_frame.end(),
              retained_frame_.begin());
  }
  scroll_pending_px_ = state.scroll_pending_px;
  scroll_ledger_shift_px_ = state.scroll_ledger_shift_px;
  scroll_moves_ = static_cast<size_t>(state.scroll_moves);
  active_input_mask_.store(state.active_input_mask, std::memory_order_release);
  last_input_change_us_.store(state.last_input_change_us,
                              std::memory_order_release);
  automatic_ghost_actions_.store(
      static_cast<size_t>(state.automatic_ghost_actions),
      std::memory_order_release);
}

bool FrameRenderer::import_handoff_state_locked(
    const RendererHandoffState &state) {
  RendererHandoffState before;
  if (!export_handoff_state_locked(&before) ||
      renderer_handoff_configuration_hash(before) !=
          renderer_handoff_configuration_hash(state) ||
      !renderer_handoff_validate(state) ||
      retained_frame_.size() != state.retained_frame.size() ||
      state.scroll_moves > std::numeric_limits<size_t>::max() ||
      state.automatic_ghost_actions > std::numeric_limits<size_t>::max()) {
    return false;
  }

  // Validation above exercised all imports against scratch components.
  // Apply the live planes only after that read-only transaction has passed;
  // preserve an exported rollback image for defensive fail-closed recovery.
  const bool imported =
      ledger_.import_state(state.frame_ledger) &&
      ladder_.import_state(state.classify_ladder) &&
      ghost_ledger_.import_state(state.ghost_ledger) &&
      stress_ledger_.import_state(state.stress_ledger) &&
      chroma_pending_.import_state(state.chroma_pending) &&
      settle_planner_.import_state(state.settle_planner) &&
      auto_ghostbuster_.import_state(state.auto_ghostbuster) &&
      scheduler_->import_state(state.region_scheduler);
  if (!imported) {
    restore_handoff_state_locked(before);
    return false;
  }
  std::copy(state.retained_frame.begin(), state.retained_frame.end(),
            retained_frame_.begin());
  scroll_pending_px_ = state.scroll_pending_px;
  scroll_ledger_shift_px_ = state.scroll_ledger_shift_px;
  scroll_moves_ = static_cast<size_t>(state.scroll_moves);
  active_input_mask_.store(state.active_input_mask, std::memory_order_release);
  last_input_change_us_.store(state.last_input_change_us,
                              std::memory_order_release);
  automatic_ghost_actions_.store(
      static_cast<size_t>(state.automatic_ghost_actions),
      std::memory_order_release);
  retained_content_ready_ = false;
  seeded_physical_baseline_valid_ = true;
  if (!tile_pass_.admit_exact_rgb565_baseline(
          ledger_,
          std::span<const uint8_t>(retained_frame_.data(),
                                   retained_frame_.size()),
          stride_)) {
    restore_handoff_state_locked(before);
    retained_content_ready_ = false;
    seeded_physical_baseline_valid_ = false;
    return false;
  }
  return true;
}

void FrameRenderer::try_admit_handoff_locked() {
  const PlutoPresenterOps *ops = config_.presenter_ops;
  PlutoPresenter *presenter = config_.presenter;
  if (presenter == nullptr || !presenter_ops_are_current(ops)) {
    return;
  }

  RendererHandoffState expected;
  if (!export_handoff_state_locked(&expected)) {
    if (ops->confirm_handoff(presenter, false) == kPlutoStatusDeviceLost) {
      notify_presenter_device_lost();
    }
    return;
  }
  const uint64_t expected_hash = renderer_handoff_configuration_hash(expected);
  PlutoHandoffPayload payload{};
  payload.struct_size = sizeof(payload);
  const PlutoStatus status = ops->get_handoff(presenter, &payload);
  if (status == kPlutoStatusAgain || status == kPlutoStatusUnsupported) {
    return;
  }
  if (status != kPlutoStatusOk) {
    if (status == kPlutoStatusDeviceLost ||
        ops->confirm_handoff(presenter, false) == kPlutoStatusDeviceLost) {
      notify_presenter_device_lost();
    }
    return;
  }

  RendererHandoffReject reject = RendererHandoffReject::kNone;
  RendererHandoffState incoming;
  const bool metadata_ok =
      payload.bytes != nullptr && payload.byte_count != 0 &&
      payload.width == static_cast<int32_t>(width_) &&
      payload.height == static_cast<int32_t>(height_) &&
      payload.rotation == config_.rotation && payload.pixel_format == format_ &&
      payload.configuration_hash == expected_hash;
  const bool decoded =
      metadata_ok &&
      renderer_handoff_decode(
          std::span<const uint8_t>(payload.bytes, payload.byte_count),
          expected_hash, &incoming, &reject);
  RendererHandoffState before;
  const bool have_before = export_handoff_state_locked(&before);
  const bool imported =
      decoded && have_before && import_handoff_state_locked(incoming);
  if (!imported) {
    const PlutoStatus confirm_status = ops->confirm_handoff(presenter, false);
    if (confirm_status == kPlutoStatusDeviceLost) {
      notify_presenter_device_lost();
    }
    seeded_physical_baseline_valid_ = false;
    if (status == kPlutoStatusOk) {
      std::fprintf(stderr, "pluto: renderer handoff rejected (%s)\n",
                   metadata_ok ? renderer_handoff_reject_name(reject)
                               : "metadata");
    }
    return;
  }

  const PlutoStatus confirm_status = ops->confirm_handoff(presenter, true);
  if (confirm_status != kPlutoStatusOk) {
    restore_handoff_state_locked(before);
    retained_content_ready_ = false;
    seeded_physical_baseline_valid_ = false;
    std::fprintf(stderr,
                 "pluto: renderer handoff confirmation failed; using cold "
                 "state\n");
    if (confirm_status == kPlutoStatusDeviceLost) {
      notify_presenter_device_lost();
    }
  }
}

void FrameRenderer::try_stage_handoff_locked(uint64_t deadline_us) {
  const PlutoPresenterOps *ops = config_.presenter_ops;
  PlutoPresenter *presenter = config_.presenter;
  if (presenter == nullptr || !presenter_ops_are_current(ops)) {
    return;
  }
  const bool scheduler_idle = scheduler_ != nullptr && scheduler_->idle();
  const bool user_pending =
      scheduler_ != nullptr && scheduler_->user_work_pending();
  const bool settle_pending =
      scheduler_ != nullptr && scheduler_->settle_work_pending();
  const bool presenter_inflight =
      scheduler_ != nullptr && scheduler_->anything_inflight();
  const size_t completion_count = completion_queue_.size_approx_for_testing();
  const size_t dropped = dropped_completions_.load(std::memory_order_acquire);
  const uint8_t input_mask = active_input_mask_.load(std::memory_order_acquire);
  if (!valid_ || !components_valid() || scheduler_ == nullptr ||
      !scheduler_idle || completion_count != 0 || dropped != 0 ||
      pixel_reset_phase_ != PixelResetPhase::kIdle ||
      pixel_reset_render_hold_ || presentation_suspended_ ||
      presentation_resume_requested_ || auto_ghostbuster_.action_active() ||
      input_mask != 0 || !retained_content_ready_ ||
      seeded_physical_baseline_valid_) {
    std::fprintf(
        stderr,
        "pluto: renderer handoff staging skipped unsafe valid=%d "
        "components=%d scheduler_idle=%d user_pending=%d "
        "settle_pending=%d inflight=%d completions=%zu dropped=%zu "
        "reset_phase=%u hold=%d suspended=%d resume_pending=%d "
        "maintenance_active=%d input=%u retained=%d seeded=%d\n",
        valid_ ? 1 : 0, components_valid() ? 1 : 0, scheduler_idle ? 1 : 0,
        user_pending ? 1 : 0, settle_pending ? 1 : 0,
        presenter_inflight ? 1 : 0, completion_count, dropped,
        static_cast<unsigned>(pixel_reset_phase_),
        pixel_reset_render_hold_ ? 1 : 0, presentation_suspended_ ? 1 : 0,
        presentation_resume_requested_ ? 1 : 0,
        auto_ghostbuster_.action_active() ? 1 : 0,
        static_cast<unsigned>(input_mask), retained_content_ready_ ? 1 : 0,
        seeded_physical_baseline_valid_ ? 1 : 0);
    return;
  }

  RendererHandoffState state;
  std::vector<uint8_t> bytes;
  RendererHandoffReject reject = RendererHandoffReject::kNone;
  if (!export_handoff_state_locked(&state) ||
      !renderer_handoff_encode(state, &bytes, &reject)) {
    std::fprintf(stderr, "pluto: renderer handoff staging skipped (%s)\n",
                 renderer_handoff_reject_name(reject));
    return;
  }

  const uint64_t now_us = monotonic_us();
  const uint32_t remaining_ms =
      now_us >= deadline_us ? 0u
                            : static_cast<uint32_t>(std::max<uint64_t>(
                                  1u, (deadline_us - now_us + 999u) / 1000u));
  const PlutoHandoffPayload payload{
      sizeof(PlutoHandoffPayload),
      bytes.data(),
      bytes.size(),
      static_cast<int32_t>(width_),
      static_cast<int32_t>(height_),
      config_.rotation,
      format_,
      renderer_handoff_configuration_hash(state),
  };
  const PlutoStatus status =
      ops->stage_handoff(presenter, &payload, remaining_ms);
  if (status != kPlutoStatusOk && status != kPlutoStatusAgain &&
      status != kPlutoStatusUnsupported) {
    std::fprintf(stderr,
                 "pluto: presenter declined renderer handoff; using cold "
                 "path\n");
  }
}

bool FrameRenderer::detach_presenter(uint32_t timeout_ms) {
  std::unique_lock<std::mutex> lock(mutex_);
  // Session teardown invalidates physical focus before any optical fence.
  // This releases only unstarted raw truth; mapped/scanned work is untouched.
  if (!clear_presenter_pen_focus_locked(
          config_.presenter_pen_focus_from_host)) {
    std::fprintf(stderr, "pluto: detach refused; presenter pen focus clear "
                         "failed\n");
    return false;
  }
  if (scheduler_ != nullptr) {
    scheduler_->clear_pen_focus();
  }
  pen_hint_mailbox_.clear();
  pen_focus_clear_requested_.store(false, std::memory_order_release);
  last_pen_focus_hint_sequence_ = 0;
  pen_focus_expires_us_ = 0;
  bool idle = true;
  const bool recovering_pixel_reset =
      pixel_reset_phase_ != PixelResetPhase::kIdle;
  const uint64_t deadline_us =
      monotonic_us() + static_cast<uint64_t>(timeout_ms) * 1000u;
  if (recovering_pixel_reset) {
    // Stop after the current black->white pair and force a balanced retained
    // restore before the presenter can be closed. Completion callbacks are
    // enqueue-only, so this platform-thread loop can wait without deadlocking
    // them, then drain/advance under the renderer mutex.
    pixel_reset_interrupted_ = true;
    while (pixel_reset_phase_ != PixelResetPhase::kIdle) {
      const uint64_t now_us = monotonic_us();
      drain_completions_locked();
      (void)advance_pixel_reset_locked(now_us);
      if (pixel_reset_phase_ == PixelResetPhase::kIdle) {
        break;
      }
      if (now_us >= deadline_us) {
        std::fprintf(stderr, "pixel-reset: detach recovery deadline expired; "
                             "presenter remains attached\n");
        return false;
      }
      const PlutoPresenterOps *ops = config_.presenter_ops;
      PlutoPresenter *presenter = config_.presenter;
      const uint32_t remaining_ms = static_cast<uint32_t>(
          std::max<uint64_t>(1, (deadline_us - now_us + 999u) / 1000u));
      lock.unlock();
      PlutoStatus status = kPlutoStatusOk;
      bool presenter_idle_proven = false;
      if (presenter_ops_are_current(ops) && presenter != nullptr) {
        status = ops->wait_idle(presenter, remaining_ms);
        presenter_idle_proven = status == kPlutoStatusOk;
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      lock.lock();
      if (presenter_idle_proven && scheduler_ != nullptr) {
        (void)scheduler_->retire_pixel_reset_after_presenter_idle();
      }
      if (status == kPlutoStatusDeviceLost) {
        std::fprintf(stderr,
                     "pixel-reset: presenter lost during detach recovery\n");
        return false;
      }
    }
  }

  if (recovering_pixel_reset && scheduler_ != nullptr) {
    // Completing the retained-content restore may enqueue one newest-ledger
    // Fast pass when Flutter changed after the restore surface was
    // snapshotted. The reset-recovery loop intentionally calls
    // advance_pixel_reset_locked() directly, so dispatch and fence that pass
    // here before destroying the scheduler generation. Keep mutex_ held once
    // recovery is idle: a late raster can no longer insert work between the
    // last presenter-idle sample and scheduler_.reset().
    for (;;) {
      drain_completions_locked();
      scheduler_->tick(monotonic_us(), /*maintenance_allowed=*/false,
                       /*intrusive_maintenance_allowed=*/false);
      drain_completions_locked();
      if (!scheduler_->user_work_pending() &&
          !scheduler_->anything_inflight()) {
        break;
      }

      const uint64_t now_us = monotonic_us();
      if (now_us >= deadline_us) {
        std::fprintf(stderr,
                     "pixel-reset: detach follow-up fence deadline expired; "
                     "presenter remains attached\n");
        return false;
      }
      const uint32_t remaining_ms = static_cast<uint32_t>(
          std::max<uint64_t>(1, (deadline_us - now_us + 999u) / 1000u));
      const PlutoPresenterOps *ops = config_.presenter_ops;
      PlutoPresenter *presenter = config_.presenter;
      if (!presenter_ops_are_current(ops) || presenter == nullptr) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        continue;
      }
      const PlutoStatus status = ops->wait_idle(presenter, remaining_ms);
      drain_completions_locked();
      if (status == kPlutoStatusDeviceLost) {
        std::fprintf(stderr, "pixel-reset: presenter lost while fencing detach "
                             "follow-up\n");
        return false;
      }
      if (status == kPlutoStatusOk) {
        // An idle presenter can still decline scheduler admission (for
        // example, an independent backpressure gate). Avoid a tight retry
        // loop while preserving the caller's absolute deadline.
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
  }

  if (presenter_ops_are_current(config_.presenter_ops) &&
      config_.presenter != nullptr) {
    const PlutoPresenterOps *ops = config_.presenter_ops;
    PlutoPresenter *presenter = config_.presenter;
    // Keep mutex_ across the final idle fence. Completion callbacks are
    // enqueue-only and do not need it, while releasing it here would let a
    // late Flutter raster submit fresh presenter work after wait_idle sampled
    // idle but before this function reset the scheduler and closed the backend.
    const uint64_t now_us = monotonic_us();
    const uint32_t remaining_ms =
        now_us >= deadline_us ? 0u
                              : static_cast<uint32_t>(std::max<uint64_t>(
                                    1, (deadline_us - now_us + 999u) / 1000u));
    const PlutoStatus status = ops->wait_idle(presenter, remaining_ms);
    idle = status == kPlutoStatusOk;
  }
  if (!idle) {
    return false;
  }
  // wait_idle guarantees that a real-completion presenter has delivered every
  // callback, but those callbacks are enqueue-only and may still be waiting in
  // completion_queue_. Drain them against the OLD scheduler before destroying
  // it. RegionScheduler frame ids restart at 1 after attach/configure; carrying
  // an old id across that boundary could otherwise retire unrelated new work.
  drain_completions_locked();
  // That drain can unpark user truth which was blocked behind the just-fenced
  // request. Run and re-fence every such item before serializing the exact
  // retained mirror. Maintenance is deliberately disabled: queued settles
  // repaint the same retained content, and their unpaid debt is part of the
  // handoff payload rather than a reason to delay an app switch.
  bool handoff_scheduler_quiescent = true;
  if (scheduler_ != nullptr && scheduler_->user_work_pending()) {
    for (;;) {
      const uint64_t now_us = monotonic_us();
      if (now_us >= deadline_us) {
        handoff_scheduler_quiescent = false;
        break;
      }
      scheduler_->tick(now_us, /*maintenance_allowed=*/false,
                       /*intrusive_maintenance_allowed=*/false);
      drain_completions_locked();
      if (!scheduler_->user_work_pending() &&
          !scheduler_->anything_inflight()) {
        break;
      }

      const PlutoPresenterOps *ops = config_.presenter_ops;
      PlutoPresenter *presenter = config_.presenter;
      if (!presenter_ops_are_current(ops) || presenter == nullptr) {
        handoff_scheduler_quiescent = false;
        break;
      }
      const uint64_t wait_now_us = monotonic_us();
      if (wait_now_us >= deadline_us) {
        handoff_scheduler_quiescent = false;
        break;
      }
      const uint32_t remaining_ms = static_cast<uint32_t>(
          std::max<uint64_t>(1, (deadline_us - wait_now_us + 999u) / 1000u));
      const PlutoStatus status = ops->wait_idle(presenter, remaining_ms);
      drain_completions_locked();
      if (status == kPlutoStatusDeviceLost) {
        std::fprintf(stderr,
                     "pluto: presenter lost while draining user work for "
                     "handoff\n");
        return false;
      }
      if (status != kPlutoStatusOk) {
        return false;
      }
      // An Ok presenter fence without its promised completion callback cannot
      // authorize renderer-state serialization. Keep detach conservative and
      // let the next owner cold-clear instead of inferring completion.
      if (!scheduler_->user_work_pending() && scheduler_->anything_inflight()) {
        handoff_scheduler_quiescent = false;
        break;
      }
      if (scheduler_->user_work_pending() && !scheduler_->anything_inflight()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
  }
  if (handoff_scheduler_quiescent && scheduler_ != nullptr &&
      !scheduler_->user_work_pending() && !scheduler_->anything_inflight()) {
    handoff_scheduler_quiescent =
        scheduler_->discard_pending_maintenance_for_handoff();
  }
  // Stage the renderer half while its old scheduler, exact retained mirror,
  // and every persistent debt/history plane still form one immutable
  // transaction. The presenter performs the deeper engine/scan barrier and
  // copies the bytes synchronously. Any unsafe renderer condition simply
  // skips staging; detach itself continues and the next process cold-clears.
  if (handoff_scheduler_quiescent) {
    try_stage_handoff_locked(deadline_us);
  } else if (presenter_ops_are_current(config_.presenter_ops)) {
    std::fprintf(stderr,
                 "pluto: renderer handoff quiescence failed user_pending=%d "
                 "settle_pending=%d inflight=%d\n",
                 scheduler_ != nullptr && scheduler_->user_work_pending(),
                 scheduler_ != nullptr && scheduler_->settle_work_pending(),
                 scheduler_ != nullptr && scheduler_->anything_inflight());
  }
  // Discard scheduler bookkeeping tied to the old presenter (especially its
  // in-flight completion ids). configure() recreates it on attach using the
  // current glass-handoff seed.
  scheduler_.reset();
  config_.presenter_ops = nullptr;
  config_.presenter = nullptr;
  valid_ = false;
  return idle;
}

bool FrameRenderer::attach_presenter(const PlutoPresenterOps *presenter_ops,
                                     PlutoPresenter *presenter) {
  if (!presenter_ops_are_current(presenter_ops) || presenter == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  config_.presenter_ops = presenter_ops;
  config_.presenter = presenter;
  next_presenter_health_poll_us_ = 0;
  configure(width_, height_, format_);
  valid_ = components_valid();
  return valid_;
}

// The Stage-6 classification path. On a verified MOVE(dy):
// ghost debt translates with the content, the disocclusion strip is fresh
// quality-first damage, the translated body presents as Fast under motion
// masking — PACED to one body drive per scroll_body_emit_px of accumulated
// translation (intermediate positions are perceptually masked and the armed
// post-scroll settle repaints the final body when the gesture rests).
void FrameRenderer::classify_damage(uint64_t now_us) {
  submit_rects_.clear();
  submit_classes_.clear();
  pen_only_damage_rects_.clear();
  ladder_.begin_pass(ledger_.epoch(), tile_pass_.dirty_tiles().data(),
                     tile_pass_.dirty_tiles().size());
  const GhostLedger *ghost = ghost_ledger_.valid() ? &ghost_ledger_ : nullptr;

  ScrollMove move{};
  if (scroll_detect_.detect(ledger_, tile_pass_.dirty_bounds(), &move)) {
    ++scroll_moves_;
    // Ghost debt follows the content (whole tile rows at a time; sub-tile
    // deltas accumulate across MOVE frames).
    scroll_ledger_shift_px_ += move.dy;
    const int32_t tile_px = static_cast<int32_t>(ledger_.tile_px());
    const int32_t shift_tiles = scroll_ledger_shift_px_ / tile_px;
    if (shift_tiles != 0 && ghost != nullptr) {
      ghost_ledger_.translate_rows(move.band, shift_tiles);
      scroll_ledger_shift_px_ -= shift_tiles * tile_px;
    }
    // Disocclusion strip: fresh content, quality-first (never Fast).
    if (!rect_is_empty(move.strip)) {
      const LadderDecision strip_decision =
          ladder_.classify(move.strip, ledger_.stats(), ghost);
      submit_rects_.push_back(move.strip);
      submit_classes_.push_back(
          promote_refresh_class(strip_decision.cls, kPlutoRefreshUi));
    }
    // Motion-masked body pacing.
    scroll_pending_px_ +=
        static_cast<uint32_t>(move.dy < 0 ? -move.dy : move.dy);
    const bool body_emitted =
        scroll_pending_px_ >= config_.renderer_config.scroll_body_emit_px &&
        !rect_is_empty(move.body);
    if (body_emitted) {
      submit_rects_.push_back(move.body);
      submit_classes_.push_back(kPlutoRefreshFast);
      scroll_pending_px_ = 0;
    }
    // Residual damage outside the moved band classifies normally. Only
    // rects FULLY inside the band are covered by the strip/body/settle
    // trio; a rect merely overlapping the band edge (a header/ticker run
    // merged with the scrolled body) keeps content OUTSIDE the band that
    // nothing else would ever present — dropping it loses that damage
    // permanently (no ghost debt accrues on unsubmitted rects, so no
    // settle repaints it). Classifying the whole rect double-covers its
    // in-band part, which is harmless: presents are idempotent reads of
    // the settled ledger.
    for (const PlutoRect &rect : damage_rects_) {
      if (rect_contains(move.band, rect)) {
        // When body pacing suppresses this frame, preserve only the exact
        // portion not already covered by the always-submitted disocclusion
        // strip. route_pen_damage() may promote these real app pixels if a
        // hover/contact hint matches; unmatched pieces remain suppressed, so
        // a nearby pen cannot accidentally disable whole-body scroll pacing.
        if (!body_emitted) {
          PlutoRect uncovered[4]{};
          const size_t uncovered_count =
              PenRenderPolicy::subtract_rect(rect, move.strip, uncovered);
          for (size_t i = 0; i < uncovered_count; ++i) {
            pen_only_damage_rects_.push_back(uncovered[i]);
          }
        }
        continue;
      }
      const LadderDecision decision =
          ladder_.classify(rect, ledger_.stats(), ghost);
      submit_rects_.push_back(rect);
      submit_classes_.push_back(decision.cls);
    }
    // One quality settle for the whole band, re-armed every MOVE frame so
    // it fires ~settle_quiesce after the motion rests.
    settle_planner_.arm_scroll_settle(move.band, now_us);
    return;
  }

  scroll_pending_px_ = 0; // gesture rest: the armed settle owns the body
  int64_t scenecut_area = 0;
  for (const PlutoRect &rect : damage_rects_) {
    const LadderDecision decision =
        ladder_.classify(rect, ledger_.stats(), ghost);
    if (decision.rung == LadderRung::kScenecut) {
      scenecut_area += rect_area(rect);
    }
    submit_rects_.push_back(rect);
    submit_classes_.push_back(decision.cls);
  }
  // Preserved whole-screen promotion (old structural_full_screen behavior):
  // when scenecut-rung damage covers most of the panel, ONE whole-screen
  // update replaces the frame's rect set — everything else is subsumed by
  // it. The CLASS is panel-dependent, mirroring the ladder and the settle
  // planner: Full/GC16 inverts the whole screen to a negative for ~1 s on
  // every big view switch (the "black squares" complaint), so gray glass
  // takes the non-flash Text quality pass; color glass keeps Full for the
  // Gallery-3 pigment develop.
  const int64_t panel_area =
      static_cast<int64_t>(width_) * static_cast<int64_t>(height_);
  if (scenecut_area * 100 >= panel_area * scenecut_full_screen_percent_) {
    submit_rects_.clear();
    submit_classes_.clear();
    submit_rects_.push_back(PlutoRect{0, 0, static_cast<int32_t>(width_),
                                      static_cast<int32_t>(height_)});
    submit_classes_.push_back(panel_is_color_ ? kPlutoRefreshFull
                                              : kPlutoRefreshText);
  }
}

// Merges the tile pass's exact per-tile dirty rects into the damage set the
// scheduler consumes: union when overlap makes merging free or the gap is
// small, then merge the cheapest pairs down to the cap. Rects stay exact
// post-quantize (no alignment padding).
size_t FrameRenderer::merge_damage() {
  damage_rects_.clear();
  const std::vector<DirtyTileRecord> &records = tile_pass_.dirty_tiles();
  if (records.empty()) {
    return 0;
  }
  const uint32_t tile_cols = ledger_.tile_cols();

  // Records are tile-row-major: fold horizontal runs first so the pairwise
  // phase below runs over row runs, not individual tiles.
  size_t i = 0;
  while (i < records.size()) {
    PlutoRect run = records[i].dirty;
    uint32_t prev_idx = records[i].tile_idx;
    size_t j = i + 1;
    while (j < records.size() && records[j].tile_idx == prev_idx + 1 &&
           (records[j].tile_idx % tile_cols) != 0) {
      const PlutoRect &next = records[j].dirty;
      if (rect_merge_waste(run, next) > 0 &&
          rect_gap_px(run, next) > k_merge_gap_px) {
        break;
      }
      run = rect_union(run, next);
      prev_idx = records[j].tile_idx;
      ++j;
    }
    damage_rects_.push_back(run);
    i = j;
  }

  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t a = 0; a < damage_rects_.size() && !changed; ++a) {
      for (size_t b = a + 1; b < damage_rects_.size(); ++b) {
        if (rect_merge_waste(damage_rects_[a], damage_rects_[b]) <= 0 ||
            rect_gap_px(damage_rects_[a], damage_rects_[b]) <= k_merge_gap_px) {
          damage_rects_[a] = rect_union(damage_rects_[a], damage_rects_[b]);
          damage_rects_[b] = damage_rects_.back();
          damage_rects_.pop_back();
          changed = true;
          break;
        }
      }
    }
  }

  while (damage_rects_.size() > k_max_damage_rects) {
    size_t best_a = 0;
    size_t best_b = 1;
    int64_t best_waste = rect_merge_waste(damage_rects_[0], damage_rects_[1]);
    for (size_t a = 0; a < damage_rects_.size(); ++a) {
      for (size_t b = a + 1; b < damage_rects_.size(); ++b) {
        const int64_t waste =
            rect_merge_waste(damage_rects_[a], damage_rects_[b]);
        if (waste < best_waste) {
          best_waste = waste;
          best_a = a;
          best_b = b;
        }
      }
    }
    damage_rects_[best_a] =
        rect_union(damage_rects_[best_a], damage_rects_[best_b]);
    damage_rects_[best_b] = damage_rects_.back();
    damage_rects_.pop_back();
  }
  return damage_rects_.size();
}

// The tile pass records whether any actually changed pixel in a dirty tile
// changed to or from chromatic RGB565 content (TileStats.changed_chroma).
// Mark only those tiles in the chroma-pending set. The convert path crushes
// chroma below Full, so the settle planner must know which tiles carry
// undeveloped color to settle them as a Full-class update (doc 03 sections 6
// and 8). Only color panels pay attention -- a gray sink cannot develop it.
void FrameRenderer::mark_chroma_tiles() {
  if (!panel_is_color_ || format_ != kPlutoPixelFormatRgb565 ||
      !chroma_pending_.valid()) {
    return;
  }
  const int32_t tile_px = static_cast<int32_t>(ledger_.tile_px());
  for (const DirtyTileRecord &record : tile_pass_.dirty_tiles()) {
    if (record.stats.changed_chroma == 0) {
      continue;
    }
    const int32_t tile_x =
        static_cast<int32_t>(record.tile_idx % ledger_.tile_cols());
    const int32_t tile_y =
        static_cast<int32_t>(record.tile_idx / ledger_.tile_cols());
    chroma_pending_.mark(
        PlutoRect{tile_x * tile_px, tile_y * tile_px, tile_px, tile_px});
    ++chroma_marked_tiles_;
  }
}

bool FrameRenderer::has_chroma_sensitive_rgb565_change(
    const PlutoFramePacket &packet) const {
  if (!retained_content_ready_ || packet.pixels == nullptr ||
      packet.format != kPlutoPixelFormatRgb565 || retained_frame_.empty()) {
    return false;
  }
  const auto has_chroma = [this](uint16_t pixel) {
    const int32_t r = static_cast<int32_t>((pixel >> 11u) & 0x1fu) << 3;
    const int32_t g = static_cast<int32_t>((pixel >> 5u) & 0x3fu) << 2;
    const int32_t b = static_cast<int32_t>(pixel & 0x1fu) << 3;
    const int32_t magnitude =
        std::max({std::abs(r - g), std::abs(r - b), std::abs(g - b)});
    return magnitude > config_.renderer_config.chroma_floor;
  };
  const auto scan = [&](const PlutoRect &requested) {
    const PlutoRect rect = rect_clip(requested, static_cast<int32_t>(width_),
                                     static_cast<int32_t>(height_));
    for (int32_t y = rect.y; y < rect_bottom(rect); ++y) {
      const auto *current = reinterpret_cast<const uint16_t *>(
          static_cast<const uint8_t *>(packet.pixels) +
          static_cast<size_t>(y) * packet.row_bytes);
      const auto *previous = reinterpret_cast<const uint16_t *>(
          retained_frame_.data() + static_cast<size_t>(y) * stride_);
      for (int32_t x = rect.x; x < rect_right(rect); ++x) {
        if (current[x] != previous[x] &&
            (has_chroma(current[x]) || has_chroma(previous[x]))) {
          return true;
        }
      }
    }
    return false;
  };
  if (packet.paint_bounds == nullptr || packet.paint_bounds_count == 0) {
    return scan(PlutoRect{0, 0, static_cast<int32_t>(width_),
                          static_cast<int32_t>(height_)});
  }
  for (size_t i = 0; i < packet.paint_bounds_count; ++i) {
    if (scan(packet.paint_bounds[i])) {
      return true;
    }
  }
  return false;
}

void FrameRenderer::open_frame_recorder() {
  const char *path = std::getenv("PLUTO_RECORD_FRAMES");
  if (path == nullptr || path[0] == '\0') {
    return;
  }
  record_file_ = std::fopen(path, "wb");
  if (record_file_ == nullptr) {
    std::fprintf(stderr, "pluto: PLUTO_RECORD_FRAMES: cannot open %s\n", path);
    return;
  }
  if (!record_write_u32(record_file_, frame_recording::kFileMagic)) {
    std::fprintf(stderr, "pluto: PLUTO_RECORD_FRAMES: write failed; "
                         "recording disabled\n");
    std::fclose(record_file_);
    record_file_ = nullptr;
  }
}

void FrameRenderer::record_frame(const PlutoFramePacket &packet) {
  if (record_file_ == nullptr) {
    return;
  }
  const size_t bpp = bytes_per_pixel(packet.format);
  const size_t row_bytes = static_cast<size_t>(packet.width) * bpp;
  if (packet.paint_bounds_count > std::numeric_limits<uint32_t>::max() ||
      (packet.did_update && packet.height != 0 &&
       row_bytes > std::numeric_limits<size_t>::max() / packet.height)) {
    std::fprintf(stderr, "pluto: PLUTO_RECORD_FRAMES: frame is too large; "
                         "recording disabled\n");
    std::fclose(record_file_);
    record_file_ = nullptr;
    return;
  }
  const size_t payload_size =
      packet.did_update ? row_bytes * packet.height : 0u;
  const size_t bounds_size = packet.paint_bounds_count * sizeof(PlutoRect);
  if (payload_size > std::numeric_limits<uint32_t>::max() ||
      bounds_size > frame_recording::kMaximumFrameBytes -
                        frame_recording::kMinimumFrameBytes ||
      payload_size > frame_recording::kMaximumFrameBytes -
                         frame_recording::kMinimumFrameBytes - bounds_size) {
    std::fprintf(stderr, "pluto: PLUTO_RECORD_FRAMES: frame is too large; "
                         "recording disabled\n");
    std::fclose(record_file_);
    record_file_ = nullptr;
    return;
  }
  const size_t frame_size =
      frame_recording::kMinimumFrameBytes + bounds_size + payload_size;
  const uint32_t payload_bytes = static_cast<uint32_t>(payload_size);
  const uint32_t frame_bytes = static_cast<uint32_t>(frame_size);
  uint32_t crc = frame_recording::kCrc32Initial;
  bool ok =
      record_write_u32_crc(record_file_, frame_recording::kFrameMagic, &crc) &&
      record_write_u32_crc(record_file_, frame_bytes, &crc) &&
      record_write_u64_crc(record_file_, packet.presentation_time_ns, &crc) &&
      record_write_u32_crc(record_file_, packet.width, &crc) &&
      record_write_u32_crc(record_file_, packet.height, &crc) &&
      record_write_u32_crc(record_file_, static_cast<uint32_t>(packet.format),
                           &crc) &&
      record_write_u32_crc(record_file_, packet.did_update ? 1u : 0u, &crc) &&
      record_write_u32_crc(record_file_,
                           static_cast<uint32_t>(packet.paint_bounds_count),
                           &crc) &&
      record_write_u32_crc(record_file_, payload_bytes, &crc);
  for (size_t i = 0; ok && i < packet.paint_bounds_count; ++i) {
    ok = record_write_crc(record_file_, &packet.paint_bounds[i],
                          sizeof(PlutoRect), &crc);
  }
  if (ok && payload_bytes != 0) {
    const auto *pixels = static_cast<const uint8_t *>(packet.pixels);
    for (uint32_t y = 0; ok && y < packet.height; ++y) {
      ok = record_write_crc(record_file_,
                            pixels + static_cast<size_t>(y) * packet.row_bytes,
                            row_bytes, &crc);
    }
  }
  const uint32_t checksum = frame_recording::crc32_finish(crc);
  ok = ok && record_write_u32(record_file_, checksum);
  if (!ok) {
    std::fprintf(stderr, "pluto: PLUTO_RECORD_FRAMES: write failed; "
                         "recording disabled\n");
    std::fclose(record_file_);
    record_file_ = nullptr;
    return;
  }
  std::fflush(record_file_);
}

void FrameRenderer::retire_forced_settles_locked(
    const PlutoPresentRequest &request) {
  for (size_t i = 0; i < request.damage_count; ++i) {
    settle_planner_.retire_forced(request.damage[i]);
  }
}

void FrameRenderer::notify_present_complete(uint64_t frame_id) {
  // Completion contract (presenter.h:96-99): this runs on an internal
  // presenter thread -- possibly still on the present() stack -- so it may
  // only enqueue. Taking mutex_ here deadlocks a synchronous-completion
  // presenter and stalls e-ink flip threads behind multi-ms ticks.
  if (!completion_queue_.push(frame_id)) {
    dropped_completions_.fetch_add(1, std::memory_order_relaxed);
  }
  wake_.store(true, std::memory_order_release);
  cv_.notify_one();
}

size_t FrameRenderer::queued_present_completions_for_testing() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return completion_queue_.size_approx_for_testing();
}

uint64_t FrameRenderer::decision_now_us() const {
  if (config_.monotonic_now_for_testing != nullptr) {
    return config_.monotonic_now_for_testing(
        config_.monotonic_now_context_for_testing);
  }
  return monotonic_us();
}

void FrameRenderer::copy_rect_from_packet(const PlutoFramePacket &packet,
                                          const PlutoRect &rect) {
  const size_t bpp = bytes_per_pixel(format_);
  const uint8_t *src = static_cast<const uint8_t *>(packet.pixels);
  const size_t row_bytes = static_cast<size_t>(rect.width) * bpp;
  for (int32_t y = 0; y < rect.height; ++y) {
    const size_t src_offset =
        static_cast<size_t>(rect.y + y) * packet.row_bytes +
        static_cast<size_t>(rect.x) * bpp;
    const size_t dst_offset = static_cast<size_t>(rect.y + y) * stride_ +
                              static_cast<size_t>(rect.x) * bpp;
    std::memcpy(retained_frame_.data() + dst_offset, src + src_offset,
                row_bytes);
  }
}

void FrameRenderer::sync_pen_focus_locked(uint64_t now_us) {
  if (pen_focus_clear_requested_.exchange(false, std::memory_order_acq_rel)) {
    if (scheduler_ != nullptr) {
      scheduler_->clear_pen_focus();
    }
    if (!config_.presenter_pen_focus_from_host &&
        !clear_presenter_pen_focus_locked()) {
      // Transient hook failures are retryable. Preserve the clear edge until
      // the backend has actually observed it; otherwise a one-shot range exit
      // could leave mapped truth reserved forever.
      pen_focus_clear_requested_.store(true, std::memory_order_release);
      wake_.store(true, std::memory_order_release);
      cv_.notify_one();
    }
    last_pen_focus_hint_sequence_ = 0;
    pen_focus_expires_us_ = 0;
  }
  if (scheduler_ == nullptr || !pen_render_policy_.valid()) {
    if (!config_.presenter_pen_focus_from_host &&
        !clear_presenter_pen_focus_locked()) {
      pen_focus_clear_requested_.store(true, std::memory_order_release);
      wake_.store(true, std::memory_order_release);
      cv_.notify_one();
    }
    return;
  }
  const PenRenderHintMailbox::Batch hints = pen_hint_mailbox_.snapshot();
  if (hints.count == 0) {
    return;
  }
  const PenRenderHintSnapshot &latest = hints.entries[hints.count - 1].hint;
  PenRenderHintSnapshot focus_hint = latest;
  if (latest.in_range) {
    // The mailbox's active position is intentionally sticky: some digitizers
    // emit no additional SYN while the pen is motionless, yet an app may keep
    // animating a hover indicator. Only a real terminal/clear releases this
    // reservation; repeatedly applying a finite stale timestamp would reopen
    // the completion-to-next-frame race after one lease interval.
    pen_focus_expires_us_ = UINT64_MAX;
    const PlutoRect active_focus = pen_render_policy_.focus_rect(latest);
    if (!config_.presenter_pen_focus_from_host) {
      if (rect_is_empty(active_focus)) {
        if (!clear_presenter_pen_focus_locked()) {
          pen_focus_clear_requested_.store(true, std::memory_order_release);
          wake_.store(true, std::memory_order_release);
          cv_.notify_one();
        }
      } else {
        publish_presenter_pen_focus_locked(active_focus, latest.contact,
                                           latest.sequence);
      }
    }
  } else {
    // The scheduler keeps a short terminal ROI solely so verified app pixels
    // may erase a hover cursor. The backend reservation itself ends exactly
    // at range exit; it must not defer truth until that terminal lease expires.
    if (!config_.presenter_pen_focus_from_host &&
        !clear_presenter_pen_focus_locked()) {
      pen_focus_clear_requested_.store(true, std::memory_order_release);
      wake_.store(true, std::memory_order_release);
      cv_.notify_one();
    }
    focus_hint.in_range = true;
    focus_hint.contact = false;
    if (latest.sequence != last_pen_focus_hint_sequence_) {
      pen_focus_expires_us_ = now_us > UINT64_MAX - k_pen_focus_release_lease_us
                                  ? UINT64_MAX - 1
                                  : now_us + k_pen_focus_release_lease_us;
    }
  }
  last_pen_focus_hint_sequence_ = latest.sequence;
  const PlutoRect focus = pen_render_policy_.focus_rect(focus_hint);
  if (rect_is_empty(focus) || pen_focus_expires_us_ == 0) {
    scheduler_->clear_pen_focus();
    return;
  }
  scheduler_->reserve_pen_focus(focus, pen_focus_expires_us_);
}

void FrameRenderer::publish_presenter_pen_focus_locked(
    const PlutoRect &logical_focus, bool contact, uint64_t sequence) {
  const PlutoPresenterOps *ops = config_.presenter_ops;
  PlutoPresenter *presenter = config_.presenter;
  if (!presenter_ops_are_current(ops) || presenter == nullptr) {
    presenter_pen_focus_active_ = false;
    return;
  }
  const PlutoRect physical =
      presenter_focus_rect(logical_focus, width_, height_, config_.rotation);
  if (rect_is_empty(physical)) {
    clear_presenter_pen_focus_locked();
    return;
  }
  if (presenter_pen_focus_active_ &&
      presenter_pen_focus_sequence_ == sequence &&
      presenter_pen_focus_contact_ == contact &&
      presenter_pen_focus_rect_.x == physical.x &&
      presenter_pen_focus_rect_.y == physical.y &&
      presenter_pen_focus_rect_.width == physical.width &&
      presenter_pen_focus_rect_.height == physical.height) {
    return;
  }
  const PlutoPenFocus focus{
      sizeof(PlutoPenFocus), physical,
      static_cast<uint32_t>(kPlutoPenFocusInRange) |
          (contact ? static_cast<uint32_t>(kPlutoPenFocusContact) : 0u),
      sequence};
  if (ops->set_pen_focus(presenter, &focus) != kPlutoStatusOk) {
    return; // retry on the next renderer tick; no pixel work is synthesized
  }
  presenter_pen_focus_active_ = true;
  presenter_pen_focus_contact_ = contact;
  presenter_pen_focus_rect_ = physical;
  presenter_pen_focus_sequence_ = sequence;
}

bool FrameRenderer::clear_presenter_pen_focus_locked(bool force) {
  const PlutoPresenterOps *ops = config_.presenter_ops;
  PlutoPresenter *presenter = config_.presenter;
  if ((force || presenter_pen_focus_active_) &&
      presenter_ops_are_current(ops) && presenter != nullptr) {
    const PlutoPenFocus clear{sizeof(PlutoPenFocus),
                              {},
                              kPlutoPenFocusNone,
                              presenter_pen_focus_sequence_};
    const PlutoStatus status = ops->set_pen_focus(presenter, &clear);
    if (status != kPlutoStatusOk && status != kPlutoStatusUnsupported) {
      return false;
    }
  }
  presenter_pen_focus_active_ = false;
  presenter_pen_focus_contact_ = false;
  presenter_pen_focus_rect_ = {};
  return true;
}

bool FrameRenderer::poll_presenter_health_locked(uint64_t now_us,
                                                 bool *presenter_idle) {
  if (presenter_idle != nullptr) {
    *presenter_idle = false;
  }
  if (presenter_device_lost_notified_.load(std::memory_order_acquire)) {
    return true;
  }
  const PlutoPresenterOps *ops = config_.presenter_ops;
  PlutoPresenter *presenter = config_.presenter;
  if (presenter == nullptr || !presenter_ops_are_current(ops)) {
    return false;
  }
  constexpr uint64_t kHealthPollIntervalUs = 250'000;
  if (next_presenter_health_poll_us_ != 0 &&
      now_us < next_presenter_health_poll_us_) {
    return false;
  }
  next_presenter_health_poll_us_ = now_us > UINT64_MAX - kHealthPollIntervalUs
                                       ? UINT64_MAX
                                       : now_us + kHealthPollIntervalUs;
  const PlutoStatus status = ops->wait_idle(presenter, 0);
  if (status != kPlutoStatusDeviceLost) {
    if (presenter_idle != nullptr && status == kPlutoStatusOk) {
      *presenter_idle = true;
    }
    return false;
  }
  notify_presenter_device_lost();
  return true;
}

void FrameRenderer::tick_locked(uint64_t now_us) {
  drain_completions_locked();
  if (scheduler_ != nullptr) {
    scheduler_->poll_completions(now_us);
    if (health_file_ != nullptr && scheduler_->real_completion_overdue()) {
      health_file_failed_ = true;
      valid_ = false;
      std::fprintf(stderr,
                   "pluto: presenter completion exceeded health deadline\n");
      if (config_.on_health_file_failure) {
        config_.on_health_file_failure();
      }
      return;
    }
  }
  // Async scan/color faults can arise after present() returned Ok. A bounded
  // nonblocking health sample closes that otherwise silent failure edge even
  // when no later frame is queued. Four polls per second is negligible beside
  // the existing 25 Hz idle renderer tick.
  bool presenter_idle = false;
  if (poll_presenter_health_locked(now_us, &presenter_idle)) {
    return;
  }
  maybe_publish_health_locked(now_us, presenter_idle);
  if (health_file_failed_) {
    return;
  }
  if (advance_pixel_reset_locked(now_us)) {
    return;
  }
  const bool automatic_policy_enabled =
      config_.enable_auto_ghostbuster && auto_ghostbuster_.valid() &&
      scheduler_ != nullptr && retained_content_ready_;
  if (automatic_policy_enabled) {
    const uint8_t input_mask =
        active_input_mask_.load(std::memory_order_acquire);
    auto_ghostbuster_.note_input_state(
        (input_mask & kTouchInputBit) != 0, (input_mask & kPenInputBit) != 0,
        last_input_change_us_.load(std::memory_order_acquire));
  }
  const bool maintenance_allowed = maintenance_allowed_locked();
  const bool intrusive_maintenance_allowed =
      intrusive_maintenance_allowed_locked(now_us);
  // The settle planner runs before the scheduler so a burst it emits can
  // dispatch on this same tick (decays ledgers, checks quiescence, feeds
  // SETTLE-class requests into the scheduler's CBS-budgeted queue).
  settle_planner_.tick(now_us, scheduler_.get(), maintenance_allowed,
                       intrusive_maintenance_allowed);
  if (scheduler_ != nullptr) {
    // Last operation before dispatch: proximity is published lock-free by the
    // SCHED_FIFO input thread and may have arrived during completion drain or
    // maintenance planning.
    sync_pen_focus_locked(now_us);
    scheduler_->tick(now_us, maintenance_allowed,
                     intrusive_maintenance_allowed);
  }
  // Cheap regional Text repayment gets the first opportunity at the same
  // idle boundary. Only seize the whole display if that work did not leave
  // anything queued/in-flight and broad debt remains latched afterwards.
  if (automatic_policy_enabled) {
    const AutoGhostbusterGateState gate{
        /*scheduler_idle=*/scheduler_->idle(),
        /*presentation_suspended=*/presentation_suspended_,
        /*maintenance_allowed=*/
        auto_maintenance_allowed_.load(std::memory_order_acquire)};
    const AutoGhostbusterDecision decision =
        auto_ghostbuster_.try_begin_action(now_us, gate);
    if (decision != AutoGhostbusterDecision::kNone) {
      if (begin_auto_ghost_control_locked(decision, now_us)) {
        (void)advance_pixel_reset_locked(now_us);
        return;
      }
      (void)auto_ghostbuster_.complete_action(false, now_us);
    }
  }
}

bool FrameRenderer::maintenance_allowed_locked() const {
  return !presentation_suspended_ &&
         auto_maintenance_allowed_.load(std::memory_order_acquire);
}

bool FrameRenderer::intrusive_maintenance_allowed_locked(
    uint64_t now_us) const {
  if (!maintenance_allowed_locked() ||
      active_input_mask_.load(std::memory_order_acquire) != 0) {
    return false;
  }
  const uint64_t last_input_us =
      last_input_change_us_.load(std::memory_order_acquire);
  if (last_input_us == 0) {
    return true;
  }
  return now_us >= last_input_us &&
         now_us - last_input_us >=
             config_.auto_ghostbuster_config.input_release_grace_us;
}

void FrameRenderer::set_pixel_reset_render_hold_locked(bool held) {
  if (pixel_reset_render_hold_ == held) {
    return;
  }
  pixel_reset_render_hold_ = held;
  if (config_.set_flutter_rendering_paused) {
    config_.set_flutter_rendering_paused(held);
  }
  std::fprintf(stderr, "pixel-reset: Flutter raster %s\n",
               held ? "held" : "resumed");
}

void FrameRenderer::finish_pixel_reset_locked(bool success, uint64_t now_us) {
  set_pixel_reset_render_hold_locked(false);
  if (success &&
      pixel_reset_auto_decision_ == AutoGhostbusterDecision::kBlink) {
    // Blink's retained-content stage intentionally stays Fast, so the
    // RegionScheduler does not clear its older local settle ledger for us.
    // The full-screen black/white cycle physically repaid that gray ghost;
    // remove the duplicate obligation without forgiving pigment/stress.
    ghost_ledger_.clear(PlutoRect{0, 0, static_cast<int32_t>(width_),
                                  static_cast<int32_t>(height_)});
  }
  if (pixel_reset_auto_decision_ != AutoGhostbusterDecision::kNone) {
    (void)auto_ghostbuster_.complete_action(success, now_us);
  } else if (success && auto_ghostbuster_.valid()) {
    // Every public/manual production operation is at least BleachNow, or the
    // empirically safer composed BlinkNow. It physically repays both planes.
    auto_ghostbuster_.acknowledge_external_action(
        AutoGhostbusterDecision::kBoth, now_us);
  }
  pixel_reset_phase_ = PixelResetPhase::kIdle;
  pixel_reset_auto_decision_ = AutoGhostbusterDecision::kNone;
  pixel_reset_interrupted_ = false;
  pixel_reset_cycles_remaining_ = 0;
  pixel_reset_deadline_us_ = 0;
  pixel_reset_abort_deadline_us_ = 0;
}

bool FrameRenderer::advance_pixel_reset_locked(uint64_t now_us) {
  if (pixel_reset_phase_ == PixelResetPhase::kIdle || scheduler_ == nullptr) {
    return false;
  }
  scheduler_->poll_completions(now_us);
  const PlutoRect full{0, 0, static_cast<int32_t>(width_),
                       static_cast<int32_t>(height_)};

  // The optical state machine keeps ownership until retained content has
  // really been restored. At the secondary bound, release Flutter raster so
  // Dart/UI work can continue into the retained ledger, but continue holding
  // ordinary panel presents and retry recovery; never abandon black/white
  // glass merely to satisfy a wall-clock timeout.
  if (now_us >= pixel_reset_abort_deadline_us_ && pixel_reset_render_hold_) {
    std::fprintf(stderr,
                 "pixel-reset: recovery delayed; releasing Flutter raster "
                 "while panel restore remains serialized\n");
    set_pixel_reset_render_hold_locked(false);
  }

  // A real presenter may have finished while its completion callback was
  // dropped (for example, the bounded callback queue overflowed).  Once the
  // action reaches its recovery deadline, ask the device itself before
  // deciding that any reset stage is still in flight.  This applies to the
  // retained-content stages too: otherwise a lost final callback would leave
  // ordinary presentation serialized forever even though the panel is idle.
  if (now_us >= pixel_reset_deadline_us_ && scheduler_->anything_inflight() &&
      presenter_ops_are_current(config_.presenter_ops) &&
      config_.presenter != nullptr &&
      config_.presenter_ops->wait_idle(config_.presenter, 0) ==
          kPlutoStatusOk) {
    (void)scheduler_->retire_pixel_reset_after_presenter_idle();
  }

  if (now_us >= pixel_reset_deadline_us_ &&
      pixel_reset_phase_ != PixelResetPhase::kRestore &&
      pixel_reset_phase_ != PixelResetPhase::kAbortRestore) {
    if (pixel_reset_phase_ == PixelResetPhase::kPending &&
        !pixel_reset_render_hold_) {
      std::fprintf(stderr,
                   "pixel-reset: timed out before first rail; cancelling\n");
      finish_pixel_reset_locked(false, now_us);
      return false;
    }
    if (!scheduler_->anything_inflight() && scheduler_->discard_pending()) {
      pixel_reset_restore_generation_ = diffed_frames_;
    }
    if (!scheduler_->anything_inflight() &&
        scheduler_->submit_pixel_reset_stage(full,
                                             kPlutoPresentFlagPixelResetRestore,
                                             now_us, kPlutoRefreshFull)) {
      pixel_reset_phase_ = PixelResetPhase::kAbortRestore;
      std::fprintf(stderr, "pixel-reset: timed out; retained-content recovery "
                           "dispatched\n");
      return true;
    }
    return true;
  }

  switch (pixel_reset_phase_) {
  case PixelResetPhase::kIdle:
    return false;
  case PixelResetPhase::kPending:
    if (pixel_reset_interrupted_) {
      std::fprintf(stderr,
                   "pixel-reset: cancelled before first optical rail\n");
      finish_pixel_reset_locked(false, now_us);
      return false;
    }
    if (now_us < pixel_reset_not_before_us_) {
      return true;
    }
    if (pixel_reset_auto_decision_ != AutoGhostbusterDecision::kNone &&
        (!auto_maintenance_allowed_.load(std::memory_order_acquire) ||
         active_input_mask_.load(std::memory_order_acquire) != 0)) {
      std::fprintf(stderr,
                   "auto-ghostbuster: start cancelled by supervisor/input\n");
      finish_pixel_reset_locked(false, now_us);
      return false;
    }
    if (scheduler_->anything_inflight() || !scheduler_->discard_pending()) {
      return true;
    }
    set_pixel_reset_render_hold_locked(true);
    if (scheduler_->submit_pixel_reset_stage(
            full, kPlutoPresentFlagPixelResetBlack, now_us)) {
      pixel_reset_phase_ = PixelResetPhase::kBlack;
      std::fprintf(stderr, "pixel-reset: fast black dispatched\n");
    } else {
      set_pixel_reset_render_hold_locked(false);
    }
    return true;
  case PixelResetPhase::kBlack:
    if (scheduler_->anything_inflight()) {
      return true;
    }
    if (scheduler_->submit_pixel_reset_stage(
            full, kPlutoPresentFlagPixelResetWhite, now_us)) {
      pixel_reset_phase_ = PixelResetPhase::kWhite;
      std::fprintf(stderr,
                   "pixel-reset: black complete; fast white dispatched\n");
    }
    return true;
  case PixelResetPhase::kWhite: {
    if (scheduler_->anything_inflight()) {
      return true;
    }
    if (pixel_reset_auto_decision_ != AutoGhostbusterDecision::kNone &&
        (!auto_maintenance_allowed_.load(std::memory_order_acquire) ||
         active_input_mask_.load(std::memory_order_acquire) != 0)) {
      pixel_reset_interrupted_ = true;
    }
    if (pixel_reset_cycles_remaining_ > 1 && !pixel_reset_interrupted_) {
      const bool starting_bleach_followup =
          (pixel_reset_mode_ == GhostControlMode::kBlinkNow ||
           pixel_reset_mode_ == GhostControlMode::kBlinkLater) &&
          pixel_reset_cycles_remaining_ == kBlinkThenBleachRailCycles;
      if (scheduler_->submit_pixel_reset_stage(
              full, kPlutoPresentFlagPixelResetBlack, now_us)) {
        --pixel_reset_cycles_remaining_;
        pixel_reset_phase_ = PixelResetPhase::kBlack;
        if (starting_bleach_followup) {
          std::fprintf(stderr,
                       "pixel-reset: blink complete; bleach follow-up "
                       "dispatched elapsed_ms=%llu remaining=%u\n",
                       static_cast<unsigned long long>(
                           (now_us - pixel_reset_started_us_) / 1000),
                       pixel_reset_cycles_remaining_);
        } else {
          std::fprintf(stderr,
                       "pixel-reset: maintenance rail cycle dispatched "
                       "elapsed_ms=%llu remaining=%u\n",
                       static_cast<unsigned long long>(
                           (now_us - pixel_reset_started_us_) / 1000),
                       pixel_reset_cycles_remaining_);
        }
      }
      return true;
    }
    pixel_reset_restore_generation_ = diffed_frames_;
    const bool balanced_restore =
        pixel_reset_auto_decision_ == AutoGhostbusterDecision::kBleach ||
        pixel_reset_auto_decision_ == AutoGhostbusterDecision::kBoth ||
        pixel_reset_auto_decision_ == AutoGhostbusterDecision::kNone;
    const uint32_t restore_flags = balanced_restore
                                       ? kPlutoPresentFlagPixelResetRestore
                                       : kPlutoPresentFlagNone;
    const PlutoRefreshClass restore_class =
        balanced_restore ? kPlutoRefreshFull : kPlutoRefreshFast;
    if (scheduler_->submit_pixel_reset_stage(full, restore_flags, now_us,
                                             restore_class)) {
      pixel_reset_phase_ = PixelResetPhase::kRestore;
      std::fprintf(stderr,
                   "pixel-reset: white complete; %s content dispatched\n",
                   balanced_restore ? "balanced" : "fast");
    }
    return true;
  }
  case PixelResetPhase::kRestore:
    if (scheduler_->anything_inflight()) {
      return true;
    }
    std::fprintf(stderr, "pixel-reset: content complete total_ms=%llu\n",
                 static_cast<unsigned long long>(
                     (now_us - pixel_reset_started_us_) / 1000));
    finish_pixel_reset_locked(!pixel_reset_interrupted_, now_us);
    // If Flutter changed after the restore surface was snapshotted by the
    // presenter, queue one current-ledger Fast pass before normal partials
    // resume. This bounds the reset even for a continuously animating app.
    if (diffed_frames_ != pixel_reset_restore_generation_) {
      const PlutoRefreshClass quality = kPlutoRefreshFast;
      scheduler_->submit_damage(&full, &quality, 1, now_us);
    }
    return false;
  case PixelResetPhase::kAbortRestore:
    if (scheduler_->anything_inflight()) {
      return true;
    }
    std::fprintf(stderr, "pixel-reset: recovery content complete\n");
    {
      const bool retained_changed =
          diffed_frames_ != pixel_reset_restore_generation_;
      finish_pixel_reset_locked(false, now_us);
      if (retained_changed) {
        const PlutoRefreshClass quality = kPlutoRefreshFast;
        scheduler_->submit_damage(&full, &quality, 1, now_us);
      }
    }
    return false;
  }
  return false;
}

void FrameRenderer::drain_completions_locked() {
  uint64_t frame_id = 0;
  while (completion_queue_.pop(&frame_id)) {
    if (scheduler_ != nullptr && scheduler_->notify_completion(frame_id)) {
      // A callback is only health evidence when it names a present that this
      // scheduler actually accepted. Stale/unknown callbacks cannot arm the
      // supervisor record.
      if (presenter_completion_count_ != UINT64_MAX) {
        ++presenter_completion_count_;
      }
    }
  }
  const size_t dropped =
      dropped_completions_.exchange(0, std::memory_order_relaxed);
  if (dropped != 0) {
    std::fprintf(stderr,
                 "pluto: completion queue overflow; dropped %zu "
                 "completions\n",
                 dropped);
  }
}

void FrameRenderer::maybe_publish_health_locked(uint64_t now_us,
                                                bool presenter_idle) {
  // Leave one health-poll interval of scheduling margin below the supervisor
  // contract's one-second observed cadence.
  constexpr uint64_t kHealthPublishIntervalUs = 750'000;
  const bool completion_progressed =
      presenter_completion_count_ > health_published_completion_count_;
  if (health_file_ == nullptr || health_file_failed_ ||
      presenter_completion_count_ == 0 ||
      (!presenter_idle && !completion_progressed) ||
      (next_health_publish_us_ != 0 && now_us < next_health_publish_us_)) {
    return;
  }

  int error_code = 0;
  if (!health_file_->publish(now_us, &error_code)) {
    health_file_failed_ = true;
    valid_ = false;
    std::fprintf(stderr, "pluto: health publish failed for %s: %s\n",
                 config_.health_file_path.c_str(), std::strerror(error_code));
    if (config_.on_health_file_failure) {
      config_.on_health_file_failure();
    }
    return;
  }
  health_published_completion_count_ = presenter_completion_count_;
  next_health_publish_us_ = now_us > UINT64_MAX - kHealthPublishIntervalUs
                                ? UINT64_MAX
                                : now_us + kHealthPublishIntervalUs;
}

void FrameRenderer::mark_ready_after_present_locked() {
  if (ready_marker_attempted_ || config_.ready_file_path.empty()) {
    return;
  }
  // Claim the one publication attempt before touching the filesystem. A
  // failure deliberately leaves readiness absent and is not retried by later
  // frames: safe-boot confirmation must not drift away from the first
  // accepted present.
  ready_marker_attempted_ = true;
  int error_code = 0;
  if (!atomic_publish_ready_file(config_.ready_file_path, &error_code)) {
    std::fprintf(stderr, "pluto: ready marker publish failed for %s: %s\n",
                 config_.ready_file_path.c_str(), std::strerror(error_code));
  }
}

void FrameRenderer::run_presenter_loop() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!stop_) {
    cv_.wait_for(
        lock,
        std::chrono::milliseconds(wake_.load(std::memory_order_acquire) ? 4
                                                                        : 40),
        [this] { return stop_ || wake_.load(std::memory_order_acquire); });
    if (stop_) {
      break;
    }
    wake_.store(false, std::memory_order_release);
    tick_locked(decision_now_us());
  }
}

void FrameRenderer::shutdown() {
  bool have_presenter = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_complete_) {
      return;
    }
    have_presenter = presenter_ops_are_current(config_.presenter_ops) &&
                     config_.presenter != nullptr;
  }
  if (have_presenter) {
    // Give the optical FSM its complete 15s recovery + 5s raster-release
    // window, plus margin, before conceding an unrecoverable presenter fault.
    if (!detach_presenter(kPixelResetShutdownTimeoutMs)) {
      std::fprintf(stderr,
                   "pixel-reset: shutdown recovery exhausted; presenter "
                   "is lost or non-responsive\n");
    }
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pixel_reset_phase_ != PixelResetPhase::kIdle) {
      finish_pixel_reset_locked(false, decision_now_us());
    } else {
      set_pixel_reset_render_hold_locked(false);
    }
    stop_ = true;
    wake_.store(true, std::memory_order_release);
  }
  cv_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }
  std::lock_guard<std::mutex> lock(mutex_);
  const uint64_t hint_overwrites = pen_hint_mailbox_.overwritten_unconsumed();
  if (pen_priority_regions_ != 0 || hint_overwrites != 0) {
    std::fprintf(
        stderr,
        "renderer pen stats: regions=%zu changed_px=%llu preview_px=%llu "
        "hint_to_frame_us=%llu hint_overwrites=%llu\n",
        pen_priority_regions_,
        static_cast<unsigned long long>(pen_priority_changed_pixels_),
        static_cast<unsigned long long>(pen_priority_preview_pixels_),
        static_cast<unsigned long long>(last_pen_hint_to_frame_us_),
        static_cast<unsigned long long>(hint_overwrites));
  }
  if (record_file_ != nullptr) {
    std::fclose(record_file_);
    record_file_ = nullptr;
  }
  shutdown_complete_ = true;
}

bool FrameRenderer::presenter_ready(void *user_data, PlutoRefreshClass cls) {
  auto *self = static_cast<FrameRenderer *>(user_data);
  if (self != nullptr &&
      (self->presentation_suspended_ ||
       self->presenter_device_lost_notified_.load(std::memory_order_acquire))) {
    return false;
  }
  if (self == nullptr ||
      !presenter_ops_are_current(self->config_.presenter_ops) ||
      self->config_.presenter == nullptr) {
    return true;
  }
  return self->config_.presenter_ops->ready(self->config_.presenter, cls);
}

void FrameRenderer::notify_presenter_device_lost() {
  if (presenter_device_lost_notified_.exchange(true,
                                               std::memory_order_acq_rel)) {
    return;
  }
  std::fprintf(stderr, "pluto: presenter reported device lost; requesting cold "
                       "supervisor restart\n");
  if (config_.on_presenter_device_lost) {
    config_.on_presenter_device_lost();
  }
}

bool FrameRenderer::presenter_present(void *user_data,
                                      const PlutoPresentRequest *request) {
  auto *self = static_cast<FrameRenderer *>(user_data);
  if (self == nullptr ||
      !presenter_ops_are_current(self->config_.presenter_ops) ||
      self->config_.presenter == nullptr) {
    return true;
  }
  // Final edge check at the irreversible presenter boundary. The planner
  // and scheduler already sample the same gate, but touch/pen publication is
  // lock-free and may race that sample. Refusal leaves SETTLE work queued;
  // sparkle is best-effort and will be reconsidered after the next settle.
  const bool background =
      (request->flags & (kPlutoPresentFlagSettle | kPlutoPresentFlagSparkle)) !=
      0;
  const bool required = (request->flags & kPlutoPresentFlagRequiredSettle) != 0;
  const bool intrusive =
      (request->flags & kPlutoPresentFlagSparkle) != 0 ||
      ((request->flags & kPlutoPresentFlagPixelResetBlack) != 0 &&
       self->pixel_reset_auto_decision_ != AutoGhostbusterDecision::kNone) ||
      ((request->flags & kPlutoPresentFlagSettle) != 0 &&
       (request->refresh_class == kPlutoRefreshFull ||
        (!required && !self->presenter_controls_refresh_class_)));
  const uint64_t gate_now_us = self->decision_now_us();
  if ((background && !self->maintenance_allowed_locked()) ||
      (intrusive && !self->intrusive_maintenance_allowed_locked(gate_now_us))) {
    return false;
  }
  // Serialized by mutex_ (scheduler ticks only run under it), so the present
  // buffer needs no extra locking.
  const bool quality = quality_class(request->refresh_class);
  const bool reset_restore =
      (request->flags & kPlutoPresentFlagPixelResetRestore) != 0;
  const bool quality_retires_forced = quality && !reset_restore;
  const auto note_auto_accepted = [self, request] {
    const uint32_t maintenance_flags =
        kPlutoPresentFlagPixelResetBlack | kPlutoPresentFlagPixelResetWhite |
        kPlutoPresentFlagPixelResetRestore | kPlutoPresentFlagSparkle;
    if (self->config_.enable_auto_ghostbuster &&
        self->auto_ghostbuster_.valid() &&
        self->pixel_reset_phase_ == PixelResetPhase::kIdle &&
        (request->flags & maintenance_flags) == 0) {
      self->auto_ghostbuster_.note_accepted_present(
          request->damage, request->damage_count,
          self->presenter_controls_refresh_class_ ? request->refresh_class
                                                  : kPlutoRefreshUi,
          self->decision_now_us());
    }
  };
  if (self->bridge_.valid()) {
    // Presentation pixels come from the ledger's settled levels (gray path)
    // or the RGB565 mirror (settled color); no dispatch re-quantization.
    const PlutoPresentRequest prepared =
        self->bridge_.prepare(*request, self->ledger_);
    const PlutoStatus status = self->config_.presenter_ops->present(
        self->config_.presenter, &prepared);
    if (status == kPlutoStatusDeviceLost) {
      self->notify_presenter_device_lost();
    }
    const bool ok = status == kPlutoStatusOk;
    if (ok) {
      self->mark_ready_after_present_locked();
      note_auto_accepted();
    }
    if (ok && quality_retires_forced) {
      self->retire_forced_settles_locked(*request);
    }
    return ok;
  }
  // Bridge off (enable_present_bridge=false or no display info): raw mirror
  // bytes pass through untouched. Forced scroll bookkeeping still retires.
  const PlutoStatus status =
      self->config_.presenter_ops->present(self->config_.presenter, request);
  if (status == kPlutoStatusDeviceLost) {
    self->notify_presenter_device_lost();
  }
  const bool ok = status == kPlutoStatusOk;
  if (ok) {
    self->mark_ready_after_present_locked();
    note_auto_accepted();
  }
  if (ok && quality_retires_forced) {
    self->retire_forced_settles_locked(*request);
  }
  return ok;
}

void FrameRenderer::completion_callback(uint64_t frame_id, void *user_data) {
  auto *self = static_cast<FrameRenderer *>(user_data);
  if (self == nullptr) {
    return;
  }
  self->notify_present_complete(frame_id);
}

SoftwareCompositor::SoftwareCompositor(PlutoPixelFormat format,
                                       FrameRenderer *renderer)
    : pool_(3, format), renderer_(renderer) {
  paint_bounds_scratch_.reserve(k_max_damage_rects);
}

FlutterCompositor SoftwareCompositor::flutter_compositor() {
  FlutterCompositor compositor{};
  compositor.struct_size = sizeof(compositor);
  compositor.user_data = this;
  compositor.create_backing_store_callback =
      &SoftwareCompositor::create_callback;
  compositor.collect_backing_store_callback =
      &SoftwareCompositor::collect_callback;
  compositor.present_layers_callback = nullptr;
  compositor.avoid_backing_store_cache = false;
  compositor.present_view_callback = &SoftwareCompositor::present_view_callback;
  return compositor;
}

bool SoftwareCompositor::create_backing_store(
    const FlutterBackingStoreConfig *config,
    FlutterBackingStore *backing_store_out) {
  return pool_.create(config, backing_store_out);
}

bool SoftwareCompositor::collect_backing_store(
    const FlutterBackingStore *backing_store) {
  return pool_.collect(backing_store);
}

bool SoftwareCompositor::present_view(const FlutterPresentViewInfo *info) {
  if (info == nullptr || info->struct_size < sizeof(FlutterPresentViewInfo) ||
      info->layers_count != 1 || info->layers == nullptr ||
      !layer_is_root_backing_store(info->layers[0])) {
    return false;
  }
  const FlutterLayer *layer = info->layers[0];
  const FlutterBackingStore *store = layer->backing_store;
  const FlutterSoftwareBackingStore2 &software = store->software2;
  ++present_count_;

  if (!store->did_update) {
    ++idle_short_circuit_count_;
    if (renderer_ != nullptr) {
      renderer_->notify_idle_frame();
    }
    return true;
  }

  paint_bounds_scratch_.clear();
  if (layer->backing_store_present_info != nullptr &&
      layer->backing_store_present_info->paint_region != nullptr) {
    FlutterRegion *region = layer->backing_store_present_info->paint_region;
    for (size_t i = 0; i < region->rects_count; ++i) {
      paint_bounds_scratch_.push_back(flutter_rect_to_pluto(region->rects[i]));
    }
  }

  PlutoFramePacket packet{};
  packet.pixels = software.allocation;
  packet.row_bytes = software.row_bytes;
  packet.width = static_cast<uint32_t>(layer->size.width);
  packet.height = static_cast<uint32_t>(software.height);
  packet.format = pool_.format();
  packet.did_update = store->did_update;
  packet.presentation_time_ns = layer->presentation_time;
  packet.paint_bounds = paint_bounds_scratch_.data();
  packet.paint_bounds_count = paint_bounds_scratch_.size();
  return renderer_ == nullptr || renderer_->submit_frame(packet);
}

bool SoftwareCompositor::create_callback(
    const FlutterBackingStoreConfig *config,
    FlutterBackingStore *backing_store_out, void *user_data) {
  auto *self = static_cast<SoftwareCompositor *>(user_data);
  return self != nullptr &&
         self->create_backing_store(config, backing_store_out);
}

bool SoftwareCompositor::collect_callback(
    const FlutterBackingStore *backing_store, void *user_data) {
  auto *self = static_cast<SoftwareCompositor *>(user_data);
  return self != nullptr && self->collect_backing_store(backing_store);
}

bool SoftwareCompositor::present_view_callback(
    const FlutterPresentViewInfo *info) {
  if (info == nullptr) {
    return false;
  }
  auto *self = static_cast<SoftwareCompositor *>(info->user_data);
  return self != nullptr && self->present_view(info);
}

} // namespace pluto
