#include "pluto/presenter.h"
#include "presenter/swtcon/drm_swtcon_device.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_phase_generator.h"
#include "presenter/swtcon/swtcon_rails.h"
#include "presenter/swtcon/swtcon_waveform.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <exception>
#include <limits>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace pluto::swtcon::probe {
namespace {

enum class Stage {
  kInfo,
  kBlank,
  kRails,
  kFlash,
};

enum class Pattern {
  kClear,
  kChecker,
  kHalves,
  kGrayRamp,
  kGrayBars,
};

struct Options {
  Stage stage = Stage::kInfo;
  bool show_help = false;
  std::uint32_t hold_ms = 3000;
  std::uint32_t duration_ms = 2000;
  std::uint32_t frames = 0;
  float temperature_c = 25.0f;
  Pattern pattern = Pattern::kClear;
  std::string card_path = "/dev/dri/card0";
  std::string waveform_dir = "/usr/share/remarkable";
  SwtconWaveform::Files waveform_files;
  SwtconRails::Config rails;
  // Diagnostic: if >=0, bypass the packer/waveform and fill every phase frame
  // with this constant 16-bit word (drives all pixels identically) to test
  // whether the panel scans/develops AT ALL. Sweep values to find first light.
  long raw_fill = -1;
  bool raw_all_words = true;  // fill entire buffer (vs only data words 47..286)
  // Validation: if >=0, drive a CONSTANT 3-bit phase code (0..7) through
  // the real packer path (correct scaffold + 3-bit layout), all pixels/slots =
  // this code. Sweep 0..7 to find which code drives solid black vs white.
  int fixed_phase = -1;
  // 2-level direct-update: pack white target pixels with du_white code and black
  // target pixels with du_black code (found empirically: 1..3=white, 4..7=black).
  int du_white = -1;
  int du_black = -1;
  bool du_dither = false;  // ordered Bayer dithering (perceived greyscale)
};

volatile std::sig_atomic_t g_interrupted_signal = 0;

void handle_signal(int signal) {
  if (g_interrupted_signal == 0) {
    g_interrupted_signal = signal;
  }
}

bool interrupted() { return g_interrupted_signal != 0; }

const char *signal_name() {
  switch (g_interrupted_signal) {
  case SIGINT:
    return "SIGINT";
  case SIGTERM:
    return "SIGTERM";
  default:
    return "signal";
  }
}

void install_signal_handlers() {
  struct sigaction action {};
  action.sa_handler = handle_signal;
  sigemptyset(&action.sa_mask);
  action.sa_flags = 0;
  (void)sigaction(SIGINT, &action, nullptr);
  (void)sigaction(SIGTERM, &action, nullptr);
}

void log_line(const char *tag, const std::string &message) {
  std::fprintf(stdout, "%s %s\n", tag, message.c_str());
  std::fflush(stdout);
}

void log_step(const std::string &message) { log_line("[step]", message); }

void log_ok(const std::string &message) { log_line("[ ok ]", message); }

void log_warn(const std::string &message) { log_line("[warn]", message); }

void log_fail(const std::string &message) { log_line("[fail]", message); }

std::string join_path(const std::string &base, const std::string &leaf) {
  if (base.empty() || base.back() == '/') {
    return base + leaf;
  }
  return base + "/" + leaf;
}

bool starts_with(const std::string &value, const char *prefix) {
  const std::size_t prefix_len = std::strlen(prefix);
  return value.size() >= prefix_len &&
         value.compare(0, prefix_len, prefix) == 0;
}

bool ends_with(const std::string &value, const char *suffix) {
  const std::size_t suffix_len = std::strlen(suffix);
  return value.size() >= suffix_len &&
         value.compare(value.size() - suffix_len, suffix_len, suffix) == 0;
}

std::string id_list(const std::vector<std::uint32_t> &ids) {
  std::string out = "[";
  for (std::size_t i = 0; i < ids.size(); ++i) {
    if (i != 0) {
      out += ", ";
    }
    out += std::to_string(ids[i]);
  }
  out += "]";
  return out;
}

std::string mode_name(const DrmModeInfo &mode) {
  const std::size_t len = strnlen(mode.name, sizeof(mode.name));
  return std::string(mode.name, mode.name + len);
}

std::string status_name(PlutoStatus status) {
  switch (status) {
  case kPlutoStatusOk:
    return "ok";
  case kPlutoStatusAgain:
    return "again";
  case kPlutoStatusUnsupported:
    return "unsupported";
  case kPlutoStatusInvalidArgument:
    return "invalid argument";
  case kPlutoStatusDeviceLost:
    return "device lost";
  case kPlutoStatusTimeout:
    return "timeout";
  case kPlutoStatusInternal:
    return "internal";
  }
  return "unknown";
}

bool parse_u32(const std::string &value, std::uint32_t *out) {
  if (out == nullptr || value.empty()) {
    return false;
  }
  char *end = nullptr;
  errno = 0;
  const unsigned long parsed = std::strtoul(value.c_str(), &end, 10);
  if (errno != 0 || end == value.c_str() || *end != '\0' ||
      parsed > std::numeric_limits<std::uint32_t>::max()) {
    return false;
  }
  *out = static_cast<std::uint32_t>(parsed);
  return true;
}

bool parse_float(const std::string &value, float *out) {
  if (out == nullptr || value.empty()) {
    return false;
  }
  char *end = nullptr;
  errno = 0;
  const float parsed = std::strtof(value.c_str(), &end);
  if (errno != 0 || end == value.c_str() || *end != '\0') {
    return false;
  }
  *out = parsed;
  return true;
}

bool parse_stage(const std::string &value, Stage *out) {
  if (out == nullptr) {
    return false;
  }
  if (value == "info") {
    *out = Stage::kInfo;
    return true;
  }
  if (value == "blank") {
    *out = Stage::kBlank;
    return true;
  }
  if (value == "rails") {
    *out = Stage::kRails;
    return true;
  }
  if (value == "flash") {
    *out = Stage::kFlash;
    return true;
  }
  return false;
}

bool parse_pattern(const std::string &value, Pattern *out) {
  if (out == nullptr) {
    return false;
  }
  if (value == "clear") {
    *out = Pattern::kClear;
    return true;
  }
  if (value == "checker") {
    *out = Pattern::kChecker;
    return true;
  }
  if (value == "halves") {
    *out = Pattern::kHalves;
    return true;
  }
  if (value == "gray-ramp" || value == "grayramp") {
    *out = Pattern::kGrayRamp;
    return true;
  }
  if (value == "gray-bars" || value == "graybars") {
    *out = Pattern::kGrayBars;
    return true;
  }
  return false;
}

const char *stage_name(Stage stage) {
  switch (stage) {
  case Stage::kInfo:
    return "info";
  case Stage::kBlank:
    return "blank";
  case Stage::kRails:
    return "rails";
  case Stage::kFlash:
    return "flash";
  }
  return "unknown";
}

const char *pattern_name(Pattern pattern) {
  switch (pattern) {
  case Pattern::kClear:
    return "clear";
  case Pattern::kChecker:
    return "checker";
  case Pattern::kHalves:
    return "halves";
  case Pattern::kGrayRamp:
    return "gray-ramp";
  case Pattern::kGrayBars:
    return "gray-bars";
  }
  return "unknown";
}

void print_usage(const char *argv0) {
  std::printf(
      "usage: %s --stage=info|blank|rails|flash [options]\n"
      "\n"
      "Safety stages:\n"
      "  --stage=info   KMS discovery + 16 RG16 dumb buffers, no flip/rails.\n"
      "  --stage=blank  info + one blank-template CRTC latch, no rails.\n"
      "  --stage=rails  info + xochitl rail values, no waveform drive.\n"
      "  --stage=flash  full-screen black->white full refresh, then cleanup.\n"
      "\n"
      "Options:\n"
      "  --hold=<ms>                  settle duration after flash, default "
      "3000\n"
      "  --duration-ms=<ms>           flash stream duration, default 2000\n"
      "  --frames=<count>             stream this many 85 Hz frames instead\n"
      "  --fixed-phase=<0..7>         drive a constant 3-bit code via the packer\n"
      "  --du-white=<0..7> --du-black=<0..7>  2-level image: white/black pixel codes\n"
      "  --pattern=<clear|checker|halves> default clear\n"
      "  --temperature=<celsius>      waveform lookup temperature, default 25\n"
      "  --card=<path>                DRM card, default /dev/dri/card0\n"
      "  --waveform-dir=<path>        default /usr/share/remarkable\n"
      "  --eink=<path>                GAL3 waveform; auto-detects GAL3_*.eink\n"
      "  --ct33-std=<path>            default ct33_std.bin in waveform dir\n"
      "  --ct33-best=<path>           default ct33_best.bin in waveform dir\n"
      "  --ct33-pen=<path>            default ct33_pen.bin in waveform dir\n"
      "  --ct33-fast=<path>           default ct33_fast.bin in waveform dir\n"
      "  --panel-base=<path>          default "
      "/sys/devices/platform/cumulus-panel\n"
      "  --regulator-base=<path>      default "
      "/sys/bus/i2c/drivers/g2194-regulator/0-0048\n",
      argv0);
}

bool parse_args(int argc, char **argv, Options *options, std::string *error) {
  if (options == nullptr) {
    return false;
  }
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") {
      options->show_help = true;
      return true;
    }
    if (!starts_with(arg, "--")) {
      *error = "unexpected positional argument: " + arg;
      return false;
    }
    const std::size_t eq = arg.find('=');
    if (eq == std::string::npos) {
      *error = "expected --key=value option: " + arg;
      return false;
    }
    const std::string key = arg.substr(2, eq - 2);
    const std::string value = arg.substr(eq + 1);

