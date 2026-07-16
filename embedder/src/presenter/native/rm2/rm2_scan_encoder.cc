#include "presenter/native/rm2/rm2_scan_encoder.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <time.h>
#include <utility>

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define PLUTO_RM2_NEON_PHASE_LOOKUP 1
#else
#define PLUTO_RM2_NEON_PHASE_LOOKUP 0
#endif

#if defined(__arm__) && PLUTO_RM2_NEON_PHASE_LOOKUP
#define PLUTO_RM2_ARMV7_PHASE_ASM 1
#else
#define PLUTO_RM2_ARMV7_PHASE_ASM 0
#endif

namespace pluto::native::rm2 {
namespace {

constexpr std::size_t kCellsPerLine = kRm2ScanoutStrideBytes / 4;
constexpr std::size_t kPreambleRows = 4;
constexpr std::size_t kFirstPixelCell = 26;
constexpr std::size_t kTransitions = 256;
constexpr std::size_t kPackedLanes = 8;
constexpr std::uint32_t kContentControl = 0x00510000U;
constexpr std::uint32_t kContentGateControl = 0x00530000U;

using PackedPhaseLut = std::array<std::uint16_t, kPackedLanes * kTransitions>;
using MaskedPhaseLut = std::array<std::uint8_t, kTransitions>;

bool rect_valid(const Rm2PanelRect &rect) {
  return rect.row_min <= rect.row_max && rect.column_min <= rect.column_max &&
         rect.row_max < kRm2PanelHeight && rect.column_max < kRm2PanelWidth &&
         (rect.row_min & 7U) == 0 && (rect.row_max & 7U) == 7U;
}

std::uint32_t read_u32(std::span<const std::byte> bytes, std::size_t offset) {
  std::uint32_t value = 0;
  std::memcpy(&value, bytes.data() + offset, sizeof(value));
  return value;
}

void write_u32(std::span<std::byte> bytes, std::size_t offset,
               std::uint32_t value) {
  std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

std::uint32_t preamble_cell(std::size_t cell) {
  std::uint32_t value = 0x00430000U;
  if (cell >= 20 && cell < 143) {
    value |= 0x00040000U;
  }
  if (cell >= 40 && cell < 103) {
    value &= ~0x00020000U;
  }
  return value;
}

std::uint32_t regular_cell(std::size_t cell, bool content,
                           std::uint16_t drive_pattern) {
  std::uint32_t value = 0x00410000U;
  if (cell >= 8 && cell < 19) {
    value |= 0x00200000U;
  }
  if (cell >= 55 && cell < 255) {
    value |= 0x00020000U;
  }
  if (content && cell >= 26) {
    value |= 0x00100000U | drive_pattern;
  }
  return value;
}

void fill_regular_line(std::span<std::byte> slot, std::size_t row, bool content,
                       std::uint16_t drive_pattern) {
  const std::size_t base = row * kRm2ScanoutStrideBytes;
  for (std::size_t cell = 0; cell < kCellsPerLine; ++cell) {
    write_u32(slot, base + cell * sizeof(std::uint32_t),
              regular_cell(cell, content, drive_pattern));
  }
}

MaskedPhaseLut build_masked_phase_lut(std::span<const std::uint8_t> phase_lut) {
  MaskedPhaseLut masked{};
  for (std::size_t transition = 0; transition < kTransitions; ++transition) {
    masked[transition] = phase_lut[transition] & 0x03U;
  }
  return masked;
}

PackedPhaseLut build_packed_phase_lut(const MaskedPhaseLut &phase_lut) {
  PackedPhaseLut packed{};
  for (std::size_t lane = 0; lane < kPackedLanes; ++lane) {
    const unsigned shift = static_cast<unsigned>((7U - lane) * 2U);
    for (std::size_t transition = 0; transition < kTransitions; ++transition) {
      packed[lane * kTransitions + transition] =
          static_cast<std::uint16_t>(phase_lut[transition]) << shift;
    }
  }
  return packed;
}

inline std::uint16_t pack_transition_group(const std::uint8_t *keys,
                                           const PackedPhaseLut &packed_lut) {
  return packed_lut[0U * kTransitions + keys[0]] |
         packed_lut[1U * kTransitions + keys[1]] |
         packed_lut[2U * kTransitions + keys[2]] |
         packed_lut[3U * kTransitions + keys[3]] |
         packed_lut[4U * kTransitions + keys[4]] |
         packed_lut[5U * kTransitions + keys[5]] |
         packed_lut[6U * kTransitions + keys[6]] |
         packed_lut[7U * kTransitions + keys[7]];
}

#if PLUTO_RM2_NEON_PHASE_LOOKUP
inline void
encode_transition_groups_neon(std::byte *destination, const std::uint8_t *keys,
                              std::uint32_t control,
                              std::span<const std::uint8_t> phase_lut) {
#if PLUTO_RM2_ARMV7_PHASE_ASM
  alignas(8) static constexpr std::array<std::uint8_t, 8> kPackWeights{
      64U, 16U, 4U, 1U, 64U, 16U, 4U, 1U};
  const std::uint8_t *key_cursor = keys;
  const std::uint8_t *lut_cursor = phase_lut.data();
  std::uint32_t blocks = 8U;
  asm volatile(
      "vld1.8 {d0-d3}, [%[keys]]!\n"
      "vld1.8 {d4-d7}, [%[keys]]\n"
      "veor q12, q12, q12\n"
      "veor q13, q13, q13\n"
      "veor q14, q14, q14\n"
      "veor q15, q15, q15\n"
      "vmov.i8 q10, #32\n"
      "1:\n"
      "vld1.8 {d16-d19}, [%[lut]]!\n"
      "vtbl.8 d8, {d16-d19}, d0\n"
      "vtbl.8 d9, {d16-d19}, d1\n"
      "vtbl.8 d10, {d16-d19}, d2\n"
      "vtbl.8 d11, {d16-d19}, d3\n"
      "vtbl.8 d12, {d16-d19}, d4\n"
      "vtbl.8 d13, {d16-d19}, d5\n"
      "vtbl.8 d14, {d16-d19}, d6\n"
      "vtbl.8 d15, {d16-d19}, d7\n"
      "vorr d24, d24, d8\n"
      "vorr d25, d25, d9\n"
      "vorr d26, d26, d10\n"
      "vorr d27, d27, d11\n"
      "vorr d28, d28, d12\n"
      "vorr d29, d29, d13\n"
      "vorr d30, d30, d14\n"
      "vorr d31, d31, d15\n"
      "subs %[blocks], %[blocks], #1\n"
      "beq 2f\n"
      "vsub.i8 q0, q0, q10\n"
      "vsub.i8 q1, q1, q10\n"
      "vsub.i8 q2, q2, q10\n"
      "vsub.i8 q3, q3, q10\n"
      "b 1b\n"
      "2:\n"
      "vld1.8 {d21}, [%[weights]]\n"
      "vmul.i8 d24, d24, d21\n"
      "vmul.i8 d25, d25, d21\n"
      "vmul.i8 d26, d26, d21\n"
      "vmul.i8 d27, d27, d21\n"
      "vmul.i8 d28, d28, d21\n"
      "vmul.i8 d29, d29, d21\n"
      "vmul.i8 d30, d30, d21\n"
      "vmul.i8 d31, d31, d21\n"
      "vpaddl.u8 d24, d24\n"
      "vpaddl.u8 d25, d25\n"
      "vpaddl.u8 d26, d26\n"
      "vpaddl.u8 d27, d27\n"
      "vpaddl.u8 d28, d28\n"
      "vpaddl.u8 d29, d29\n"
      "vpaddl.u8 d30, d30\n"
      "vpaddl.u8 d31, d31\n"
      "vpadd.i16 d0, d24, d25\n"
      "vpadd.i16 d1, d26, d27\n"
      "vpadd.i16 d2, d28, d29\n"
      "vpadd.i16 d3, d30, d31\n"
      "vmovn.i16 d4, q0\n"
      "vmovn.i16 d5, q1\n"
      "vrev16.8 d4, d4\n"
      "vrev16.8 d5, d5\n"
      "vmovl.u16 q3, d4\n"
      "vmovl.u16 q4, d5\n"
      "vdup.32 q5, %[control]\n"
      "vorr q3, q3, q5\n"
      "vorr q4, q4, q5\n"
      "vst1.8 {d6-d9}, [%[destination]]\n"
      : [keys] "+r"(key_cursor), [lut] "+r"(lut_cursor), [blocks] "+r"(blocks)
      : [destination] "r"(destination), [control] "r"(control),
        [weights] "r"(kPackWeights.data())
      : "cc", "memory", "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7", "d8",
        "d9", "d10", "d11", "d12", "d13", "d14", "d15", "d16", "d17", "d18",
        "d19", "d20", "d21", "d22", "d23", "d24", "d25", "d26", "d27", "d28",
        "d29", "d30", "d31");
#else
  // Eight independent groups amortize each 32-byte table load across 64
  // pixels while staying entirely within the ARMv7 NEON register file.
  std::array<uint8x8_t, 8> key_groups{};
  std::array<uint8x8_t, 8> mapped_groups{};
  for (std::size_t group = 0; group < key_groups.size(); ++group) {
    key_groups[group] = vld1_u8(keys + group * kPackedLanes);
    mapped_groups[group] = vdup_n_u8(0);
  }
  for (std::uint8_t block = 0; block < 8U; ++block) {
    const std::uint8_t *block_base = phase_lut.data() + block * 32U;
    const uint8x8x4_t table{{vld1_u8(block_base), vld1_u8(block_base + 8U),
                             vld1_u8(block_base + 16U),
                             vld1_u8(block_base + 24U)}};
    const uint8x8_t block_offset =
        vdup_n_u8(static_cast<std::uint8_t>(block * 32U));
    // vtbl returns zero for an index >= 32. Unsigned subtraction makes every
    // key outside this block out of range. Four independent lookups at a time
    // expose enough instruction-level parallelism to hide Cortex-A7 VTB L1
    // and execution latency; keeping the OR separate is faster than VTBX on
    // the exact RM2 CPU.
    const uint8x8_t indices0 = vsub_u8(key_groups[0], block_offset);
    const uint8x8_t indices1 = vsub_u8(key_groups[1], block_offset);
    const uint8x8_t indices2 = vsub_u8(key_groups[2], block_offset);
    const uint8x8_t indices3 = vsub_u8(key_groups[3], block_offset);
    const uint8x8_t lookup0 = vtbl4_u8(table, indices0);
    const uint8x8_t lookup1 = vtbl4_u8(table, indices1);
    const uint8x8_t lookup2 = vtbl4_u8(table, indices2);
    const uint8x8_t lookup3 = vtbl4_u8(table, indices3);
    mapped_groups[0] = vorr_u8(mapped_groups[0], lookup0);
    mapped_groups[1] = vorr_u8(mapped_groups[1], lookup1);
    mapped_groups[2] = vorr_u8(mapped_groups[2], lookup2);
    mapped_groups[3] = vorr_u8(mapped_groups[3], lookup3);
    const uint8x8_t indices4 = vsub_u8(key_groups[4], block_offset);
    const uint8x8_t indices5 = vsub_u8(key_groups[5], block_offset);
    const uint8x8_t indices6 = vsub_u8(key_groups[6], block_offset);
    const uint8x8_t indices7 = vsub_u8(key_groups[7], block_offset);
    const uint8x8_t lookup4 = vtbl4_u8(table, indices4);
    const uint8x8_t lookup5 = vtbl4_u8(table, indices5);
    const uint8x8_t lookup6 = vtbl4_u8(table, indices6);
    const uint8x8_t lookup7 = vtbl4_u8(table, indices7);
    mapped_groups[4] = vorr_u8(mapped_groups[4], lookup4);
    mapped_groups[5] = vorr_u8(mapped_groups[5], lookup5);
    mapped_groups[6] = vorr_u8(mapped_groups[6], lookup6);
    mapped_groups[7] = vorr_u8(mapped_groups[7], lookup7);
  }

  // A weighted pairwise reduction turns each eight-lane base-4 number into
  // two bytes. Combining four groups before narrowing keeps all eight packed
  // results in registers and avoids the ARMv7 compiler's scalar lane spills.
  const uint8x8_t weights = vcreate_u8(0x0104104001041040ULL);
  const uint16x4_t sums0 = vpaddl_u8(vmul_u8(mapped_groups[0], weights));
  const uint16x4_t sums1 = vpaddl_u8(vmul_u8(mapped_groups[1], weights));
  const uint16x4_t sums2 = vpaddl_u8(vmul_u8(mapped_groups[2], weights));
  const uint16x4_t sums3 = vpaddl_u8(vmul_u8(mapped_groups[3], weights));
  const uint16x4_t sums4 = vpaddl_u8(vmul_u8(mapped_groups[4], weights));
  const uint16x4_t sums5 = vpaddl_u8(vmul_u8(mapped_groups[5], weights));
  const uint16x4_t sums6 = vpaddl_u8(vmul_u8(mapped_groups[6], weights));
  const uint16x4_t sums7 = vpaddl_u8(vmul_u8(mapped_groups[7], weights));
  const uint8x8_t packed0 = vrev16_u8(vmovn_u16(
      vcombine_u16(vpadd_u16(sums0, sums1), vpadd_u16(sums2, sums3))));
  const uint8x8_t packed1 = vrev16_u8(vmovn_u16(
      vcombine_u16(vpadd_u16(sums4, sums5), vpadd_u16(sums6, sums7))));
  const uint32x4_t output0 =
      vorrq_u32(vmovl_u16(vreinterpret_u16_u8(packed0)), vdupq_n_u32(control));
  const uint32x4_t output1 =
      vorrq_u32(vmovl_u16(vreinterpret_u16_u8(packed1)), vdupq_n_u32(control));
  vst1q_u8(reinterpret_cast<std::uint8_t *>(destination),
           vreinterpretq_u8_u32(output0));
  vst1q_u8(reinterpret_cast<std::uint8_t *>(destination) + 16U,
           vreinterpretq_u8_u32(output1));
#endif
}
#else
inline void
encode_transition_groups_neon(std::byte *destination, const std::uint8_t *keys,
                              std::uint32_t control,
                              std::span<const std::uint8_t> phase_lut) {
  for (std::size_t group = 0; group < 8U; ++group) {
    std::uint16_t packed = 0;
    for (std::size_t lane = 0; lane < kPackedLanes; ++lane) {
      packed |= static_cast<std::uint16_t>(
                    phase_lut[keys[group * kPackedLanes + lane]] & 0x03U)
                << ((kPackedLanes - 1U - lane) * 2U);
    }
    const std::uint32_t value = control | packed;
    std::memcpy(destination + group * sizeof(value), &value, sizeof(value));
  }
}
#endif

inline void encode_full_panel_groups(std::byte *destination,
                                     const std::uint8_t *keys,
                                     std::size_t group_count,
                                     std::uint32_t control,
                                     const PackedPhaseLut &packed_lut,
                                     std::span<const std::uint8_t> phase_lut) {
#if PLUTO_RM2_NEON_PHASE_LOOKUP
  while (group_count >= 8U) {
    encode_transition_groups_neon(destination, keys, control, phase_lut);
    destination += 8U * sizeof(std::uint32_t);
    keys += 8U * kPackedLanes;
    group_count -= 8U;
  }
#else
  (void)phase_lut;
#endif
  for (std::size_t group = 0; group < group_count; ++group) {
    const std::uint32_t value =
        control | pack_transition_group(keys, packed_lut);
    std::memcpy(destination, &value, sizeof(value));
    destination += sizeof(value);
    keys += kPackedLanes;
  }
}

inline void replace_group_controls(std::byte *destination,
                                   std::size_t first_group,
                                   std::size_t group_count,
                                   std::uint32_t control) {
  for (std::size_t group = first_group; group < first_group + group_count;
       ++group) {
    std::uint32_t value = 0;
    std::memcpy(&value, destination + group * sizeof(value), sizeof(value));
    value = control | (value & 0x0000ffffU);
    std::memcpy(destination + group * sizeof(value), &value, sizeof(value));
  }
}

bool is_full_height(const Rm2PanelRect &rect) {
  return rect.row_min == 0 && rect.row_max == kRm2PanelHeight - 1U;
}

bool configure_phase_worker() noexcept {
#if defined(__linux__) && PLUTO_RM2_ARMV7_PHASE_ASM
  cpu_set_t affinity;
  CPU_ZERO(&affinity);
  CPU_SET(1, &affinity);
  sched_param parameters{};
  parameters.sched_priority = 60;
  const pthread_t worker = pthread_self();
  const int affinity_error =
      pthread_setaffinity_np(worker, sizeof(affinity), &affinity);
  const int policy_error =
      pthread_setschedparam(worker, SCHED_FIFO, &parameters);
  (void)pthread_setname_np(worker, "rm2-phase");
  return affinity_error == 0 && policy_error == 0;
#else
  return true;
#endif
}

inline void phase_spin_yield() noexcept {
#if defined(__arm__)
  asm volatile("yield" ::: "memory");
#else
  std::this_thread::yield();
#endif
}

bool configure_pan_worker() noexcept {
#if defined(__linux__) && defined(__arm__)
  cpu_set_t affinity;
  CPU_ZERO(&affinity);
  CPU_SET(0, &affinity);
  sched_param parameters{};
  parameters.sched_priority = 61;
  const pthread_t worker = pthread_self();
  const int affinity_error =
      pthread_setaffinity_np(worker, sizeof(affinity), &affinity);
  const int policy_error =
      pthread_setschedparam(worker, SCHED_FIFO, &parameters);
  (void)pthread_setname_np(worker, "rm2-pan");
  return affinity_error == 0 && policy_error == 0;
#elif defined(__linux__)
  (void)pthread_setname_np(pthread_self(), "rm2-pan");
  return true;
#else
  return true;
#endif
}

void encode_full_height_columns(std::span<std::byte> slot,
                                std::span<const std::uint8_t> transition_keys,
                                const PackedPhaseLut &packed_lut,
                                std::span<const std::uint8_t> phase_lut,
                                std::size_t destination_column_begin,
                                std::size_t local_column_begin,
                                std::size_t local_column_end) {
  constexpr std::size_t kLeadingGroups = 55U - kFirstPixelCell;
  constexpr std::size_t kGatedGroups = 255U - 55U;
  constexpr std::size_t kTrailingGroups =
      kRm2PanelHeight / kPackedLanes - kLeadingGroups - kGatedGroups;
  constexpr std::size_t kLeadingVectorGroups = 24U;
  constexpr std::size_t kGatedVectorGroups = 192U;
  constexpr std::size_t kBoundaryGroups = 8U;
  constexpr std::size_t kTrailingScalarGroups = 2U;
  static_assert(kLeadingGroups == 29U);
  static_assert(kGatedGroups == 200U);
  static_assert(kTrailingGroups == 5U);
  static_assert(kLeadingVectorGroups + kBoundaryGroups + kGatedVectorGroups +
                    kBoundaryGroups + kTrailingScalarGroups ==
                kRm2PanelHeight / kPackedLanes);

  const std::uint8_t *keys =
      transition_keys.data() + local_column_begin * kRm2PanelHeight;
  for (std::size_t local_column = local_column_begin;
       local_column < local_column_end; ++local_column) {
    const std::size_t column = destination_column_begin + local_column;
    std::byte *destination = slot.data() +
                             (kPreambleRows + column) * kRm2ScanoutStrideBytes +
                             kFirstPixelCell * sizeof(std::uint32_t);
    encode_full_panel_groups(destination, keys, kLeadingVectorGroups,
                             kContentControl, packed_lut, phase_lut);
    destination += kLeadingVectorGroups * sizeof(std::uint32_t);
    keys += kLeadingVectorGroups * kPackedLanes;

    encode_transition_groups_neon(destination, keys, kContentControl,
                                  phase_lut);
    replace_group_controls(destination, 5U, 3U, kContentGateControl);
    destination += kBoundaryGroups * sizeof(std::uint32_t);
    keys += kBoundaryGroups * kPackedLanes;

    encode_full_panel_groups(destination, keys, kGatedVectorGroups,
                             kContentGateControl, packed_lut, phase_lut);
    destination += kGatedVectorGroups * sizeof(std::uint32_t);
    keys += kGatedVectorGroups * kPackedLanes;

    encode_transition_groups_neon(destination, keys, kContentGateControl,
                                  phase_lut);
    replace_group_controls(destination, 5U, 3U, kContentControl);
    destination += kBoundaryGroups * sizeof(std::uint32_t);
    keys += kBoundaryGroups * kPackedLanes;

    encode_full_panel_groups(destination, keys, kTrailingScalarGroups,
                             kContentControl, packed_lut, phase_lut);
    keys += kTrailingScalarGroups * kPackedLanes;
  }
}

void encode_rect_columns(std::span<std::byte> slot, const Rm2PanelRect &rect,
                         std::span<const std::uint8_t> transition_keys,
                         const PackedPhaseLut &packed_lut,
                         std::span<const std::uint8_t> phase_lut,
                         std::size_t local_column_begin,
                         std::size_t local_column_end) {
  const std::size_t rows = rect.row_count();
  for (std::size_t local_column = local_column_begin;
       local_column < local_column_end; ++local_column) {
    const std::size_t column = rect.column_min + local_column;
    const std::uint8_t *keys = transition_keys.data() + local_column * rows;
    std::size_t cell = kFirstPixelCell + (rect.row_min >> 3U);
    std::byte *destination = slot.data() +
                             (kPreambleRows + column) * kRm2ScanoutStrideBytes +
                             cell * sizeof(std::uint32_t);
    std::size_t groups = rows / kPackedLanes;
    while (groups != 0) {
      const std::size_t next_control_boundary =
          cell < 55U ? 55U : (cell < 255U ? 255U : kCellsPerLine);
      const std::size_t segment =
          std::min(groups, next_control_boundary - cell);
      const std::uint32_t control =
          cell >= 55U && cell < 255U ? kContentGateControl : kContentControl;
      encode_full_panel_groups(destination, keys, segment, control, packed_lut,
                               phase_lut);
      destination += segment * sizeof(std::uint32_t);
      keys += segment * kPackedLanes;
      cell += segment;
      groups -= segment;
    }
  }
}

class PhaseWorker final {
public:
  PhaseWorker() {
    try {
      worker_ = std::thread([this] { worker_main(); });
    } catch (...) {
      return;
    }
    std::unique_lock<std::mutex> lock(start_mutex_);
    start_cv_.wait(lock, [this] { return started_; });
  }

  ~PhaseWorker() {
    {
      std::lock_guard<std::mutex> lock(work_mutex_);
      stopping_.store(true, std::memory_order_release);
    }
    work_cv_.notify_one();
    if (worker_.joinable()) {
      worker_.join();
    }
  }

  PhaseWorker(const PhaseWorker &) = delete;
  PhaseWorker &operator=(const PhaseWorker &) = delete;

  bool ready() const noexcept { return configured_; }

  std::chrono::nanoseconds cpu_time() noexcept {
#if defined(__linux__)
    if (!worker_.joinable()) {
      return {};
    }
    clockid_t clock_id{};
    timespec value{};
    if (::pthread_getcpuclockid(worker_.native_handle(), &clock_id) != 0 ||
        ::clock_gettime(clock_id, &value) != 0) {
      return {};
    }
    return std::chrono::seconds(value.tv_sec) +
           std::chrono::nanoseconds(value.tv_nsec);
#else
    return {};
#endif
  }

  bool encode(std::span<std::byte> slot, const Rm2PanelRect &rect,
              std::span<const std::uint8_t> transition_keys,
              const PackedPhaseLut &packed_lut,
              std::span<const std::uint8_t> phase_lut) {
    if (!configured_) {
      return false;
    }
    std::lock_guard<std::mutex> call_lock(call_mutex_);
    slot_ = slot;
    transition_keys_ = transition_keys;
    rect_ = rect;
    packed_lut_ = &packed_lut;
    phase_lut_ = phase_lut;
    complete_.store(false, std::memory_order_relaxed);
    {
      std::lock_guard<std::mutex> lock(work_mutex_);
      work_pending_.store(true, std::memory_order_release);
    }
    work_cv_.notify_one();

    const std::size_t column_split = rect.column_count() / 2U;
    if (is_full_height(rect)) {
      encode_full_height_columns(slot, transition_keys, packed_lut, phase_lut,
                                 rect.column_min, column_split,
                                 rect.column_count());
    } else {
      encode_rect_columns(slot, rect, transition_keys, packed_lut, phase_lut,
                          column_split, rect.column_count());
    }
    while (!complete_.load(std::memory_order_acquire)) {
      phase_spin_yield();
    }
    return true;
  }

private:
  void worker_main() {
    const bool configured = configure_phase_worker();
    {
      std::lock_guard<std::mutex> lock(start_mutex_);
      configured_ = configured;
      started_ = true;
    }
    start_cv_.notify_one();
    if (!configured) {
      return;
    }

    for (;;) {
      if (!work_pending_.exchange(false, std::memory_order_acquire)) {
        std::unique_lock<std::mutex> lock(work_mutex_);
        work_cv_.wait(lock, [this] {
          return stopping_.load(std::memory_order_acquire) ||
                 work_pending_.load(std::memory_order_acquire);
        });
        if (stopping_.load(std::memory_order_acquire)) {
          return;
        }
        continue;
      }

      const std::size_t column_split = rect_.column_count() / 2U;
      if (is_full_height(rect_)) {
        encode_full_height_columns(slot_, transition_keys_, *packed_lut_,
                                   phase_lut_, rect_.column_min, 0,
                                   column_split);
      } else {
        encode_rect_columns(slot_, rect_, transition_keys_, *packed_lut_,
                            phase_lut_, 0, column_split);
      }
      complete_.store(true, std::memory_order_release);
    }
  }

  std::thread worker_;
  std::mutex start_mutex_;
  std::condition_variable start_cv_;
  std::mutex work_mutex_;
  std::condition_variable work_cv_;
  std::mutex call_mutex_;
  std::atomic<bool> work_pending_{false};
  std::atomic<bool> complete_{true};
  std::atomic<bool> stopping_{false};
  std::span<std::byte> slot_;
  Rm2PanelRect rect_{};
  std::span<const std::uint8_t> transition_keys_;
  const PackedPhaseLut *packed_lut_ = nullptr;
  std::span<const std::uint8_t> phase_lut_;
  bool started_ = false;
  bool configured_ = false;
};

bool encode_regions_internal(PhaseWorker *worker, std::span<std::byte> slot,
                             std::span<const Rm2PhaseRegion> regions,
                             std::span<const std::uint8_t> transition_keys,
                             std::span<const std::uint8_t> phase_lut) {
  if (slot.size() != kRm2SlotBytes || regions.empty() ||
      phase_lut.size() != 16U * 16U) {
    return false;
  }
  for (const Rm2PhaseRegion &region : regions) {
    const std::size_t pixels =
        region.rect.row_count() * region.rect.column_count();
    if (!rect_valid(region.rect) ||
        region.transition_offset > transition_keys.size() ||
        pixels > transition_keys.size() - region.transition_offset) {
      return false;
    }
  }

  const MaskedPhaseLut masked_phase_lut = build_masked_phase_lut(phase_lut);
  const PackedPhaseLut packed_lut = build_packed_phase_lut(masked_phase_lut);
  constexpr std::size_t kParallelRegionPixels = 64U * 1024U;
  for (const Rm2PhaseRegion &region : regions) {
    const std::size_t pixels =
        region.rect.row_count() * region.rect.column_count();
    const std::span<const std::uint8_t> region_keys =
        transition_keys.subspan(region.transition_offset, pixels);
    if (worker != nullptr && region.rect.column_count() >= 2U &&
        pixels >= kParallelRegionPixels) {
      if (!worker->encode(slot, region.rect, region_keys, packed_lut,
                          masked_phase_lut)) {
        return false;
      }
      continue;
    }
    if (is_full_height(region.rect)) {
      encode_full_height_columns(slot, region_keys, packed_lut,
                                 masked_phase_lut, region.rect.column_min, 0,
                                 region.rect.column_count());
    } else {
      encode_rect_columns(slot, region.rect, region_keys, packed_lut,
                          masked_phase_lut, 0, region.rect.column_count());
    }
  }
  return true;
}

} // namespace

bool fill_rm2_scan_slot(std::span<std::byte> slot,
                        std::uint16_t drive_pattern) {
  if (slot.size() != kRm2SlotBytes) {
    return false;
  }

  for (std::size_t cell = 0; cell < kCellsPerLine; ++cell) {
    write_u32(slot, cell * sizeof(std::uint32_t), preamble_cell(cell));
  }
  fill_regular_line(slot, 1, false, 0);
  fill_regular_line(slot, 2, false, 0);
  for (std::size_t row = 3; row < kRm2ScanoutHeight; ++row) {
    fill_regular_line(slot, row, true, drive_pattern);
  }
  return true;
}

bool rm2_scan_slot_is_safe_hold(std::span<const std::byte> slot) {
  if (slot.size() != kRm2SlotBytes) {
    return false;
  }
  for (std::size_t row = 0; row < kRm2ScanoutHeight; ++row) {
    const bool preamble = row == 0;
    const bool content = row >= 3;
    const std::size_t base = row * kRm2ScanoutStrideBytes;
    for (std::size_t cell = 0; cell < kCellsPerLine; ++cell) {
      const std::uint32_t expected =
          preamble ? preamble_cell(cell) : regular_cell(cell, content, 0);
      if (read_u32(slot, base + cell * sizeof(std::uint32_t)) != expected) {
        return false;
      }
    }
  }
  return true;
}

class Rm2PhaseEncoder::Impl final {
public:
  PhaseWorker worker;
};

class Rm2PanWorker::Impl final {
public:
  explicit Impl(PanCallback callback) : callback_(std::move(callback)) {
    if (!callback_) {
      return;
    }
    try {
      worker_ = std::thread([this] { worker_main(); });
    } catch (...) {
      return;
    }
    std::unique_lock<std::mutex> lock(mutex_);
    start_cv_.wait(lock, [this] { return started_; });
  }

