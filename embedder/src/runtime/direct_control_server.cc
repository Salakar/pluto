#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "runtime/direct_control_server.h"

#include "runtime/sha256.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <exception>
#include <filesystem>
#include <limits>
#include <mutex>
#include <span>
#include <string_view>
#include <thread>
#include <unordered_set>
#include <utility>

#if defined(__linux__)
#include <fcntl.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace pluto {
namespace {

constexpr char kSocketLeaf[] = "embedder-control.sock";

void set_error(std::string *error, const std::string &message) {
  if (error != nullptr) {
    *error = message;
  }
}

#if defined(__linux__)
constexpr std::size_t kProtocolMaxPacketBytes = 32768;
constexpr std::size_t kMaximumTokenBytes = 128;
constexpr std::size_t kMaximumErrorMessageBytes = 512;
constexpr int kClientTimeoutSeconds = 2;
constexpr char kScreenshotDirectoryLeaf[] = "screenshots";
constexpr std::array<std::uint8_t, 8> kPngSignature = {
    0x89u, 'P', 'N', 'G', '\r', '\n', 0x1au, '\n'};

std::string errno_message(const char *operation) {
  return std::string(operation) + ": " + std::strerror(errno);
}

bool is_valid_utf8(std::string_view input) {
  std::size_t index = 0;
  while (index < input.size()) {
    const auto first = static_cast<std::uint8_t>(input[index]);
    if (first <= 0x7fu) {
      ++index;
      continue;
    }
    std::size_t count = 0;
    std::uint32_t value = 0;
    std::uint32_t minimum = 0;
    if (first >= 0xc2u && first <= 0xdfu) {
      count = 2;
      value = first & 0x1fu;
      minimum = 0x80u;
    } else if (first >= 0xe0u && first <= 0xefu) {
      count = 3;
      value = first & 0x0fu;
      minimum = 0x800u;
    } else if (first >= 0xf0u && first <= 0xf4u) {
      count = 4;
      value = first & 0x07u;
      minimum = 0x10000u;
    } else {
      return false;
    }
    if (index + count > input.size()) {
      return false;
    }
    for (std::size_t offset = 1; offset < count; ++offset) {
      const auto continuation =
          static_cast<std::uint8_t>(input[index + offset]);
      if ((continuation & 0xc0u) != 0x80u) {
        return false;
      }
      value = (value << 6u) | (continuation & 0x3fu);
    }
    if (value < minimum || value > 0x10ffffu ||
        (value >= 0xd800u && value <= 0xdfffu)) {
      return false;
    }
    index += count;
  }
  return true;
}

void append_utf8(std::uint32_t codepoint, std::string *out) {
  if (codepoint <= 0x7fu) {
    out->push_back(static_cast<char>(codepoint));
  } else if (codepoint <= 0x7ffu) {
    out->push_back(static_cast<char>(0xc0u | (codepoint >> 6u)));
    out->push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
  } else if (codepoint <= 0xffffu) {
    out->push_back(static_cast<char>(0xe0u | (codepoint >> 12u)));
    out->push_back(static_cast<char>(0x80u | ((codepoint >> 6u) & 0x3fu)));
    out->push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
  } else {
    out->push_back(static_cast<char>(0xf0u | (codepoint >> 18u)));
    out->push_back(static_cast<char>(0x80u | ((codepoint >> 12u) & 0x3fu)));
    out->push_back(static_cast<char>(0x80u | ((codepoint >> 6u) & 0x3fu)));
    out->push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
  }
}

int hex_value(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}

enum class DirectAction : std::uint8_t {
  kScreenshot,
  kTapSwitcherPreview,
  kDrawStroke,
};

struct ParsedRequest {
  std::string request_id;
  std::optional<std::string> app_id;
  DirectScreenshotSurface surface = DirectScreenshotSurface::kLogical;
  DirectAction action = DirectAction::kScreenshot;
};

class RequestParser {
public:
  explicit RequestParser(std::string_view input) : input_(input) {}