    if (key == "stage") {
      if (!parse_stage(value, &options->stage)) {
        *error = "invalid stage: " + value;
        return false;
      }
    } else if (key == "hold") {
      if (!parse_u32(value, &options->hold_ms)) {
        *error = "invalid hold milliseconds: " + value;
        return false;
      }
    } else if (key == "duration-ms" || key == "duration_ms") {
      if (!parse_u32(value, &options->duration_ms)) {
        *error = "invalid duration milliseconds: " + value;
        return false;
      }
    } else if (key == "frames") {
      if (!parse_u32(value, &options->frames) || options->frames == 0) {
        *error = "invalid frame count: " + value;
        return false;
      }
    } else if (key == "pattern") {
      if (!parse_pattern(value, &options->pattern)) {
        *error = "invalid pattern: " + value;
        return false;
      }
    } else if (key == "temperature" || key == "temperature-c") {
      if (!parse_float(value, &options->temperature_c)) {
        *error = "invalid temperature: " + value;
        return false;
      }
    } else if (key == "card") {
      options->card_path = value;
    } else if (key == "waveform-dir" || key == "waveform_dir") {
      options->waveform_dir = value;
    } else if (key == "eink" || key == "waveform") {
      options->waveform_files.eink_path = value;
    } else if (key == "ct33-std" || key == "ct33_std") {
      options->waveform_files.ct33_std_path = value;
    } else if (key == "ct33-best" || key == "ct33_best") {
      options->waveform_files.ct33_best_path = value;
    } else if (key == "ct33-pen" || key == "ct33_pen") {
      options->waveform_files.ct33_pen_path = value;
    } else if (key == "ct33-fast" || key == "ct33_fast") {
      options->waveform_files.ct33_fast_path = value;
    } else if (key == "panel-base" || key == "panel_base") {
      options->rails.panel_base = value;
    } else if (key == "regulator-base" || key == "regulator_base") {
      options->rails.regulator_base = value;
    } else if (key == "vcom") {
      options->rails.vcom_value = value;
    } else if (key == "vpdd") {
      options->rails.vpdd_value = value;
    } else if (key == "raw-fill" || key == "raw_fill") {
      options->raw_fill = std::strtol(value.c_str(), nullptr, 0) & 0xffffL;
    } else if (key == "raw-data-only") {
      options->raw_all_words = false;
    } else if (key == "fixed-phase" || key == "fixed_phase") {
      long fp = std::strtol(value.c_str(), nullptr, 0);
      if (fp < 0 || fp > 7) {
        *error = "fixed-phase must be 0..7: " + value;
        return false;
      }
      options->fixed_phase = static_cast<int>(fp);
    } else if (key == "du-white" || key == "du_white") {
      long c = std::strtol(value.c_str(), nullptr, 0);
      if (c < 0 || c > 7) { *error = "du-white must be 0..7: " + value; return false; }
      options->du_white = static_cast<int>(c);
    } else if (key == "du-black" || key == "du_black") {
      long c = std::strtol(value.c_str(), nullptr, 0);
      if (c < 0 || c > 7) { *error = "du-black must be 0..7: " + value; return false; }
      options->du_black = static_cast<int>(c);
    } else if (key == "du-dither" || key == "du_dither") {
      options->du_dither = (value == "1" || value == "true");
    } else {
      *error = "unknown option: --" + key;
      return false;
    }
  }
  return true;
}

bool find_default_eink(const std::string &directory, std::string *out) {
  if (out == nullptr) {
    return false;
  }
  DIR *dir = opendir(directory.c_str());
  if (dir == nullptr) {
    return false;
  }

  std::vector<std::string> matches;
  for (;;) {
    errno = 0;
    dirent *entry = readdir(dir);
    if (entry == nullptr) {
      break;
    }
    const std::string name = entry->d_name;
    if (starts_with(name, "GAL3_") && ends_with(name, ".eink")) {
      matches.push_back(join_path(directory, name));
    }
  }
  const int saved_errno = errno;
  closedir(dir);
  errno = saved_errno;
  if (saved_errno != 0 || matches.empty()) {
    return false;
  }
  std::sort(matches.begin(), matches.end());
  *out = matches.front();
  return true;
}