  ~Impl() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    work_cv_.notify_one();
    if (worker_.joinable()) {
      worker_.join();
    }
  }

  bool ready() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return configured_ && !stopping_;
  }

  bool begin(std::uint32_t slot) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!configured_ || stopping_ || pending_ || awaiting_finish_) {
      return false;
    }
    slot_ = slot;
    result_ = {};
    complete_ = false;
    operation_started_ = false;
    pending_ = true;
    awaiting_finish_ = true;
    work_cv_.notify_one();
    operation_started_cv_.wait(
        lock, [this] { return operation_started_ || !configured_; });
    return configured_;
  }

  bool finish(Rm2PanResult *out_result) {
    if (out_result == nullptr) {
      return false;
    }
    std::unique_lock<std::mutex> lock(mutex_);
    if (!configured_ || !awaiting_finish_) {
      return false;
    }
    complete_cv_.wait(lock, [this] { return complete_ || !configured_; });
    if (!configured_) {
      return false;
    }
    *out_result = result_;
    awaiting_finish_ = false;
    return true;
  }

  std::chrono::nanoseconds cpu_time() noexcept {
#if defined(__linux__)
    if (!worker_.joinable()) {
      return {};
    }
    clockid_t clock_id{};
    timespec value{};
    if (::pthread_getcpuclockid(worker_.native_handle(), &clock_id) != 0 ||
        ::clock_gettime(clock_id, &value) != 0) {
      return {};
    }
    return std::chrono::seconds(value.tv_sec) +
           std::chrono::nanoseconds(value.tv_nsec);
#else
    return {};
#endif
  }