  bool parse(ParsedRequest *request, DirectControlFailure *failure) {
    if (request == nullptr || failure == nullptr || !is_valid_utf8(input_)) {
      return fail(failure, "bad-request",
                  "request is not a valid UTF-8 JSON object");
    }
    skip_whitespace();
    if (!consume('{')) {
      return fail(failure, "bad-request", "request must be a JSON object");
    }

    bool have_schema = false;
    bool have_request_id = false;
    bool have_action = false;
    bool have_app_id = false;
    bool have_surface = false;
    std::string schema;
    std::string action;
    std::string surface;
    std::unordered_set<std::string> keys;

    skip_whitespace();
    if (!peek('}')) {
      for (;;) {
        std::string key;
        if (!parse_string(&key) || !keys.insert(key).second || !consume(':')) {
          return fail(failure, "bad-request",
                      "request has malformed or duplicate fields");
        }
        if (key == "schema") {
          have_schema = parse_number(&schema);
          if (!have_schema) {
            return fail(failure, "bad-schema", "schema must be 1");
          }
        } else if (key == "requestId") {
          have_request_id = parse_string(&request->request_id);
          if (!have_request_id) {
            return fail(failure, "bad-request-id",
                        "requestId must be a string");
          }
        } else if (key == "action") {
          have_action = parse_string(&action);
          if (!have_action) {
            return fail(failure, "bad-action", "action must be a string");
          }
        } else if (key == "appId") {
          have_app_id = true;
          skip_whitespace();
          if (consume_literal("null")) {
            request->app_id.reset();
          } else {
            std::string app_id;
            if (!parse_string(&app_id)) {
              return fail(failure, "bad-args",
                          "appId must be a string or null");
            }
            request->app_id = std::move(app_id);
          }
        } else if (key == "surface") {
          have_surface = parse_string(&surface);
          if (!have_surface) {
            return fail(failure, "bad-args", "surface must be a string");
          }
        } else if (!skip_value(0)) {
          return fail(failure, "bad-request", "request contains invalid JSON");
        }

        skip_whitespace();
        if (consume('}')) {
          break;
        }
        if (!consume(',')) {
          return fail(failure, "bad-request", "request contains invalid JSON");
        }
      }
    } else {
      consume('}');
    }
    skip_whitespace();
    if (offset_ != input_.size()) {
      return fail(failure, "bad-request", "request has trailing data");
    }
    if (!have_schema || schema != "1") {
      return fail(failure, "bad-schema", "unsupported control schema");
    }
    if (!have_request_id ||
        !printable_ascii(request->request_id, true, kMaximumTokenBytes)) {
      return fail(failure, "bad-request-id",
                  "requestId must be 1-128 printable ASCII bytes");
    }
    if (!have_action ||
        (action != "screenshot" && action != "tap-switcher-preview" &&
         action != "draw-stroke")) {
      return fail(failure, "bad-action", "unsupported control action");
    }
    if (!have_app_id) {
      return fail(failure, "bad-args", "control action requires appId");
    }
    if (request->app_id.has_value() &&
        !printable_ascii(*request->app_id, false, kMaximumTokenBytes)) {
      return fail(failure, "bad-args",
                  "appId must be 1-128 visible ASCII bytes");
    }
    if (action == "screenshot") {
      request->action = DirectAction::kScreenshot;
      if (!have_surface) {
        return fail(failure, "bad-args", "screenshot requires surface");
      }
      if (surface == "logical") {
        request->surface = DirectScreenshotSurface::kLogical;
      } else if (surface == "post-dither") {
        request->surface = DirectScreenshotSurface::kPostDither;
      } else {
        return fail(failure, "bad-args",
                    "surface must be logical or post-dither");
      }
    } else {
      request->action = action == "tap-switcher-preview"
                            ? DirectAction::kTapSwitcherPreview
                            : DirectAction::kDrawStroke;
      if (!request->app_id.has_value()) {
        return fail(failure, "bad-args",
                    action == "tap-switcher-preview"
                        ? "tap-switcher-preview requires a concrete appId"
                        : "draw-stroke requires a concrete appId");
      }
      if (have_surface) {
        return fail(
            failure, "bad-args",
            action == "tap-switcher-preview"
                ? "tap-switcher-preview does not accept a screenshot surface"
                : "draw-stroke does not accept a screenshot surface");
      }
    }
    return true;
  }

private:
  static bool fail(DirectControlFailure *failure, const char *code,
                   const char *message) {
    failure->code = code;
    failure->message = message;
    return false;
  }

  static bool printable_ascii(std::string_view value, bool allow_space,
                              std::size_t maximum) {
    if (value.empty() || value.size() > maximum) {
      return false;
    }
    for (const unsigned char byte : value) {
      const unsigned char minimum = allow_space ? 0x20u : 0x21u;
      if (byte < minimum || byte > 0x7eu) {
        return false;
      }
    }
    return true;
  }

  void skip_whitespace() {
    while (offset_ < input_.size() &&
           (input_[offset_] == ' ' || input_[offset_] == '\n' ||
            input_[offset_] == '\r' || input_[offset_] == '\t')) {
      ++offset_;
    }
  }

  bool peek(char expected) {
    skip_whitespace();
    return offset_ < input_.size() && input_[offset_] == expected;
  }

  bool consume(char expected) {
    skip_whitespace();
    if (offset_ >= input_.size() || input_[offset_] != expected) {
      return false;
    }
    ++offset_;
    return true;
  }

  bool consume_literal(std::string_view literal) {
    skip_whitespace();
    if (input_.substr(offset_, literal.size()) != literal) {
      return false;
    }
    offset_ += literal.size();
    return true;
  }