bool resolve_waveform_defaults(Options *options, std::string *error) {
  if (options == nullptr) {
    return false;
  }
  if (options->waveform_files.ct33_std_path.empty()) {
    options->waveform_files.ct33_std_path =
        join_path(options->waveform_dir, "ct33_std.bin");
  }
  if (options->waveform_files.ct33_best_path.empty()) {
    options->waveform_files.ct33_best_path =
        join_path(options->waveform_dir, "ct33_best.bin");
  }
  if (options->waveform_files.ct33_pen_path.empty()) {
    options->waveform_files.ct33_pen_path =
        join_path(options->waveform_dir, "ct33_pen.bin");
  }
  if (options->waveform_files.ct33_fast_path.empty()) {
    options->waveform_files.ct33_fast_path =
        join_path(options->waveform_dir, "ct33_fast.bin");
  }
  if (options->waveform_files.eink_path.empty() &&
      !find_default_eink(options->waveform_dir,
                         &options->waveform_files.eink_path)) {
    *error = "unable to find GAL3_*.eink in " + options->waveform_dir +
             "; pass --eink=/path/to/GAL3_*.eink";
    return false;
  }
  return true;
}

void print_properties(const std::vector<DrmPropertyValue> &properties) {
  for (const DrmPropertyValue &property : properties) {
    std::printf("       prop id=%u name=%s value=%llu\n", property.id,
                property.name.c_str(),
                static_cast<unsigned long long>(property.value));
  }
}

class LoggingDrmInterface final : public DrmInterface {
public:
  explicit LoggingDrmInterface(std::unique_ptr<DrmInterface> inner)
      : inner_(std::move(inner)) {}

  int open_card(const std::string &path, std::string *error) override {
    log_step("open " + path);
    const int fd = inner_->open_card(path, error);
    if (fd < 0) {
      log_fail(error != nullptr ? *error : "open failed");
    } else {
      log_ok("opened DRM fd " + std::to_string(fd));
    }
    return fd;
  }

  void close_fd(int fd) override {
    log_step("close DRM fd " + std::to_string(fd));
    inner_->close_fd(fd);
    log_ok("DRM fd closed");
  }

  bool set_client_cap(int fd, std::uint64_t capability, std::uint64_t value,
                      std::string *error) override {
    log_step("drmSetClientCap cap=" + std::to_string(capability) +
             " value=" + std::to_string(value));
    const bool ok = inner_->set_client_cap(fd, capability, value, error);
    log_result(ok, error);
    return ok;
  }