private:
  void worker_main() {
    const bool configured = configure_pan_worker();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      configured_ = configured;
      started_ = true;
    }
    start_cv_.notify_one();
    if (!configured) {
      return;
    }

    for (;;) {
      std::uint32_t slot = 0;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        work_cv_.wait(lock, [this] { return stopping_ || pending_; });
        if (stopping_ && !pending_) {
          return;
        }
        slot = slot_;
        pending_ = false;
        operation_started_ = true;
      }
      operation_started_cv_.notify_one();

      Rm2PanResult result;
      try {
        result.operation_ok = callback_(slot, &result.duration);
      } catch (...) {
        result = {};
      }
      {
        std::lock_guard<std::mutex> lock(mutex_);
        result_ = result;
        complete_ = true;
      }
      complete_cv_.notify_one();
    }
  }

  PanCallback callback_;
  mutable std::mutex mutex_;
  std::condition_variable start_cv_;
  std::condition_variable work_cv_;
  std::condition_variable operation_started_cv_;
  std::condition_variable complete_cv_;
  std::thread worker_;
  Rm2PanResult result_{};
  std::uint32_t slot_ = 0;
  bool started_ = false;
  bool configured_ = false;
  bool stopping_ = false;
  bool pending_ = false;
  bool operation_started_ = false;
  bool complete_ = true;
  bool awaiting_finish_ = false;
};