  bool parse_hex_quad(std::uint32_t *value) {
    if (value == nullptr || offset_ + 4 > input_.size()) {
      return false;
    }
    std::uint32_t decoded = 0;
    for (std::size_t index = 0; index < 4; ++index) {
      const int digit = hex_value(input_[offset_++]);
      if (digit < 0) {
        return false;
      }
      decoded = (decoded << 4u) | static_cast<std::uint32_t>(digit);
    }
    *value = decoded;
    return true;
  }

  bool parse_string(std::string *out) {
    if (out == nullptr || !consume('"')) {
      return false;
    }
    out->clear();
    while (offset_ < input_.size()) {
      const unsigned char byte = static_cast<unsigned char>(input_[offset_++]);
      if (byte == '"') {
        return true;
      }
      if (byte < 0x20u) {
        return false;
      }
      if (byte != '\\') {
        out->push_back(static_cast<char>(byte));
        continue;
      }
      if (offset_ >= input_.size()) {
        return false;
      }
      const char escaped = input_[offset_++];
      switch (escaped) {
      case '"':
      case '\\':
      case '/':
        out->push_back(escaped);
        break;
      case 'b':
        out->push_back('\b');
        break;
      case 'f':
        out->push_back('\f');
        break;
      case 'n':
        out->push_back('\n');
        break;
      case 'r':
        out->push_back('\r');
        break;
      case 't':
        out->push_back('\t');
        break;
      case 'u': {
        std::uint32_t codepoint = 0;
        if (!parse_hex_quad(&codepoint) || codepoint == 0) {
          return false;
        }
        if (codepoint >= 0xd800u && codepoint <= 0xdbffu) {
          if (offset_ + 2 > input_.size() || input_[offset_] != '\\' ||
              input_[offset_ + 1] != 'u') {
            return false;
          }
          offset_ += 2;
          std::uint32_t low = 0;
          if (!parse_hex_quad(&low) || low < 0xdc00u || low > 0xdfffu) {
            return false;
          }
          codepoint =
              0x10000u + ((codepoint - 0xd800u) << 10u) + (low - 0xdc00u);
        } else if (codepoint >= 0xdc00u && codepoint <= 0xdfffu) {
          return false;
        }
        append_utf8(codepoint, out);
        break;
      }
      default:
        return false;
      }
    }
    return false;
  }

  bool parse_number(std::string *out) {
    if (out == nullptr) {
      return false;
    }
    skip_whitespace();
    const std::size_t start = offset_;
    if (offset_ < input_.size() && input_[offset_] == '-') {
      ++offset_;
    }
    if (offset_ >= input_.size()) {
      offset_ = start;
      return false;
    }
    if (input_[offset_] == '0') {
      ++offset_;
      if (offset_ < input_.size() && input_[offset_] >= '0' &&
          input_[offset_] <= '9') {
        offset_ = start;
        return false;
      }
    } else if (input_[offset_] >= '1' && input_[offset_] <= '9') {
      while (offset_ < input_.size() && input_[offset_] >= '0' &&
             input_[offset_] <= '9') {
        ++offset_;
      }
    } else {
      offset_ = start;
      return false;
    }
    if (offset_ < input_.size() && input_[offset_] == '.') {
      ++offset_;
      const std::size_t fraction = offset_;
      while (offset_ < input_.size() && input_[offset_] >= '0' &&
             input_[offset_] <= '9') {
        ++offset_;
      }
      if (offset_ == fraction) {
        offset_ = start;
        return false;
      }
    }
    if (offset_ < input_.size() &&
        (input_[offset_] == 'e' || input_[offset_] == 'E')) {
      ++offset_;
      if (offset_ < input_.size() &&
          (input_[offset_] == '+' || input_[offset_] == '-')) {
        ++offset_;
      }
      const std::size_t exponent = offset_;
      while (offset_ < input_.size() && input_[offset_] >= '0' &&
             input_[offset_] <= '9') {
        ++offset_;
      }
      if (offset_ == exponent) {
        offset_ = start;
        return false;
      }
    }
    *out = std::string(input_.substr(start, offset_ - start));
    return true;
  }

  bool skip_value(std::size_t depth) {
    if (depth > 32) {
      return false;
    }
    skip_whitespace();
    if (offset_ >= input_.size()) {
      return false;
    }
    if (input_[offset_] == '"') {
      std::string ignored;
      return parse_string(&ignored);
    }
    if (input_[offset_] == '{') {
      return skip_object(depth + 1);
    }
    if (input_[offset_] == '[') {
      return skip_array(depth + 1);
    }
    if (consume_literal("true") || consume_literal("false") ||
        consume_literal("null")) {
      return true;
    }
    std::string ignored;
    return parse_number(&ignored);
  }

