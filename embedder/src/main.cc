#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "engine/engine_host.h"
#include "presenter/host_preview.h"
#include "presenter/presenter_contract.h"

namespace {

bool starts_with(const std::string& value, const char* prefix) {
  return value.rfind(prefix, 0) == 0;
}

std::string after_equals(const std::string& value) {
  const size_t pos = value.find('=');
  return pos == std::string::npos ? std::string() : value.substr(pos + 1);
}

std::vector<std::string> split_csv(const std::string& value) {
  std::vector<std::string> out;
  std::stringstream stream(value);
  std::string item;
  while (std::getline(stream, item, ',')) {
    if (!item.empty()) {
      out.push_back(item);
    }
  }
  return out;
}

bool parse_point(const std::string& value, double* x, double* y) {
  const size_t comma = value.find(',');
  if (comma == std::string::npos || x == nullptr || y == nullptr) {
    return false;
  }
  *x = std::stod(value.substr(0, comma));
  *y = std::stod(value.substr(comma + 1));
  return true;
}

PlutoPixelFormat parse_pixel_format(const std::string& value) {
  if (value == "gray8") {
    return kPlutoPixelFormatGray8;
  }
  if (value == "n32" || value == "xrgb8888") {
    return kPlutoPixelFormatXrgb8888;
  }
  return kPlutoPixelFormatRgb565;
}

void print_usage() {
  std::cout
      << "Usage: pluto-embedder --bundle=<path> --engine=<so> "
         "--icu-data=<dat> [options]\n"
         "\n"
         "Modes:\n"
         "  --release   Product AOT (default; loads <bundle>/lib/app.so)\n"
         "  --profile   Profile AOT (loads <bundle>/lib/app.so)\n"
         "  --debug     JIT development/hot reload; requires kernel_blob.bin\n"
         "\n"
         "Options:\n"
         "  [--aot-elf=<so>] "
         "[--ready-file=<absolute-path>] "
         "[--health-file=<absolute-path>] "
         "[--presenter=null|host-headless] [--run-duration-ms=<ms>] "
         "[--rotation=0|90|180|270] [--allowed-rotations=<csv>] "
         "[--auto-rotate] "
         "[--hibernate] "
         "[--tap=<x,y>] [--tap-delay-ms=<ms>] "
         "[--touch[-device=<evdev>]] [--pen[-device=<evdev>]] "
         "[--bezel-redraw] "
         "[--doctor] [--print-config]\n";
}

std::string mode_json(pluto::EngineMode mode) {
  return pluto::engine_mode_name(mode);
}

int run_doctor(const pluto::EngineHostConfig& config) {
  std::string error;
  pluto::EngineLibrary library;
  if (!library.load(config.engine_path, &error)) {
    std::cerr << "doctor: engine load failed: " << error << "\n";
    return 1;
  }
  const PlutoPresenterOps* ops =
      pluto_presenter_by_name(config.presenter_name.c_str());
  if (ops == nullptr) {
    std::cerr << "doctor: presenter not found: " << config.presenter_name
              << "\n";
    return 1;
  }
  if (!pluto::presenter_ops_are_current(ops)) {
    std::cerr << "doctor: presenter operation table is not current\n";
    return 1;
  }
  PlutoPresenter* presenter = nullptr;
  PlutoPresenterConfig presenter_config{};
  presenter_config.struct_size = sizeof(presenter_config);
  presenter_config.backend_name = config.presenter_name.c_str();
  presenter_config.options = config.presenter_options.c_str();
  const PlutoStatus status = ops->open(&presenter_config, &presenter);
  if (status != kPlutoStatusOk) {
    std::cerr << "doctor: presenter open failed: " << status << "\n";
    return 1;
  }
  ops->close(presenter);
  std::cout << "doctor: engine loaded, aot="
            << (library.procs().RunsAOTCompiledDartCode() ? "true" : "false")
            << " presenter=" << ops->name << "\n";
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  pluto::EngineHostConfig config;
  bool print_config = false;
  bool doctor = false;
  std::string explicit_mode_flag;

  const auto select_mode = [&](const std::string& flag,
                               pluto::EngineMode mode) {
    if (!explicit_mode_flag.empty() && explicit_mode_flag != flag) {
      std::cerr << "conflicting mode flags: " << explicit_mode_flag << " and "
                << flag << "\n";
      return false;
    }
    explicit_mode_flag = flag;
    config.mode = mode;
    return true;
  };

  for (int i = 1; i < argc; ++i) {
    const std::string arg(argv[i]);
    if (arg == "--help" || arg == "-h") {
      print_usage();
      return 0;
    }
    if (arg == "--debug") {
      if (!select_mode(arg, pluto::EngineMode::kDebug)) {
        return 2;
      }
    } else if (arg == "--profile") {
      if (!select_mode(arg, pluto::EngineMode::kProfile)) {
        return 2;
      }
    } else if (arg == "--release") {
      if (!select_mode(arg, pluto::EngineMode::kRelease)) {
        return 2;
      }
    } else if (starts_with(arg, "--bundle=")) {
      config.bundle_path = after_equals(arg);
    } else if (starts_with(arg, "--engine=")) {
      config.engine_path = after_equals(arg);
    } else if (starts_with(arg, "--icu-data=")) {
      config.icu_data_path = after_equals(arg);
    } else if (starts_with(arg, "--aot-elf=")) {
      config.aot_elf_path = after_equals(arg);
    } else if (starts_with(arg, "--ready-file=")) {
      config.ready_file_path = after_equals(arg);
      if (config.ready_file_path.empty() ||
          !std::filesystem::path(config.ready_file_path).is_absolute()) {
        std::cerr << "--ready-file must be a non-empty absolute path\n";
        return 2;
      }
    } else if (starts_with(arg, "--health-file=")) {
      config.health_file_path = after_equals(arg);
      if (config.health_file_path.empty() ||
          !std::filesystem::path(config.health_file_path).is_absolute()) {
        std::cerr << "--health-file must be a non-empty absolute path\n";
        return 2;
      }
    } else if (starts_with(arg, "--presenter=")) {
      config.presenter_name = after_equals(arg);
    } else if (starts_with(arg, "--presenter-options=")) {
      config.presenter_options = after_equals(arg);
    } else if (starts_with(arg, "--pixel-format=")) {
      config.pixel_format = parse_pixel_format(after_equals(arg));
    } else if (starts_with(arg, "--rotation=")) {
      config.rotation = std::stoi(after_equals(arg));
    } else if (starts_with(arg, "--allowed-rotations=")) {
      config.allowed_rotation_mask = 0;
      for (const std::string& value : split_csv(after_equals(arg))) {
        const int degrees = std::stoi(value);
        if (degrees == 0) {
          config.allowed_rotation_mask |= 0x1;
        } else if (degrees == 90) {
          config.allowed_rotation_mask |= 0x2;
        } else if (degrees == 180) {
          config.allowed_rotation_mask |= 0x4;
        } else if (degrees == 270) {
          config.allowed_rotation_mask |= 0x8;
        } else {
          std::cerr << "invalid --allowed-rotations value: " << value << "\n";
          return 2;
        }
      }
      if (config.allowed_rotation_mask == 0) {
        std::cerr << "--allowed-rotations must not be empty\n";
        return 2;
      }
    } else if (arg == "--auto-rotate") {
      config.auto_rotate = true;
    } else if (starts_with(arg, "--dpr=")) {
      config.dpr = std::stod(after_equals(arg));
      config.dpr_explicitly_set = true;
    } else if (starts_with(arg, "--vm-service-port=")) {
      config.vm_service_port = std::stoi(after_equals(arg));
    } else if (starts_with(arg, "--vm-service-host=")) {
      config.vm_service_host = after_equals(arg);
    } else if (arg == "--insecure-vm-service") {
      config.insecure_vm_service = true;
    } else if (arg == "--no-vsync-pacer") {
      config.enable_vsync_pacer = false;
    } else if (starts_with(arg, "--run-duration-ms=")) {
      config.run_duration_ms = std::stoi(after_equals(arg));
    } else if (starts_with(arg, "--tap=")) {
      if (!parse_point(after_equals(arg), &config.synthetic_tap_x,
                       &config.synthetic_tap_y)) {
        std::cerr << "invalid --tap value, expected x,y\n";
        return 2;
      }
      config.synthetic_tap = true;
    } else if (arg == "--touch") {
      config.enable_touch = true;
    } else if (starts_with(arg, "--touch-device=")) {
      config.enable_touch = true;
      config.touch_device_path = after_equals(arg);
    } else if (arg == "--pen") {
      config.enable_pen = true;
    } else if (starts_with(arg, "--pen-device=")) {
      config.enable_pen = true;
      config.pen_device_path = after_equals(arg);
    } else if (arg == "--bezel-redraw") {
      config.enable_bezel_redraw = true;
    } else if (arg == "--hibernate") {
      config.enable_hibernation = true;
    } else if (starts_with(arg, "--run-dir=")) {
      config.run_dir = after_equals(arg);
    } else if (starts_with(arg, "--tap-delay-ms=")) {
      config.synthetic_tap_delay_ms = std::stoi(after_equals(arg));
    } else if (starts_with(arg, "--dart-entrypoint-args=")) {
      config.dart_entrypoint_args = split_csv(after_equals(arg));
    } else if (arg == "--doctor") {
      doctor = true;
    } else if (arg == "--print-config") {
      print_config = true;
    } else {
      std::cerr << "unknown argument: " << arg
                << " (run pluto-embedder --help for usage)\n";
      return 2;
    }
  }

  if (argc == 1) {
    print_usage();
    return 0;
  }
  if (config.engine_path.empty()) {
    std::cerr << "--engine must be a non-empty path\n";
    return 2;
  }
  if (config.icu_data_path.empty()) {
    std::cerr << "--icu-data must be a non-empty path\n";
    return 2;
  }

  if (print_config) {
    std::cout << "{\"mode\":\"" << mode_json(config.mode) << "\","
              << "\"engine\":\"" << config.engine_path << "\","
              << "\"presenter\":\"" << config.presenter_name << "\","
              << "\"rotation\":" << config.rotation << ","
              << "\"autoRotate\":"
              << (config.auto_rotate ? "true" : "false") << ","
              << "\"dpr\":" << config.dpr << "}\n";
    return 0;
  }

  if (doctor) {
    return run_doctor(config);
  }

  if (config.bundle_path.empty()) {
    std::cerr << "--bundle=<path> is required to run an app "
                 "(run pluto-embedder --help for usage)\n";
    return 2;
  }

  pluto::EngineHost host(config);
  std::string error;
  if (!host.initialize(&error)) {
    std::cerr << error << "\n";
    return 1;
  }
  if (!host.run(&error)) {
    std::cerr << error << "\n";
    return 1;
  }
  host.shutdown();
  return 0;
}