Rm2PhaseEncoder::Rm2PhaseEncoder() : impl_(std::make_unique<Impl>()) {}

Rm2PhaseEncoder::~Rm2PhaseEncoder() = default;

bool Rm2PhaseEncoder::ready() const noexcept {
  return impl_ != nullptr && impl_->worker.ready();
}

bool Rm2PhaseEncoder::encode(std::span<std::byte> slot,
                             const Rm2PanelRect &rect,
                             std::span<const std::uint8_t> transition_keys,
                             std::span<const std::uint8_t> phase_lut) {
  const Rm2PhaseRegion region{.rect = rect, .transition_offset = 0};
  return encode_regions(slot, std::span<const Rm2PhaseRegion>(&region, 1),
                        transition_keys, phase_lut);
}

bool Rm2PhaseEncoder::encode_regions(
    std::span<std::byte> slot, std::span<const Rm2PhaseRegion> regions,
    std::span<const std::uint8_t> transition_keys,
    std::span<const std::uint8_t> phase_lut) {
  return impl_ != nullptr &&
         encode_regions_internal(&impl_->worker, slot, regions, transition_keys,
                                 phase_lut);
}

std::chrono::nanoseconds Rm2PhaseEncoder::worker_cpu_time() noexcept {
  return impl_ == nullptr ? std::chrono::nanoseconds{}
                          : impl_->worker.cpu_time();
}