  bool skip_object(std::size_t depth) {
    if (!consume('{')) {
      return false;
    }
    std::unordered_set<std::string> keys;
    if (peek('}')) {
      return consume('}');
    }
    for (;;) {
      std::string key;
      if (!parse_string(&key) || !keys.insert(key).second || !consume(':') ||
          !skip_value(depth)) {
        return false;
      }
      if (consume('}')) {
        return true;
      }
      if (!consume(',')) {
        return false;
      }
    }
  }

  bool skip_array(std::size_t depth) {
    if (!consume('[')) {
      return false;
    }
    if (peek(']')) {
      return consume(']');
    }
    for (;;) {
      if (!skip_value(depth)) {
        return false;
      }
      if (consume(']')) {
        return true;
      }
      if (!consume(',')) {
        return false;
      }
    }
  }

  std::string_view input_;
  std::size_t offset_ = 0;
};

std::string json_string(std::string_view value) {
  std::string out;
  out.reserve(value.size() + 2);
  out.push_back('"');
  constexpr char kHex[] = "0123456789abcdef";
  for (const unsigned char byte : value) {
    switch (byte) {
    case '"':
      out += "\\\"";
      break;
    case '\\':
      out += "\\\\";
      break;
    case '\b':
      out += "\\b";
      break;
    case '\f':
      out += "\\f";
      break;
    case '\n':
      out += "\\n";
      break;
    case '\r':
      out += "\\r";
      break;
    case '\t':
      out += "\\t";
      break;
    default:
      if (byte < 0x20u) {
        out += "\\u00";
        out.push_back(kHex[byte >> 4u]);
        out.push_back(kHex[byte & 0x0fu]);
      } else {
        out.push_back(static_cast<char>(byte));
      }
      break;
    }
  }
  out.push_back('"');
  return out;
}

std::string failure_response(std::string_view request_id,
                             DirectControlFailure failure) {
  if (failure.code.empty() || failure.code.size() > kMaximumTokenBytes) {
    failure.code = "internal";
  }
  if (failure.message.empty()) {
    failure.message = "control request failed";
  } else if (failure.message.size() > kMaximumErrorMessageBytes) {
    failure.message.resize(kMaximumErrorMessageBytes);
  }
  return "{\"schema\":1,\"requestId\":" + json_string(request_id) +
         ",\"ok\":false,\"error\":{\"code\":" + json_string(failure.code) +
         ",\"message\":" + json_string(failure.message) + "}}";
}

const char *pixel_format_name(PlutoPixelFormat format) {
  switch (format) {
  case kPlutoPixelFormatGray8:
    return "gray8";
  case kPlutoPixelFormatXrgb8888:
    return "xrgb8888";
  case kPlutoPixelFormatRgb565:
    return "rgb565";
  }
  return nullptr;
}

std::size_t bytes_per_pixel(PlutoPixelFormat format) {
  switch (format) {
  case kPlutoPixelFormatGray8:
    return 1;
  case kPlutoPixelFormatXrgb8888:
    return 4;
  case kPlutoPixelFormatRgb565:
    return 2;
  }
  return 0;
}

bool printable_metadata(std::string_view value) {
  if (value.empty() || value.size() > kMaximumTokenBytes) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](unsigned char byte) {
    return byte >= 0x21u && byte <= 0x7eu;
  });
}

bool valid_capture(const DirectScreenshotCapture &capture,
                   DirectScreenshotSurface requested_surface,
                   const std::optional<std::string> &requested_app,
                   DirectControlFailure *failure) {
  const std::size_t bpp = bytes_per_pixel(capture.format);
  if (capture.png.size() < kPngSignature.size() ||
      !std::equal(kPngSignature.begin(), kPngSignature.end(),
                  capture.png.begin()) ||
      capture.width <= 0 || capture.height <= 0 || bpp == 0 ||
      static_cast<std::size_t>(capture.width) >
          std::numeric_limits<std::size_t>::max() / bpp ||
      capture.stride < static_cast<std::size_t>(capture.width) * bpp ||
      !printable_metadata(capture.app_id) || capture.pid <= 0 ||
      capture.surface != requested_surface) {
    failure->code = "internal";
    failure->message = "screenshot callback returned invalid metadata";
    return false;
  }
  if (requested_app.has_value() && capture.app_id != *requested_app) {
    failure->code = "not-found";
    failure->message = "requested app is not the foreground surface";
    return false;
  }
  return true;
}
#endif

} // namespace

const char *direct_screenshot_surface_name(DirectScreenshotSurface surface) {
  switch (surface) {
  case DirectScreenshotSurface::kLogical:
    return "logical";
  case DirectScreenshotSurface::kPostDither:
    return "post-dither";
  }
  return "unknown";
}

class DirectControlServer::Impl {
public:
  explicit Impl(DirectControlServerConfig config) : config_(std::move(config)) {
    if (!config_.run_dir.empty()) {
      run_dir_ =
          std::filesystem::path(config_.run_dir).lexically_normal().string();
    }
  }

