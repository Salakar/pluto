#ifndef PLUTO_PRESENTER_SWTCON_SWTCON_RAILS_H_
#define PLUTO_PRESENTER_SWTCON_SWTCON_RAILS_H_

#include "pluto/presenter.h"

#include <string>
#include <vector>

namespace pluto::swtcon {

struct RailWrite {
  std::string path;
  std::string value;
};

class RailsFs {
 public:
  virtual ~RailsFs() = default;
  virtual bool write_file(const std::string& path,
                          const std::string& value,
                          std::string* error) = 0;
};

class RealRailsFs final : public RailsFs {
 public:
  bool write_file(const std::string& path,
                  const std::string& value,
                  std::string* error) override;
};

class SwtconRails final {
 public:
  struct Config {
    bool enable = false;
    bool dry_run = false;
    std::string panel_base = "/sys/devices/platform/cumulus-panel";
    std::string regulator_base = "/sys/bus/i2c/drivers/g2194-regulator/0-0048";
    std::vector<RailWrite>* dry_run_log = nullptr;
    // The xochitl evidence gives six rail voltages. vcom/vpdd path constants
    // are known, but their exact writable values remain device-verified-pending.
    std::string vcom_value;
    std::string vpdd_value;
  };

  static std::vector<RailWrite> planned_writes(const Config& config);
  static PlutoStatus apply(const Config& config,
                             RailsFs* fs,
                             std::string* error);
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SWTCON_RAILS_H_