Rm2PanWorker::Rm2PanWorker(PanCallback callback)
    : impl_(std::make_unique<Impl>(std::move(callback))) {}

Rm2PanWorker::~Rm2PanWorker() = default;

bool Rm2PanWorker::ready() const noexcept {
  return impl_ != nullptr && impl_->ready();
}

bool Rm2PanWorker::begin(std::uint32_t slot) {
  return impl_ != nullptr && impl_->begin(slot);
}

bool Rm2PanWorker::finish(Rm2PanResult *out_result) {
  return impl_ != nullptr && impl_->finish(out_result);
}

std::chrono::nanoseconds Rm2PanWorker::worker_cpu_time() noexcept {
  return impl_ == nullptr ? std::chrono::nanoseconds{} : impl_->cpu_time();
}

bool encode_rm2_phase(std::span<std::byte> slot, const Rm2PanelRect &rect,
                      std::span<const std::uint8_t> transition_keys,
                      std::span<const std::uint8_t> phase_lut) {
  const Rm2PhaseRegion region{.rect = rect, .transition_offset = 0};
  return encode_regions_internal(nullptr, slot,
                                 std::span<const Rm2PhaseRegion>(&region, 1),
                                 transition_keys, phase_lut);
}

bool clear_rm2_phase_cells(std::span<std::byte> slot,
                           const Rm2PanelRect &rect) {
  if (slot.size() != kRm2SlotBytes || !rect_valid(rect)) {
    return false;
  }
  for (std::uint32_t column = rect.column_min; column <= rect.column_max;
       ++column) {
    const std::size_t scan_line = kPreambleRows + column;
    for (std::uint32_t row = rect.row_min; row <= rect.row_max; row += 8U) {
      const std::size_t cell = kFirstPixelCell + (row >> 3U);
      const std::size_t offset =
          scan_line * kRm2ScanoutStrideBytes + cell * sizeof(std::uint32_t);
      const std::uint32_t existing = read_u32(slot, offset);
      write_u32(slot, offset, existing & 0xffff0000U);
    }
  }
  return true;
}

} // namespace pluto::native::rm2