  bool get_cap(int fd, std::uint64_t capability, std::uint64_t *value,
               std::string *error) override {
    log_step("drmGetCap cap=" + std::to_string(capability));
    const bool ok = inner_->get_cap(fd, capability, value, error);
    if (ok) {
      log_ok("cap value " + std::to_string(value != nullptr ? *value : 0));
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool get_resources(int fd, DrmResources *out, std::string *error) override {
    log_step("drmModeGetResources");
    const bool ok = inner_->get_resources(fd, out, error);
    if (ok && out != nullptr) {
      log_ok("resources crtcs=" + id_list(out->crtcs) +
             " connectors=" + id_list(out->connectors));
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool get_connector(int fd, std::uint32_t connector_id, DrmConnectorInfo *out,
                     std::string *error) override {
    log_step("drmModeGetConnector id=" + std::to_string(connector_id));
    const bool ok = inner_->get_connector(fd, connector_id, out, error);
    if (ok && out != nullptr) {
      log_ok("connector id=" + std::to_string(out->connector_id) +
             " connected=" + (out->connected ? "yes" : "no") +
             " encoder=" + std::to_string(out->encoder_id) +
             " encoders=" + id_list(out->encoders));
      for (std::size_t i = 0; i < out->modes.size(); ++i) {
        const DrmModeInfo &mode = out->modes[i];
        std::printf(
            "       mode[%zu] %ux%u clock=%u refresh=%u flags=0x%x type=0x%x "
            "name=%s\n",
            i, mode.hdisplay, mode.vdisplay, mode.clock, mode.vrefresh,
            mode.flags, mode.type, mode_name(mode).c_str());
      }
      print_properties(out->properties);
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool get_encoder(int fd, std::uint32_t encoder_id, DrmEncoderInfo *out,
                   std::string *error) override {
    log_step("drmModeGetEncoder id=" + std::to_string(encoder_id));
    const bool ok = inner_->get_encoder(fd, encoder_id, out, error);
    if (ok && out != nullptr) {
      log_ok("encoder id=" + std::to_string(out->encoder_id) +
             " crtc=" + std::to_string(out->crtc_id) + " possible_crtcs=0x" +
             hex32(out->possible_crtcs));
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool get_plane_ids(int fd, std::vector<std::uint32_t> *out,
                     std::string *error) override {
    log_step("drmModeGetPlaneResources");
    const bool ok = inner_->get_plane_ids(fd, out, error);
    if (ok && out != nullptr) {
      log_ok("planes=" + id_list(*out));
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool get_plane(int fd, std::uint32_t plane_id, DrmPlaneInfo *out,
                 std::string *error) override {
    log_step("drmModeGetPlane id=" + std::to_string(plane_id));
    const bool ok = inner_->get_plane(fd, plane_id, out, error);
    if (ok && out != nullptr) {
      log_ok("plane id=" + std::to_string(out->plane_id) +
             " possible_crtcs=0x" + hex32(out->possible_crtcs));
      print_properties(out->properties);
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool create_dumb(int fd, std::uint32_t width, std::uint32_t height,
                   std::uint32_t bpp, DrmDumbCreateResult *out,
                   std::string *error) override {
    log_step("DRM_IOCTL_MODE_CREATE_DUMB " + std::to_string(width) + "x" +
             std::to_string(height) + " bpp=" + std::to_string(bpp));
    const bool ok = inner_->create_dumb(fd, width, height, bpp, out, error);
    if (ok && out != nullptr) {
      log_ok("dumb handle=" + std::to_string(out->handle) + " pitch=" +
             std::to_string(out->pitch) + " size=" + std::to_string(out->size));
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool add_fb(int fd, std::uint32_t width, std::uint32_t height,
              std::uint8_t depth, std::uint8_t bpp, std::uint32_t pitch,
              std::uint32_t handle, std::uint32_t *fb_id,
              std::string *error) override {
    log_step("drmModeAddFB handle=" + std::to_string(handle) + " " +
             std::to_string(width) + "x" + std::to_string(height) +
             " depth=" + std::to_string(depth) + " bpp=" + std::to_string(bpp) +
             " pitch=" + std::to_string(pitch));
    const bool ok = inner_->add_fb(fd, width, height, depth, bpp, pitch, handle,
                                   fb_id, error);
    if (ok) {
      log_ok("fb_id=" + std::to_string(fb_id != nullptr ? *fb_id : 0));
    } else {
      log_result(false, error);
    }
    return ok;
  }

  bool map_dumb(int fd, std::uint32_t handle, std::uint64_t *offset,
                std::string *error) override {
    log_step("DRM_IOCTL_MODE_MAP_DUMB handle=" + std::to_string(handle));
    const bool ok = inner_->map_dumb(fd, handle, offset, error);
    if (ok) {
      log_ok("mmap offset=" + std::to_string(offset != nullptr ? *offset : 0));
    } else {
      log_result(false, error);
    }
    return ok;
  }

  void *mmap_dumb(int fd, std::uint64_t offset, std::uint64_t size,
                  std::string *error) override {
    log_step("mmap dumb offset=" + std::to_string(offset) +
             " size=" + std::to_string(size));
    void *mapped = inner_->mmap_dumb(fd, offset, size, error);
    if (mapped != nullptr) {
      char buffer[64];
      std::snprintf(buffer, sizeof(buffer), "%p", mapped);
      log_ok(std::string("mapped at ") + buffer);
    } else {
      log_result(false, error);
    }
    return mapped;
  }

  void munmap_dumb(void *address, std::uint64_t size) override {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%p", address);
    log_step(std::string("munmap ") + buffer + " size=" + std::to_string(size));
    inner_->munmap_dumb(address, size);
    log_ok("unmapped dumb buffer");
  }

  bool rm_fb(int fd, std::uint32_t fb_id, std::string *error) override {
    log_step("drmModeRmFB fb_id=" + std::to_string(fb_id));
    const bool ok = inner_->rm_fb(fd, fb_id, error);
    log_result(ok, error);
    return ok;
  }

  bool destroy_dumb(int fd, std::uint32_t handle, std::string *error) override {
    log_step("DRM_IOCTL_MODE_DESTROY_DUMB handle=" + std::to_string(handle));
    const bool ok = inner_->destroy_dumb(fd, handle, error);
    log_result(ok, error);
    return ok;
  }

  bool set_crtc(int fd, std::uint32_t crtc_id, std::uint32_t fb_id,
                std::uint32_t connector_id, const DrmModeInfo &mode,
                std::string *error) override {
    log_step("drmModeSetCrtc crtc=" + std::to_string(crtc_id) +
             " fb_id=" + std::to_string(fb_id) +
             " connector=" + std::to_string(connector_id) +
             " mode=" + std::to_string(mode.hdisplay) + "x" +
             std::to_string(mode.vdisplay));
    const bool ok =
        inner_->set_crtc(fd, crtc_id, fb_id, connector_id, mode, error);
    log_result(ok, error);
    return ok;
  }

  bool blank_crtc(int fd, std::uint32_t crtc_id, std::string *error) override {
    log_step("drmModeSetCrtc blank crtc=" + std::to_string(crtc_id));
    const bool ok = inner_->blank_crtc(fd, crtc_id, error);
    log_result(ok, error);
    return ok;
  }

  bool set_connector_property(int fd, std::uint32_t connector_id,
                              std::uint32_t property_id, std::uint64_t value,
                              std::string *error) override {
    log_step("drmModeConnectorSetProperty connector=" +
             std::to_string(connector_id) + " prop=" +
             std::to_string(property_id) + " value=" + std::to_string(value));
    const bool ok = inner_->set_connector_property(fd, connector_id,
                                                   property_id, value, error);
    log_result(ok, error);
    return ok;
  }

  bool atomic_commit(int fd, const DrmAtomicRequest &request,
                     std::string *error) override {
    const bool log_this = atomic_commit_count_ == 0;
    if (log_this) {
      log_step("DRM_IOCTL_MODE_ATOMIC flags=" + std::to_string(request.flags) +
               " objects=" + id_list(request.objects) +
               " prop_count=" + std::to_string(request.properties.size()));
    }
    const bool ok = inner_->atomic_commit(fd, request, error);
    if (!ok && !log_this) {
      log_step("DRM_IOCTL_MODE_ATOMIC flags=" + std::to_string(request.flags) +
               " objects=" + id_list(request.objects) +
               " prop_count=" + std::to_string(request.properties.size()));
    }
    if (log_this || !ok) {
      log_result(ok, error);
    }
    ++atomic_commit_count_;
    return ok;
  }

private:
  static std::string hex32(std::uint32_t value) {
    char buffer[16];
    std::snprintf(buffer, sizeof(buffer), "%08x", value);
    return buffer;
  }

  static void log_result(bool ok, const std::string *error) {
    if (ok) {
      log_ok("ok");
    } else {
      log_fail(error != nullptr && !error->empty() ? *error : "failed");
    }
  }

  std::unique_ptr<DrmInterface> inner_;
  std::uint64_t atomic_commit_count_ = 0;
};

void print_selected_device(const DrmSwtconDevice &device) {
  const DrmModeInfo &mode = device.mode();
  log_ok("selected connector=" + std::to_string(device.connector_id()) +
         " crtc=" + std::to_string(device.crtc_id()) +
         " primary_plane=" + std::to_string(device.plane_id()) +
         " dpms_prop=" + std::to_string(device.dpms_property_id()) +
         " plane_fb_id_prop=" + std::to_string(device.fb_id_property_id()));
  const DrmPlaneAtomicPropertyIds &props = device.plane_property_ids();
  log_ok("atomic plane props FB_ID=" + std::to_string(props.fb_id) +
         " CRTC_ID=" + std::to_string(props.crtc_id) +
         " CRTC_X/Y/W/H=" + std::to_string(props.crtc_x) + "/" +
         std::to_string(props.crtc_y) + "/" + std::to_string(props.crtc_w) +
         "/" + std::to_string(props.crtc_h) + " SRC_X/Y/W/H=" +
         std::to_string(props.src_x) + "/" + std::to_string(props.src_y) + "/" +
         std::to_string(props.src_w) + "/" + std::to_string(props.src_h));
  log_ok("validated mode " + std::to_string(mode.hdisplay) + "x" +
         std::to_string(mode.vdisplay) + " name=" + mode_name(mode));
  const std::vector<DrmMappedBuffer> &buffers = device.buffers();
  log_ok("mapped RG16 dumb buffers=" + std::to_string(buffers.size()) +
         " expected=" + std::to_string(kDrmBufferCount) +
         " payload_bytes=" + std::to_string(kDrmPhaseBytes));
  for (std::size_t i = 0; i < buffers.size(); ++i) {
    const DrmMappedBuffer &buffer = buffers[i];
    char ptr[64];
    std::snprintf(ptr, sizeof(ptr), "%p", buffer.map);
    std::printf(
        "       buffer[%zu] handle=%u fb_id=%u pitch=%u size=%llu map=%s\n", i,
        buffer.handle, buffer.fb_id, buffer.pitch,
        static_cast<unsigned long long>(buffer.size), ptr);
  }
  std::fflush(stdout);
}

class ProbeContext final {
public:
  explicit ProbeContext(const Options &options)
      : options_(options),
        device_(std::make_unique<DrmSwtconDevice>(
            std::make_unique<LoggingDrmInterface>(make_real_drm_interface()))) {
  }

  ProbeContext(const ProbeContext &) = delete;
  ProbeContext &operator=(const ProbeContext &) = delete;

  ~ProbeContext() { cleanup(); }

  bool open_drm() {
    log_step("opening SWTCON DRM device for full KMS discovery");
    DrmSwtconDevice::Config config;
    config.card_path = options_.card_path;
    const PlutoStatus status = device_->open(config);
    if (status != kPlutoStatusOk) {
      log_fail("DRM open failed: " + status_name(status) + ": " +
               device_->last_error());
      return false;
    }
    print_selected_device(*device_);
    return true;
  }

  bool copy_to_buffer(std::size_t buffer_index, const std::uint16_t *words) {
    log_step("copy RG16 phase frame to buffer " + std::to_string(buffer_index));
    const PlutoStatus status =
        device_->copy_phase_to_buffer(buffer_index, words);
    if (status != kPlutoStatusOk) {
      log_fail("copy failed: " + status_name(status) + ": " +
               device_->last_error());
      return false;
    }
    log_ok("buffer copy complete");
    return true;
  }

  bool latch_buffer(std::size_t buffer_index) {
    log_step("latch buffer " + std::to_string(buffer_index) +
             " with drmModeSetCrtc");
    const PlutoStatus status = device_->set_crtc(buffer_index);
    if (status != kPlutoStatusOk) {
      log_fail("latch failed: " + status_name(status) + ": " +
               device_->last_error());
      return false;
    }
    latched_ = true;
    log_ok("buffer latched");
    return true;
  }

  bool set_dpms_on() {
    log_step("force connector DPMS On");
    const PlutoStatus status = device_->set_dpms_on();
    if (status != kPlutoStatusOk) {
      log_fail("DPMS On failed: " + status_name(status) + ": " +
               device_->last_error());
      return false;
    }
    log_ok("DPMS On");
    return true;
  }

  bool atomic_flip(std::size_t buffer_index) {
    const PlutoStatus status = device_->atomic_flip(buffer_index);
    if (status != kPlutoStatusOk) {
      log_fail("atomic flip failed: " + status_name(status) + ": " +
               device_->last_error());
      return false;
    }
    latched_ = true;
    return true;
  }

  bool blank_latched_crtc() {
    if (!device_->is_open()) {
      return true;
    }
    log_step("blank/release CRTC");
    const PlutoStatus status = device_->blank();
    if (status != kPlutoStatusOk) {
      log_fail("blank failed: " + status_name(status) + ": " +
               device_->last_error());
      return false;
    }
    latched_ = false;
    log_ok("CRTC blanked");
    return true;
  }

  bool rails_on() {
    log_step("apply xochitl SWTCON rail values");
    SwtconRails::Config config = options_.rails;
    config.enable = true;
    RealRailsFs fs;
    std::string error;
    const PlutoStatus status = SwtconRails::apply(config, &fs, &error);
    if (status != kPlutoStatusOk) {
      log_fail("rails on failed: " + status_name(status) + ": " + error);
      return false;
    }
    rails_enabled_ = true;
    log_ok("rails on: vpos 6/12/24, vneg -24/-12/-6, vpdd_length 30000");
    return true;
  }

  bool rails_off() {
    if (!rails_enabled_) {
      return true;
    }
    log_step("turn panel rails off via regulator enable_nowait=0");
    RealRailsFs fs;
    std::string error;
    const std::string path =
        join_path(options_.rails.regulator_base, "enable_nowait");
    if (!fs.write_file(path, "0", &error)) {
      log_fail("rails off failed: " + error);
      return false;
    }
    rails_enabled_ = false;
    log_ok("rails off");
    return true;
  }

  void cleanup() {
    if (cleaned_) {
      return;
    }
    cleaned_ = true;
    if (interrupted()) {
      log_warn(std::string("cleanup after ") + signal_name());
    }
    if (latched_ && device_->is_open()) {
      (void)blank_latched_crtc();
    }
    if (device_->is_open()) {
      log_step("release DRM buffers and fd");
      device_->close();
      log_ok("DRM released");
    }
    if (rails_enabled_) {
      (void)rails_off();
    }
  }

private:
  const Options &options_;
  std::unique_ptr<DrmSwtconDevice> device_;
  bool latched_ = false;
  bool rails_enabled_ = false;
  bool cleaned_ = false;
};

bool wait_until(std::chrono::steady_clock::time_point deadline) {
  while (std::chrono::steady_clock::now() < deadline) {
    if (interrupted()) {
      return false;
    }
    const auto remaining = deadline - std::chrono::steady_clock::now();
    const auto chunk = std::min<std::chrono::steady_clock::duration>(
        remaining, std::chrono::milliseconds(50));
    if (chunk > std::chrono::steady_clock::duration::zero()) {
      std::this_thread::sleep_for(chunk);
    }
  }
  return !interrupted();
}

bool hold_for_ms(std::uint32_t hold_ms, const char *label) {
  log_step(std::string("hold ") + std::to_string(hold_ms) + " ms: " + label);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(hold_ms);
  const bool ok = wait_until(deadline);
  if (ok) {
    log_ok("hold complete");
  } else {
    log_warn(std::string("interrupted during hold: ") + label);
  }
  return ok;
}

constexpr std::uint64_t kAtomicPhasePeriodNs =
    (1000000000ULL + 85ULL / 2ULL) / 85ULL;

bool monotonic_now(timespec *out, std::string *error) {
  if (out == nullptr) {
    return false;
  }
  if (clock_gettime(CLOCK_MONOTONIC, out) != 0) {
    if (error != nullptr) {
      *error = std::string("clock_gettime: ") + std::strerror(errno);
    }
    return false;
  }
  return true;
}

void add_ns(timespec *value, std::uint64_t ns) {
  if (value == nullptr) {
    return;
  }
  value->tv_sec += static_cast<time_t>(ns / 1000000000ULL);
  value->tv_nsec += static_cast<long>(ns % 1000000000ULL);
  if (value->tv_nsec >= 1000000000L) {
    ++value->tv_sec;
    value->tv_nsec -= 1000000000L;
  }
}

bool timespec_less(const timespec &a, const timespec &b) {
  if (a.tv_sec != b.tv_sec) {
    return a.tv_sec < b.tv_sec;
  }
  return a.tv_nsec < b.tv_nsec;
}

double elapsed_seconds(const timespec &start, const timespec &end) {
  const double seconds = static_cast<double>(end.tv_sec - start.tv_sec);
  const double nanoseconds =
      static_cast<double>(end.tv_nsec - start.tv_nsec) / 1000000000.0;
  return seconds + nanoseconds;
}

bool sleep_until_monotonic(const timespec &deadline, std::string *error) {
  for (;;) {
    if (interrupted()) {
      return false;
    }
    const int rc =
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, nullptr);
    if (rc == 0) {
      return !interrupted();
    }
    if (rc == EINTR) {
      continue;
    }
    if (error != nullptr) {
      *error = std::string("clock_nanosleep: ") + std::strerror(rc);
    }
    return false;
  }
}

bool load_waveforms(const Options &options, SwtconWaveform *waveform) {
  if (waveform == nullptr) {
    return false;
  }
  log_step("load xochitl waveform files");
  log_ok("GAL3 eink: " + options.waveform_files.eink_path);
  log_ok("ct33 std: " + options.waveform_files.ct33_std_path);
  log_ok("ct33 best: " + options.waveform_files.ct33_best_path);
  log_ok("ct33 pen: " + options.waveform_files.ct33_pen_path);
  log_ok("ct33 fast: " + options.waveform_files.ct33_fast_path);

  RealWaveformFileReader reader;
  std::string error;
  if (!waveform->load(options.waveform_files, reader, &error)) {
    log_fail("waveform load failed: " + error);
    return false;
  }
  log_ok("loaded eink bytes=" + std::to_string(waveform->eink_bytes().size()) +
         " ct33 files=" + std::to_string(waveform->ct33_bytes().size()));
  return true;
}

void write_rgb565(std::vector<std::uint8_t> *frame, int x, int y,
                  std::uint16_t value) {
  const std::size_t offset = static_cast<std::size_t>(y) * kLogicalStrideBytes +
                             static_cast<std::size_t>(x) * kRgb565BytesPerPixel;
  (*frame)[offset] = static_cast<std::uint8_t>(value & 0xff);
  (*frame)[offset + 1] = static_cast<std::uint8_t>(value >> 8);
}

std::uint16_t gray_to_rgb565(int g) {
  const int r5 = (g >> 3) & 0x1f, g6 = (g >> 2) & 0x3f, b5 = (g >> 3) & 0x1f;
  return static_cast<std::uint16_t>((r5 << 11) | (g6 << 5) | b5);
}

std::vector<std::uint8_t> make_pattern_frame(Pattern pattern) {
  std::vector<std::uint8_t> frame(kLogicalFrameBytes, 0);
  for (int y = 0; y < kLogicalHeight; ++y) {
    for (int x = 0; x < kLogicalWidth; ++x) {
      if (pattern == Pattern::kGrayRamp) {
        const int g = (x * 255) / (kLogicalWidth - 1);  // 0..255 left->right
        write_rgb565(&frame, x, y, gray_to_rgb565(g));
        continue;
      }
      if (pattern == Pattern::kGrayBars) {
        const int band = (x * 16) / kLogicalWidth;  // 16 grey bands
        write_rgb565(&frame, x, y, gray_to_rgb565(band * 17));
        continue;
      }
      bool white = true;
      switch (pattern) {
      case Pattern::kClear:
        white = true;
        break;
      case Pattern::kChecker:
        white = ((x / 64) + (y / 64)) % 2 == 0;
        break;
      case Pattern::kHalves:
        white = x >= kLogicalWidth / 2;
        break;
      default:
        break;
      }
      write_rgb565(&frame, x, y, white ? 0xffffU : 0x0000U);
    }
  }
  return frame;
}

// Fills either the fixed 15-slot diagnostic ring (raw/du/fixed paths,
// *waveform_phase_count = 0) or, for the decoded-waveform path, packs the
// waveform's variable N phase frames into *waveform_packed and sets
// *waveform_phase_count = N (played once, not looped).
bool generate_fullscreen_pattern(
    const Options &options, const SwtconWaveform &waveform,
    std::array<std::vector<std::uint16_t>, kActivePhaseSlots> *phase_slots,
    std::vector<std::uint16_t> *waveform_packed, int *waveform_phase_count) {
  if (phase_slots == nullptr || waveform_packed == nullptr ||
      waveform_phase_count == nullptr) {
    return false;
  }
  *waveform_phase_count = 0;
  const char *target_name = options.pattern == Pattern::kClear
                                ? "white"
                                : pattern_name(options.pattern);
  log_step(std::string("pack full-screen black->") + target_name +
           " target through waveform phases");
  std::vector<std::uint8_t> target = make_pattern_frame(options.pattern);
  for (std::vector<std::uint16_t> &slot : *phase_slots) {
    slot.assign(kDrmPhaseWords, 0);
  }

  // Diagnostic raw-fill: bypass packer/waveform, fill frames with a constant.
  if (options.raw_fill >= 0) {
    const std::uint16_t v = static_cast<std::uint16_t>(options.raw_fill);
    for (std::vector<std::uint16_t> &slot : *phase_slots) {
      if (options.raw_all_words) {
        std::fill(slot.begin(), slot.end(), v);
      } else {
        // only the visible data words 47..286 of rows 3..1698, keep control template
        init_blank_phase_frame(slot.data());
        for (int y = 0; y < 1696; ++y) {
          std::uint16_t *row = slot.data() + static_cast<std::size_t>(y + 3) * kDrmWidth;
          for (int w = 47; w <= 286; ++w) row[w] = v;
        }
      }
    }
    log_ok("RAW-FILL diagnostic: all phase frames = 0x" +
           [](std::uint16_t x){ char b[8]; std::snprintf(b, sizeof(b), "%04x", x); return std::string(b); }(v) +
           (options.raw_all_words ? " (all words)" : " (data words only)"));
    return true;
  }
  // 2-level direct-update: render the target pattern as a real image by packing
  // white pixels with du_white code and black pixels with du_black code (all
  // slots), on top of the control scaffold. Mirrors the packer's 3-bit layout
  // (leftmost pixel bits[11:9], shift=9-3*(x%4)); preserves control bits.
  if (options.du_white >= 0 && options.du_black >= 0) {
    for (std::vector<std::uint16_t> &slot : *phase_slots) {
      slot.assign(kDrmPhaseWords, 0);
      init_blank_phase_frame(slot.data());
    }
    for (int y = 0; y < kLogicalHeight; ++y) {
      const std::uint8_t *trow =
          target.data() + static_cast<std::size_t>(y) * kLogicalStrideBytes;
      for (int x = 0; x < kLogicalWidth; ++x) {
        const std::uint16_t px = static_cast<std::uint16_t>(
            trow[x * 2] | (static_cast<std::uint16_t>(trow[x * 2 + 1]) << 8));
        bool white;
        if (options.du_dither) {
          static const int kB8[64] = {
              0,  32, 8,  40, 2,  34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
              12, 44, 4,  36, 14, 46, 6,  38, 60, 28, 52, 20, 62, 30, 54, 22,
              3,  35, 11, 43, 1,  33, 9,  41, 51, 19, 59, 27, 49, 17, 57, 25,
              15, 47, 7,  39, 13, 45, 5,  37, 63, 31, 55, 23, 61, 29, 53, 21};
          const int r = ((px >> 11) & 0x1f) << 3, g = ((px >> 5) & 0x3f) << 2,
                    b = (px & 0x1f) << 3;
          const int luma = (r * 30 + g * 59 + b * 11) / 100;
          white = luma > (kB8[(y & 7) * 8 + (x & 7)] * 4 + 2);
        } else {
          white = (px == 0xffffU);
        }
        const int code = white ? options.du_white : options.du_black;
        const std::size_t widx =
            static_cast<std::size_t>(y + kFirstDataRow) * kDrmWidth +
            kFirstDataWord + static_cast<std::size_t>(x / 4);
        const int shift = 9 - 3 * (x % 4);
        const std::uint16_t mask = static_cast<std::uint16_t>(0x7U << shift);
        for (std::vector<std::uint16_t> &slot : *phase_slots) {
          std::uint16_t *f = slot.data();
          f[widx] = static_cast<std::uint16_t>(
              (f[widx] & ~mask) |
              (static_cast<std::uint16_t>(code & 0x7) << shift));
        }
      }
    }
    log_ok("DU 2-level: white->code " + std::to_string(options.du_white) +
           ", black->code " + std::to_string(options.du_black));
    return true;
  }

  // Validation: drive a CONSTANT 3-bit code through the real packer
  // (correct 3-bit layout + control scaffold), all pixels/slots = fixed_phase.
  if (options.fixed_phase >= 0) {
    SourceFrame frame{};
    frame.previous_pixels = target.data();
    frame.next_pixels = target.data();
    frame.previous_stride_bytes = kLogicalStrideBytes;
    frame.next_stride_bytes = kLogicalStrideBytes;
    frame.width = kLogicalWidth;
    frame.height = kLogicalHeight;
    frame.format = kPlutoPixelFormatRgb565;

    PhaseLookup lookup{};
    lookup.waveform = &waveform;
    lookup.mode = SwtconUpdateMode::kFull;
    lookup.temperature_c = options.temperature_c;
    lookup.use_fixed_phase_value = true;
    lookup.fixed_phase_value = static_cast<std::uint8_t>(options.fixed_phase);

    std::vector<std::uint16_t> packed;
    SwtconPacker packer;
    std::string perr;
    if (!packer.pack(frame, lookup, &packed, &perr)) {
      log_fail("fixed-phase pack failed: " + perr);
      return false;
    }
    for (int i = 0; i < kActivePhaseSlots; ++i) {
      std::copy_n(packed.data() + static_cast<std::size_t>(i) * kDrmPhaseWords,
                  kDrmPhaseWords,
                  (*phase_slots)[static_cast<std::size_t>(i)].data());
    }
    log_ok("FIXED-PHASE diagnostic: all pixels/slots driven with 3-bit code " +
           std::to_string(options.fixed_phase) + " (packer path)");
    return true;
  }

  SwtconPhaseGenerator generator(&waveform);
  generator.reset_previous(0x0000U);

  PlutoSurface surface{};
  surface.pixels = target.data();
  surface.stride_bytes = kLogicalStrideBytes;
  surface.width = kLogicalWidth;
  surface.height = kLogicalHeight;
  surface.format = kPlutoPixelFormatRgb565;

  PlutoRect damage{};
  damage.x = 0;
  damage.y = 0;
  damage.width = kLogicalWidth;
  damage.height = kLogicalHeight;

  std::string error;
  if (!generator.generate(surface, &damage, 1, kPlutoRefreshFull,
                          options.temperature_c, waveform_packed,
                          waveform_phase_count, &error)) {
    log_fail("phase generation failed: " + error);
    return false;
  }
  log_ok("packed " + std::to_string(*waveform_phase_count) +
         " decoded phase frames, words/frame=" +
         std::to_string(kDrmPhaseWords));
  return true;
}

// Streaming for the decoded waveform: play the N phase frames exactly
// once through the dumb-buffer ring (copy just-in-time, ring can be shorter
// than N), then settle on the hold-only blank scaffold. No frame%N looping.
bool stream_waveform_once(ProbeContext *context,
                          const std::vector<std::uint16_t> &packed,
                          int phase_count) {
  if (context == nullptr || phase_count <= 0) {
    return false;
  }
  log_step("stream " + std::to_string(phase_count) +
           " decoded phases once at 85 Hz, then hold");

  std::string error;
  timespec start{};
  if (!monotonic_now(&start, &error)) {
    log_fail(error);
    return false;
  }
  timespec deadline = start;
  std::vector<std::uint16_t> blank(kDrmPhaseWords, 0);
  init_blank_phase_frame(blank.data());
  for (int frame = 0; frame <= phase_count; ++frame) {
    if (interrupted()) {
      return false;
    }
    const auto buffer_index =
        static_cast<std::size_t>(frame % kDrmBufferCount);
    const std::uint16_t *words =
        frame < phase_count
            ? packed.data() + static_cast<std::size_t>(frame) * kDrmPhaseWords
            : blank.data();
    if (!context->copy_to_buffer(buffer_index, words)) {
      return false;
    }
    if (!context->atomic_flip(buffer_index)) {
      return false;
    }
    add_ns(&deadline, kAtomicPhasePeriodNs);
    if (!sleep_until_monotonic(deadline, &error)) {
      if (!interrupted() && !error.empty()) {
        log_fail(error);
      }
      return false;
    }
  }
  log_ok("waveform pass complete: " + std::to_string(phase_count) +
         " phases + hold frame");
  return true;
}

bool copy_phase_slots(
    ProbeContext *context,
    const std::array<std::vector<std::uint16_t>, kActivePhaseSlots> &slots) {
  if (context == nullptr) {
    return false;
  }
  for (int i = 0; i < kActivePhaseSlots; ++i) {
    if (interrupted()) {
      return false;
    }
    if (!context->copy_to_buffer(static_cast<std::size_t>(i),
                                 slots[static_cast<std::size_t>(i)].data())) {
      return false;
    }
  }
  return true;
}

bool stream_continuous(ProbeContext *context, const Options &options) {
  if (context == nullptr) {
    return false;
  }
  log_step("stream phase buffers with DRM atomic commits at 85 Hz");

  std::string error;
  timespec start{};
  if (!monotonic_now(&start, &error)) {
    log_fail(error);
    return false;
  }

  timespec end = start;
  add_ns(&end, static_cast<std::uint64_t>(options.duration_ms) * 1000000ULL);
  timespec deadline = start;
  std::uint64_t frame = 0;
  for (;;) {
    if (interrupted()) {
      return false;
    }

    if (options.frames != 0) {
      if (frame >= options.frames) {
        break;
      }
    } else {
      timespec now{};
      if (!monotonic_now(&now, &error)) {
        log_fail(error);
        return false;
      }
      if (!timespec_less(now, end)) {
        break;
      }
    }

    const std::size_t buffer_index =
        static_cast<std::size_t>(frame % kActivePhaseSlots);
    if (!context->atomic_flip(buffer_index)) {
      return false;
    }
    ++frame;
    add_ns(&deadline, kAtomicPhasePeriodNs);
    if (!sleep_until_monotonic(deadline, &error)) {
      if (!interrupted() && !error.empty()) {
        log_fail(error);
      }
      return false;
    }
  }

  timespec finish{};
  if (!monotonic_now(&finish, &error)) {
    log_fail(error);
    return false;
  }
  const double elapsed = elapsed_seconds(start, finish);
  const double fps = elapsed > 0.0 ? static_cast<double>(frame) / elapsed : 0.0;
  char summary[160];
  std::snprintf(summary, sizeof(summary),
                "atomic stream complete: frames=%llu elapsed_ms=%.1f "
                "fps=%.2f period_ms=%.5f",
                static_cast<unsigned long long>(frame), elapsed * 1000.0, fps,
                static_cast<double>(kAtomicPhasePeriodNs) / 1000000.0);
  log_ok(summary);
  return true;
}

int interrupted_exit_code() { return interrupted() ? 130 : 0; }

int run_info(const Options &options) {
  ProbeContext context(options);
  if (!context.open_drm()) {
    return 1;
  }
  log_ok("info stage complete: no rails, no flip, no panel drive");
  return interrupted_exit_code();
}

int run_blank(const Options &options) {
  ProbeContext context(options);
  if (!context.open_drm()) {
    return 1;
  }
  if (interrupted()) {
    return interrupted_exit_code();
  }

  log_step("initialize blank-frame control template");
  std::vector<std::uint16_t> blank(kDrmPhaseWords);
  init_blank_phase_frame(blank.data());
  log_ok("blank template initialized");

  if (!context.copy_to_buffer(0, blank.data())) {
    return 1;
  }
  if (!context.latch_buffer(0)) {
    return 1;
  }
  (void)hold_for_ms(options.hold_ms, "blank frame latched with rails off");
  const bool blanked = context.blank_latched_crtc();
  return blanked ? interrupted_exit_code() : 1;
}

int run_rails(const Options &options) {
  ProbeContext context(options);
  if (!context.open_drm()) {
    return 1;
  }
  if (interrupted()) {
    return interrupted_exit_code();
  }
  if (!context.rails_on()) {
    return 1;
  }
  (void)hold_for_ms(options.hold_ms, "rails energized, no waveform drive");
  const bool off = context.rails_off();
  return off ? interrupted_exit_code() : 1;
}

int run_flash(Options options) {
  std::string error;
  if (!resolve_waveform_defaults(&options, &error)) {
    log_fail(error);
    return 1;
  }

  ProbeContext context(options);
  if (!context.open_drm()) {
    return 1;
  }
  if (interrupted()) {
    return interrupted_exit_code();
  }

  SwtconWaveform waveform;
  if (!load_waveforms(options, &waveform)) {
    return 1;
  }
  if (interrupted()) {
    return interrupted_exit_code();
  }

  std::array<std::vector<std::uint16_t>, kActivePhaseSlots> phase_slots;
  std::vector<std::uint16_t> waveform_packed;
  int waveform_phase_count = 0;
  if (!generate_fullscreen_pattern(options, waveform, &phase_slots,
                                   &waveform_packed, &waveform_phase_count)) {
    return 1;
  }
  const bool waveform_once = waveform_phase_count > 0;
  if (!waveform_once && !copy_phase_slots(&context, phase_slots)) {
    return interrupted() ? interrupted_exit_code() : 1;
  }
  if (waveform_once &&
      !context.copy_to_buffer(0, waveform_packed.data())) {
    return interrupted() ? interrupted_exit_code() : 1;
  }
  if (interrupted()) {
    return interrupted_exit_code();
  }

  if (!context.rails_on()) {
    return 1;
  }
  if (!context.set_dpms_on()) {
    return 1;
  }
  if (!context.latch_buffer(0)) {
    return 1;
  }
  if (waveform_once) {
    if (!stream_waveform_once(&context, waveform_packed,
                              waveform_phase_count)) {
      return interrupted() ? interrupted_exit_code() : 1;
    }
  } else if (!stream_continuous(&context, options)) {
    return interrupted() ? interrupted_exit_code() : 1;
  }
  (void)hold_for_ms(options.hold_ms, "post-flash settle");
  const bool blanked = context.blank_latched_crtc();
  const bool rails_off = context.rails_off();
  return blanked && rails_off ? interrupted_exit_code() : 1;
}

int run(const Options &options) {
  log_ok(std::string("SWTCON probe stage=") + stage_name(options.stage) +
         " hold_ms=" + std::to_string(options.hold_ms) +
         " duration_ms=" + std::to_string(options.duration_ms) +
         " frames=" + std::to_string(options.frames) + " pattern=" +
         pattern_name(options.pattern) + " card=" + options.card_path);
  switch (options.stage) {
  case Stage::kInfo:
    return run_info(options);
  case Stage::kBlank:
    return run_blank(options);
  case Stage::kRails:
    return run_rails(options);
  case Stage::kFlash:
    return run_flash(options);
  }
  return 1;
}

} // namespace
} // namespace pluto::swtcon::probe

int main(int argc, char **argv) {
  using namespace pluto::swtcon::probe;

  install_signal_handlers();

  Options options;
  std::string error;
  if (!parse_args(argc, argv, &options, &error)) {
    log_fail(error);
    print_usage(argv[0]);
    return 2;
  }
  if (options.show_help) {
    print_usage(argv[0]);
    return 0;
  }

  try {
    return run(options);
  } catch (const std::exception &ex) {
    log_fail(std::string("unhandled exception: ") + ex.what());
    return 1;
  } catch (...) {
    log_fail("unhandled unknown exception");
    return 1;
  }
}
