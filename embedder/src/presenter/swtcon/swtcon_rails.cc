#include "presenter/swtcon/swtcon_rails.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>

namespace pluto::swtcon {
namespace {

std::string join_path(const std::string& base, const char* leaf) {
  if (base.empty() || base.back() == '/') {
    return base + leaf;
  }
  return base + "/" + leaf;
}

void set_error(std::string* error, const std::string& message) {
  if (error != nullptr) {
    *error = message;
  }
}

}  // namespace

bool RealRailsFs::write_file(const std::string& path,
                             const std::string& value,
                             std::string* error) {
  std::ofstream out(path);
  if (!out) {
    set_error(error, "open " + path + ": " + std::strerror(errno));
    return false;
  }
  out << value;
  if (!out) {
    set_error(error, "write " + path + ": " + std::strerror(errno));
    return false;
  }
  return true;
}

std::vector<RailWrite> SwtconRails::planned_writes(const Config& config) {
  std::vector<RailWrite> writes;
  writes.push_back({join_path(config.panel_base, "vpos1"), "6.0"});
  writes.push_back({join_path(config.panel_base, "vpos2"), "12.0"});
  writes.push_back({join_path(config.panel_base, "vpos3"), "24.0"});
  writes.push_back({join_path(config.panel_base, "vneg1"), "-24.0"});
  writes.push_back({join_path(config.panel_base, "vneg2"), "-12.0"});
  writes.push_back({join_path(config.panel_base, "vneg3"), "-6.0"});
  if (!config.vcom_value.empty()) {
    writes.push_back({join_path(config.panel_base, "vcom"), config.vcom_value});
  }
  if (!config.vpdd_value.empty()) {
    writes.push_back({join_path(config.panel_base, "vpdd"), config.vpdd_value});
  }
  writes.push_back({join_path(config.regulator_base, "vpdd_length"), "30000"});
  writes.push_back({join_path(config.regulator_base, "enable_nowait"), "1"});
  return writes;
}

PlutoStatus SwtconRails::apply(const Config& config,
                                 RailsFs* fs,
                                 std::string* error) {
  if (!config.enable) {
    if (config.dry_run_log != nullptr) {
      config.dry_run_log->clear();
    }
    return kPlutoStatusOk;
  }
  const std::vector<RailWrite> writes = planned_writes(config);
  if (config.dry_run) {
    if (config.dry_run_log != nullptr) {
      *config.dry_run_log = writes;
    }
    for (const RailWrite& write : writes) {
      std::fprintf(stderr, "swtcon rails dry-run: %s <- %s\n",
                   write.path.c_str(), write.value.c_str());
    }
    return kPlutoStatusOk;
  }
  if (fs == nullptr) {
    set_error(error, "rails enabled without a filesystem writer");
    return kPlutoStatusInvalidArgument;
  }
  for (const RailWrite& write : writes) {
    if (!fs->write_file(write.path, write.value, error)) {
      return kPlutoStatusDeviceLost;
    }
  }
  return kPlutoStatusOk;
}

}  // namespace pluto::swtcon