  ~Impl() { stop(); }

  bool start(std::string *error) {
#if !defined(__linux__)
    set_error(error, "direct control server is only supported on Linux");
    return false;
#else
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    if (running_.load(std::memory_order_acquire)) {
      return true;
    }
    if (worker_.joinable()) {
      set_error(error, "direct control server has not finished stopping");
      return false;
    }
    if (!config_.screenshot) {
      set_error(error, "direct control server requires a screenshot callback");
      return false;
    }
    if (config_.max_packet_bytes < 256 ||
        config_.max_packet_bytes > kProtocolMaxPacketBytes) {
      set_error(error, "direct control packet limit must be 256-32768 bytes");
      return false;
    }
    const std::filesystem::path run_path(run_dir_);
    if (run_dir_.empty() || !run_path.is_absolute() ||
        run_path.filename().empty() ||
        run_dir_.find('\0') != std::string::npos) {
      set_error(error, "direct control run directory must be an absolute path");
      return false;
    }
    socket_path_ = (run_path / std::filesystem::path(kSocketLeaf)).string();
    if (socket_path_.size() >=
        sizeof((static_cast<sockaddr_un *>(nullptr))->sun_path)) {
      set_error(error, "direct control socket path is too long");
      return false;
    }

    owner_uid_ = ::geteuid();
    if (!prepare_directories(error) || !prepare_socket(error)) {
      cleanup_locked();
      return false;
    }
    stop_requested_.store(false, std::memory_order_release);
    try {
      worker_ = std::thread(&Impl::run, this);
    } catch (const std::exception &exception) {
      set_error(error, std::string("cannot start direct control worker: ") +
                           exception.what());
      cleanup_locked();
      return false;
    }
    running_.store(true, std::memory_order_release);
    return true;
#endif
  }

  void stop() {
#if defined(__linux__)
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    if (worker_.joinable()) {
      stop_requested_.store(true, std::memory_order_release);
      if (wake_fd_ >= 0) {
        std::uint64_t wake = 1;
        while (::write(wake_fd_, &wake, sizeof(wake)) < 0 && errno == EINTR) {
        }
      }
      worker_.join();
    }
    cleanup_locked();
#endif
    running_.store(false, std::memory_order_release);
  }

  bool running() const { return running_.load(std::memory_order_acquire); }

  std::string socket_path() const {
    if (!socket_path_.empty()) {
      return socket_path_;
    }
    if (run_dir_.empty()) {
      return {};
    }
    return (std::filesystem::path(run_dir_) / kSocketLeaf).string();
  }

private:
#if defined(__linux__)
  struct DispatchResult {
    std::string response;
    std::string artifact_leaf;
  };

