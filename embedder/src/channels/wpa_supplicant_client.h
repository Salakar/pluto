#ifndef PLUTO_CHANNELS_WPA_SUPPLICANT_CLIENT_H_
#define PLUTO_CHANNELS_WPA_SUPPLICANT_CLIENT_H_

#include <chrono>
#include <optional>
#include <string>

namespace pluto {

// Minimal client for wpa_supplicant's Unix control socket. Commands and
// credentials are sent in-process, so secrets never appear in a shell command
// or process argument list.
class WpaSupplicantClient {
 public:
  WpaSupplicantClient(std::string control_directory,
                      std::string interface_name);

  std::optional<std::string> request(
      const std::string& command,
      std::chrono::milliseconds timeout = std::chrono::seconds(3)) const;

 private:
  std::string control_directory_;
  std::string interface_name_;
};

}  // namespace pluto

#endif  // PLUTO_CHANNELS_WPA_SUPPLICANT_CLIENT_H_
