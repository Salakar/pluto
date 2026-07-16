#ifndef PLUTO_GLASS_HANDOFF_H_
#define PLUTO_GLASS_HANDOFF_H_

// Atomic warm-display handoff between embedder processes.
//
// The handoff file is an explicitly encoded, little-endian tmpfs bundle. It
// is intentionally not a C/C++ object dump: every geometry/configuration
// field and every section length is validated before any live renderer state
// is mutated. There is one exact current layout; non-matching files take the
// normal cold-clear path.
//
// Lifecycle (the presenter/renderer handshake is defined in presenter.h):
//   1. The outgoing renderer stages its quiescent renderer payload.
//   2. The presenter resolves the final content scan count, snapshots its
//      engine/history state, and writes this bundle via temp + fsync + rename.
//   3. The incoming presenter validates the entire bundle and seeds core
//      state, but does not skip cold clear yet.
//   4. The incoming renderer validates and seeds the renderer section, then
//      confirms the same candidate. Only that confirmation admits warm state.
//   5. Before the first accepted content admission is published, the bundle
//      is unlinked. A crash after glass divergence therefore cannot leak a
//      stale seed to another process.
//
// One process owns the bundle namespace for that complete lifecycle through a
// persistent `path + ".lease"` inode. The lease spans load, first-admission
// claim/discard, and the eventual close/save; it is never unlinked by this
// module, so competing processes cannot split the lock across different
// inodes.

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace pluto {

inline constexpr std::uint32_t kGlassHandoffMagic = 0x48474c50u; // "PLGH"
inline constexpr std::uint32_t kGlassHandoffMaxChain = 8;
inline constexpr std::int64_t kGlassHandoffMaxAgeSec = 60;
inline constexpr std::uint64_t kGlassHandoffMaxBytes = 128ull << 20;
// Accommodates the largest supported native RGB565 logical mirror plus its
// backend envelope while bounding preallocation from an untrusted bundle.
inline constexpr std::uint64_t kGlassHandoffMaxPresenterPayloadBytes =
    8ull * 1024ull * 1024ull;
inline constexpr char kGlassHandoffDefaultPath[] = "/run/pluto/glass.handoff";

enum GlassHandoffFlags : std::uint32_t {
  kGlassHandoffFlagNone = 0,
  kGlassHandoffFlagExactColor = 1u << 0,
};

// Device/pipeline routing is explicit. A future panel gets a new profile and
// must opt into it after its geometry and pipeline identities are defined;
// it can never accidentally consume the Move/Xochitl layout merely because
// one dimension happens to match.
enum class GlassHandoffProfile : std::uint32_t {
  kMonochrome = 1,
  kXochitlGallery3Move = 0x5847334du, // "XG3M"
};

enum class GlassHandoffSection : std::uint32_t {
  // Monochrome only: settled engine plane, full engine stride x height.
  kEngineLevels = 1,
  // Exact-color and monochrome engine debt state.
  kEngineDc = 2,
  kEngineStress = 3,
  kEngineRescan = 4,
  // Exact-color only: little-endian {u16 A,u16 B} for the full history
  // storage plane (the Move profile is 968x1698).
  kXochitlHistory = 5,
  // Opaque to the presenter; encoded and validated by FrameRenderer.
  kRenderer = 6,
  // Opaque to the common bundle; encoded and validated by the native
  // presenter backend that owns the logical glass mirror.
  kPresenter = 7,
};

struct GlassHandoffClock {
  std::int64_t realtime_sec = 0;
  std::uint64_t boottime_ns = 0;
  std::uint64_t boot_id_hash = 0;
};

// Presenter-owned exact identity. Hashes cover bytes, never paths.
// `pipeline_hash` includes the canonical PixelEngine/DcLedger configuration.
struct GlassHandoffIdentity {
  std::uint32_t flags = kGlassHandoffFlagNone;
  GlassHandoffProfile profile = GlassHandoffProfile::kMonochrome;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t pixel_format = 0;
  std::uint32_t engine_stride = 0;
  std::uint32_t tile_px = 0;
  std::uint32_t history_stride = 0;
  std::uint32_t history_rows = 0;
  std::uint32_t history_pixel_bytes = 0;
  std::uint64_t waveform_hash = 0;
  std::uint64_t waveform_bytes = 0;
  std::uint64_t ct33_hash = 0;
  std::uint64_t ct33_bytes = 0;
  std::uint64_t pipeline_hash = 0;

  friend bool operator==(const GlassHandoffIdentity &,
                         const GlassHandoffIdentity &) = default;
};

struct GlassHandoffRendererInfo {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t rotation = 0;
  std::uint32_t pixel_format = 0;
  std::uint64_t configuration_hash = 0;

  friend bool operator==(const GlassHandoffRendererInfo &,
                         const GlassHandoffRendererInfo &) = default;
};

// Canonical quiescent presenter state. Multi-byte vectors are host values in
// memory and are encoded little-endian on disk. Exact color derives
// prev/next/final from Xochitl A low5 after proving equality at save time, so
// it does not duplicate an engine level plane in the bundle.
struct GlassHandoffCoreState {
  std::int32_t engine_temperature_bin = 0;
  std::int32_t admission_temperature_bin = 0;
  std::vector<std::uint8_t> engine_levels;
  std::vector<std::int8_t> engine_dc;
  std::vector<std::uint16_t> engine_stress;
  std::vector<std::int32_t> engine_rescan;
  // Interleaved host values: [A0,B0,A1,B1,...].
  std::vector<std::uint16_t> xochitl_history_ab;
};

// Non-wire identity of the exact inode validated by glass_handoff_load().
// It is intentionally opaque to callers: the only valid operation is an
// atomic first-admission claim through glass_handoff_claim().
struct GlassHandoffClaim {
  bool valid = false;
  std::uint64_t device = 0;
  std::uint64_t inode = 0;
  std::uint64_t file_bytes = 0;
  std::uint64_t header_checksum = 0;
  std::int64_t modified_sec = 0;
  std::int64_t modified_nsec = 0;
};

struct GlassHandoffBundle {
  GlassHandoffIdentity identity;
  GlassHandoffRendererInfo renderer;
  GlassHandoffClock written;
  std::uint32_t chain = 0;
  GlassHandoffCoreState core;
  std::vector<std::uint8_t> renderer_payload;
  // Optional for presenters such as Move whose exact state already lives in
  // the core/renderer sections. Native backends use this bounded section for
  // their own exact logical mirror encoding.
  std::vector<std::uint8_t> presenter_payload;
  // Filled only by glass_handoff_load(); never serialized by save.
  GlassHandoffClaim claim;
};

enum class GlassHandoffReject : std::uint8_t;

// Exclusive process-lifetime ownership of one handoff bundle namespace.
// Acquisition uses a nonblocking advisory lock on a persistent private lease
// inode. The object is intentionally move-only: copying a locked descriptor or
// using an inherited post-fork descriptor would make ownership ambiguous.
class GlassHandoffLease final {
public:
  GlassHandoffLease() = default;
  ~GlassHandoffLease();

  GlassHandoffLease(const GlassHandoffLease &) = delete;
  GlassHandoffLease &operator=(const GlassHandoffLease &) = delete;
  GlassHandoffLease(GlassHandoffLease &&other) noexcept;
  GlassHandoffLease &operator=(GlassHandoffLease &&other) noexcept;

  bool valid() const;

private:
  bool valid_for_path(const std::string &path) const;
  void reset() noexcept;

  int fd_ = -1;
  std::int64_t owner_pid_ = 0;
  std::string path_;

  friend bool glass_handoff_acquire_lease(const std::string &,
                                          GlassHandoffLease *);
  friend GlassHandoffReject glass_handoff_load(const GlassHandoffLease &,
                                               const std::string &,
                                               const GlassHandoffIdentity &,
                                               const GlassHandoffClock &,
                                               GlassHandoffBundle *);
  friend bool glass_handoff_save(const GlassHandoffLease &, const std::string &,
                                 const GlassHandoffBundle &);
  friend bool glass_handoff_claim(const GlassHandoffLease &,
                                  const std::string &,
                                  const GlassHandoffClaim &);
  friend bool glass_handoff_discard(const GlassHandoffLease &,
                                    const std::string &);
};

enum class GlassHandoffReject : std::uint8_t {
  kNone = 0,
  kMissing,
  kIo,
  kPartial,
  kMagic,
  kLayout,
  kTooLarge,
  kChecksum,
  kAge,
  kChain,
  kGeometry,
  kPixelFormat,
  kProfile,
  kWaveform,
  kCt33,
  kPipeline,
  kState,
};

const char *glass_handoff_reject_name(GlassHandoffReject reject);

// CRC-64/ECMA-182. Used both for corruption detection and for canonical
// byte-identity fingerprints. The seed permits deterministic composition of
// named blobs/config fields without allocating a concatenation buffer.
std::uint64_t glass_handoff_crc64(std::span<const std::uint8_t> bytes,
                                  std::uint64_t seed = 0);

// Current CLOCK_REALTIME/CLOCK_BOOTTIME + Linux boot-id fingerprint. Fields
// unavailable on a host are zero; load then uses the remaining age proof.
GlassHandoffClock glass_handoff_now();

// Acquire exclusive, nonblocking ownership of `path`'s namespace. The
// persistent `path + ".lease"` file is a root/current-user-owned, single-link,
// mode-0600 regular inode. It is deliberately never unlinked by this module;
// closing the move-only lease releases the lock, including on process death.
bool glass_handoff_acquire_lease(const std::string &path,
                                 GlassHandoffLease *out);

// Load validates the complete file, exact EOF, directory, per-section and
// whole-payload checksums, age/boot, chain, and presenter identity. Renderer
// geometry/configuration is deliberately validated later by the renderer in
// the same admission transaction.
GlassHandoffReject glass_handoff_load(const GlassHandoffLease &lease,
                                      const std::string &path,
                                      const GlassHandoffIdentity &expected,
                                      const GlassHandoffClock &now,
                                      GlassHandoffBundle *out);

// Stream-encodes and atomically replaces `path` using a same-directory unique
// O_EXCL temporary inode, mode 0600, full EINTR-safe writes, fsync, rename,
// and directory sync. A failed save removes its own temporary file and never
// publishes a partial final bundle. Before writing, private writer-temporary
// and abandoned claim names older than the maximum handoff age are
// conservatively reclaimed.
bool glass_handoff_save(const GlassHandoffLease &lease, const std::string &path,
                        const GlassHandoffBundle &bundle);

// Atomically removes `path` from the shared namespace by renaming it to a
// unique private claim name, then proves that it is the exact candidate inode
// returned by load before unlinking it. Exactly one competing consumer can
// succeed. Missing, replaced, partially rewritten, or corrupt candidates are
// removed and fail closed. Success includes a parent-directory durability
// fence and is required before the first warm content admission.
bool glass_handoff_claim(const GlassHandoffLease &lease,
                         const std::string &path,
                         const GlassHandoffClaim &claim);

// Conservative invalidation used before first admission and on unsafe close.
// Removes the final path, synchronizes its parent directory when the name
// existed, and returns true only when it is confirmed absent. Unique writer
// temporaries and claims remain private and are never removed by a competing
// process while recent; abandoned private files older than the maximum
// handoff age are reclaimed. An already-absent path is success even if its
// parent directory does not exist.
bool glass_handoff_discard(const GlassHandoffLease &lease,
                           const std::string &path);

} // namespace pluto

#endif // PLUTO_GLASS_HANDOFF_H_