  bool prepare_directories(std::string *error) {
    if (::mkdir(run_dir_.c_str(), 0700) != 0 && errno != EEXIST) {
      set_error(error,
                errno_message("cannot create direct control run directory"));
      return false;
    }
    struct stat run_stat {};
    if (::lstat(run_dir_.c_str(), &run_stat) != 0 ||
        !S_ISDIR(run_stat.st_mode) || run_stat.st_uid != owner_uid_) {
      set_error(error, "refusing an untrusted direct control run directory");
      return false;
    }
    run_fd_ = ::open(run_dir_.c_str(),
                     O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (run_fd_ < 0) {
      set_error(error,
                errno_message("cannot open direct control run directory"));
      return false;
    }
    struct stat opened_run {};
    if (::fstat(run_fd_, &opened_run) != 0 ||
        opened_run.st_dev != run_stat.st_dev ||
        opened_run.st_ino != run_stat.st_ino || ::fchmod(run_fd_, 0700) != 0) {
      set_error(error, "cannot secure direct control run directory");
      return false;
    }

    if (::mkdirat(run_fd_, kScreenshotDirectoryLeaf, 0700) != 0 &&
        errno != EEXIST) {
      set_error(error, errno_message("cannot create screenshot directory"));
      return false;
    }
    screenshots_fd_ = ::openat(run_fd_, kScreenshotDirectoryLeaf,
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (screenshots_fd_ < 0) {
      set_error(error, errno_message("cannot open screenshot directory"));
      return false;
    }
    struct stat screenshot_stat {};
    if (::fstat(screenshots_fd_, &screenshot_stat) != 0 ||
        !S_ISDIR(screenshot_stat.st_mode) ||
        screenshot_stat.st_uid != owner_uid_ ||
        ::fchmod(screenshots_fd_, 0700) != 0) {
      set_error(error, "refusing an untrusted screenshot directory");
      return false;
    }
    return true;
  }

  bool existing_socket_is_active() const {
    const int probe =
        ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (probe < 0) {
      return true;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, socket_path_.c_str(),
                socket_path_.size() + 1);
    const socklen_t length = static_cast<socklen_t>(
        offsetof(sockaddr_un, sun_path) + socket_path_.size() + 1);
    const bool active =
        ::connect(probe, reinterpret_cast<sockaddr *>(&address), length) == 0;
    const int saved = errno;
    ::close(probe);
    if (active) {
      return true;
    }
    return saved != ECONNREFUSED && saved != ENOENT;
  }

  bool prepare_socket(std::string *error) {
    struct stat existing {};
    if (::fstatat(run_fd_, kSocketLeaf, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
      if (!S_ISSOCK(existing.st_mode) || existing.st_uid != owner_uid_ ||
          (existing.st_mode & 0077) != 0) {
        set_error(error, "refusing an untrusted stale control path");
        return false;
      }
      if (existing_socket_is_active()) {
        set_error(error, "direct control socket is already active");
        return false;
      }
      if (::unlinkat(run_fd_, kSocketLeaf, 0) != 0) {
        set_error(error, errno_message("cannot remove stale control socket"));
        return false;
      }
    } else if (errno != ENOENT) {
      set_error(error, errno_message("cannot inspect direct control socket"));
      return false;
    }

    listen_fd_ =
        ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (listen_fd_ < 0) {
      set_error(error, errno_message("cannot create direct control socket"));
      return false;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, socket_path_.c_str(),
                socket_path_.size() + 1);
    const socklen_t length = static_cast<socklen_t>(
        offsetof(sockaddr_un, sun_path) + socket_path_.size() + 1);
    if (::bind(listen_fd_, reinterpret_cast<sockaddr *>(&address), length) !=
        0) {
      set_error(error, errno_message("cannot bind direct control socket"));
      return false;
    }
    struct stat bound {};
    if (::fstatat(run_fd_, kSocketLeaf, &bound, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISSOCK(bound.st_mode) || bound.st_uid != owner_uid_) {
      (void)::unlinkat(run_fd_, kSocketLeaf, 0);
      set_error(error, "bound direct control socket is not secure");
      return false;
    }
    socket_device_ = bound.st_dev;
    socket_inode_ = bound.st_ino;
    socket_identity_valid_ = true;
    if (::chmod(socket_path_.c_str(), 0600) != 0 ||
        ::listen(listen_fd_, 8) != 0) {
      set_error(error, errno_message("cannot secure direct control socket"));
      return false;
    }
    if (::fstatat(run_fd_, kSocketLeaf, &bound, AT_SYMLINK_NOFOLLOW) != 0 ||
        bound.st_dev != socket_device_ || bound.st_ino != socket_inode_ ||
        (bound.st_mode & 0077) != 0) {
      set_error(error, "bound direct control socket is not mode 0600");
      return false;
    }

    wake_fd_ = ::eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (wake_fd_ < 0) {
      set_error(error, errno_message("cannot create direct control wake fd"));
      return false;
    }
    return true;
  }

  void run() {
    pollfd fds[2] = {{listen_fd_, POLLIN, 0}, {wake_fd_, POLLIN, 0}};
    while (!stop_requested_.load(std::memory_order_acquire)) {
      const int ready = ::poll(fds, 2, -1);
      if (ready < 0) {
        if (errno == EINTR) {
          continue;
        }
        break;
      }
      if ((fds[1].revents & POLLIN) != 0) {
        break;
      }
      if ((fds[0].revents & POLLIN) == 0) {
        continue;
      }
      accept_ready();
    }
  }

  void accept_ready() {
    for (;;) {
      const int client = ::accept4(listen_fd_, nullptr, nullptr, SOCK_CLOEXEC);
      if (client < 0) {
        if (errno == EINTR) {
          continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
          return;
        }
        return;
      }
      handle_client(client);
      ::close(client);
    }
  }

  void handle_client(int client) {
    ucred credentials{};
    socklen_t credential_size = sizeof(credentials);
    if (::getsockopt(client, SOL_SOCKET, SO_PEERCRED, &credentials,
                     &credential_size) != 0 ||
        credential_size != sizeof(credentials) ||
        credentials.uid != owner_uid_) {
      return;
    }

    timeval timeout{};
    timeout.tv_sec = kClientTimeoutSeconds;
    (void)::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       sizeof(timeout));
    (void)::setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       sizeof(timeout));

    std::vector<char> packet(config_.max_packet_bytes + 1);
    const ssize_t received =
        ::recv(client, packet.data(), packet.size(), MSG_TRUNC);
    DispatchResult result;
    if (received <= 0 ||
        static_cast<std::size_t>(received) > config_.max_packet_bytes) {
      result.response = failure_response(
          "", {"bad-request", "request packet is empty or oversized"});
    } else if (std::memchr(packet.data(), '\0',
                           static_cast<std::size_t>(received)) != nullptr) {
      result.response = failure_response(
          "", {"bad-request", "request packet contains an embedded NUL"});
    } else {
      result = dispatch(
          std::string_view(packet.data(), static_cast<std::size_t>(received)));
    }

    const ssize_t sent = ::send(client, result.response.data(),
                                result.response.size(), MSG_NOSIGNAL);
    if (sent != static_cast<ssize_t>(result.response.size()) &&
        !result.artifact_leaf.empty()) {
      (void)::unlinkat(screenshots_fd_, result.artifact_leaf.c_str(), 0);
    }
  }

  DispatchResult dispatch(std::string_view packet) {
    ParsedRequest request;
    DirectControlFailure failure;
    RequestParser parser(packet);
    if (!parser.parse(&request, &failure)) {
      return {failure_response(request.request_id, std::move(failure)), {}};
    }

    if (request.action == DirectAction::kTapSwitcherPreview) {
      return dispatch_pointer_action(request, config_.tap_switcher_preview,
                                     "tap-switcher-preview", 4, 4, &failure);
    }
    if (request.action == DirectAction::kDrawStroke) {
      return dispatch_pointer_action(request, config_.draw_stroke,
                                     "draw-stroke", 4, 256, &failure);
    }

    DirectScreenshotCapture capture;
    bool captured = false;
    try {
      captured = config_.screenshot(request.surface, request.app_id, &capture,
                                    &failure);
    } catch (const std::exception &exception) {
      failure.code = "internal";
      failure.message =
          std::string("screenshot callback failed: ") + exception.what();
    } catch (...) {
      failure.code = "internal";
      failure.message = "screenshot callback failed";
    }
    if (!captured) {
      if (failure.code.empty()) {
        failure.code = "unavailable";
      }
      if (failure.message.empty()) {
        failure.message = "screenshot is not available";
      }
      return {failure_response(request.request_id, std::move(failure)), {}};
    }
    if (!valid_capture(capture, request.surface, request.app_id, &failure)) {
      return {failure_response(request.request_id, std::move(failure)), {}};
    }

    std::string leaf;
    std::string path;
    const std::string digest = sha256_hex(
        std::span<const std::uint8_t>(capture.png.data(), capture.png.size()));
    if (!publish_artifact(capture, &leaf, &path, &failure)) {
      return {failure_response(request.request_id, std::move(failure)), {}};
    }
    const char *format = pixel_format_name(capture.format);
    std::string response =
        "{\"schema\":1,\"requestId\":" + json_string(request.request_id) +
        ",\"ok\":true,\"result\":{\"path\":" + json_string(path) +
        ",\"bytes\":" + std::to_string(capture.png.size()) +
        ",\"sha256\":" + json_string(digest) +
        ",\"appId\":" + json_string(capture.app_id) +
        ",\"pid\":" + std::to_string(capture.pid) + ",\"surface\":" +
        json_string(direct_screenshot_surface_name(capture.surface)) +
        ",\"width\":" + std::to_string(capture.width) +
        ",\"height\":" + std::to_string(capture.height) +
        ",\"stride\":" + std::to_string(capture.stride) +
        ",\"format\":" + json_string(format) + "}}";
    if (response.size() > config_.max_packet_bytes) {
      (void)::unlinkat(screenshots_fd_, leaf.c_str(), 0);
      return {
          failure_response(request.request_id,
                           {"internal", "screenshot response is too large"}),
          {}};
    }
    return {std::move(response), std::move(leaf)};
  }

  DispatchResult dispatch_pointer_action(const ParsedRequest &request,
                                         const DirectPointerHandler &handler,
                                         std::string_view action_name,
                                         std::size_t minimum_events,
                                         std::size_t maximum_events,
                                         DirectControlFailure *failure) {
    const std::string unavailable =
        action_name == "draw-stroke"
            ? "programmatic stroke is not available"
            : "programmatic switcher tap is not available";
    if (!handler || !request.app_id.has_value()) {
      return {
          failure_response(request.request_id, {"unavailable", unavailable}),
          {}};
    }

    DirectPointerResult result;
    bool delivered = false;
    try {
      delivered = handler(*request.app_id, &result, failure);
    } catch (const std::exception &exception) {
      failure->code = "internal";
      failure->message =
          std::string(action_name) + " callback failed: " + exception.what();
    } catch (...) {
      failure->code = "internal";
      failure->message = std::string(action_name) + " callback failed";
    }
    if (!delivered) {
      if (failure->code.empty()) {
        failure->code = "unavailable";
      }
      if (failure->message.empty()) {
        failure->message = unavailable;
      }
      return {failure_response(request.request_id, std::move(*failure)), {}};
    }
    if (result.app_id != *request.app_id || result.pid <= 0 ||
        result.event_count < minimum_events ||
        result.event_count > maximum_events) {
      return {failure_response(
                  request.request_id,
                  {"internal", std::string(action_name) +
                                   " callback returned invalid metadata"}),
              {}};
    }

    std::string response =
        "{\"schema\":1,\"requestId\":" + json_string(request.request_id) +
        ",\"ok\":true,\"result\":{\"appId\":" + json_string(result.app_id) +
        ",\"pid\":" + std::to_string(result.pid) +
        ",\"eventCount\":" + std::to_string(result.event_count) + "}}";
    if (response.size() > config_.max_packet_bytes) {
      return {
          failure_response(request.request_id,
                           {"internal", "draw-stroke response is too large"}),
          {}};
    }
    return {std::move(response), {}};
  }

  bool publish_artifact(const DirectScreenshotCapture &capture,
                        std::string *leaf, std::string *path,
                        DirectControlFailure *failure) {
    const auto clock_value = static_cast<std::uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
    int artifact_fd = -1;
    for (std::uint64_t attempt = 0; attempt < 64; ++attempt) {
      const std::uint64_t sequence = ++artifact_sequence_;
      *leaf = "direct-" + std::to_string(capture.pid) + "-" +
              std::to_string(clock_value) + "-" + std::to_string(sequence) +
              ".png";
      artifact_fd =
          ::openat(screenshots_fd_, leaf->c_str(),
                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
      if (artifact_fd >= 0 || errno != EEXIST) {
        break;
      }
    }
    if (artifact_fd < 0) {
      failure->code = "io";
      failure->message = errno_message("cannot create screenshot artifact");
      return false;
    }

    struct stat artifact_stat {};
    bool ok = ::fstat(artifact_fd, &artifact_stat) == 0 &&
              S_ISREG(artifact_stat.st_mode) &&
              artifact_stat.st_uid == owner_uid_ &&
              artifact_stat.st_nlink == 1 && ::fchmod(artifact_fd, 0600) == 0;
    std::size_t written = 0;
    while (ok && written < capture.png.size()) {
      const ssize_t count = ::write(artifact_fd, capture.png.data() + written,
                                    capture.png.size() - written);
      if (count > 0) {
        written += static_cast<std::size_t>(count);
      } else if (count < 0 && errno == EINTR) {
        continue;
      } else {
        ok = false;
      }
    }
    ok = ok && written == capture.png.size() && ::fsync(artifact_fd) == 0;
    const int close_result = ::close(artifact_fd);
    ok = ok && close_result == 0;
    if (!ok) {
      const int saved = errno;
      (void)::unlinkat(screenshots_fd_, leaf->c_str(), 0);
      failure->code = "io";
      failure->message = "could not publish screenshot artifact";
      errno = saved;
      return false;
    }
    *path = (std::filesystem::path(run_dir_) / kScreenshotDirectoryLeaf / *leaf)
                .string();
    return true;
  }

  void unlink_owned_socket() {
    if (run_fd_ < 0 || !socket_identity_valid_) {
      return;
    }
    struct stat current {};
    if (::fstatat(run_fd_, kSocketLeaf, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISSOCK(current.st_mode) && current.st_uid == owner_uid_ &&
        current.st_dev == socket_device_ && current.st_ino == socket_inode_) {
      (void)::unlinkat(run_fd_, kSocketLeaf, 0);
    }
    socket_identity_valid_ = false;
  }

  void cleanup_locked() {
    running_.store(false, std::memory_order_release);
    if (listen_fd_ >= 0) {
      ::close(listen_fd_);
      listen_fd_ = -1;
    }
    if (wake_fd_ >= 0) {
      ::close(wake_fd_);
      wake_fd_ = -1;
    }
    unlink_owned_socket();
    if (screenshots_fd_ >= 0) {
      ::close(screenshots_fd_);
      screenshots_fd_ = -1;
    }
    if (run_fd_ >= 0) {
      ::close(run_fd_);
      run_fd_ = -1;
    }
  }
#endif

  DirectControlServerConfig config_;
  std::string run_dir_;
  std::string socket_path_;
  std::atomic<bool> running_{false};
  std::mutex lifecycle_mutex_;
#if defined(__linux__)
  std::atomic<bool> stop_requested_{false};
  std::thread worker_;
  int run_fd_ = -1;
  int screenshots_fd_ = -1;
  int listen_fd_ = -1;
  int wake_fd_ = -1;
  uid_t owner_uid_ = 0;
  dev_t socket_device_ = 0;
  ino_t socket_inode_ = 0;
  bool socket_identity_valid_ = false;
  std::uint64_t artifact_sequence_ = 0;
#endif
};

DirectControlServer::DirectControlServer(DirectControlServerConfig config)
    : impl_(std::make_unique<Impl>(std::move(config))) {}

DirectControlServer::~DirectControlServer() = default;

bool DirectControlServer::start(std::string *error) {
  return impl_->start(error);
}

void DirectControlServer::stop() { impl_->stop(); }

bool DirectControlServer::running() const { return impl_->running(); }

std::string DirectControlServer::socket_path() const {
  return impl_->socket_path();
}

} // namespace pluto
