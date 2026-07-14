#include "engine/device_identity.h"

#include <sys/utsname.h>

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iterator>
#include <span>
#include <string>

#include "generated/device_profiles.h"

namespace pluto {
namespace {

std::string normalized_identity(std::string_view raw) {
  std::string normalized;
  normalized.reserve(raw.size());
  for (const unsigned char value : raw) {
    if (value == '\0' || std::isspace(value) != 0) {
      normalized.push_back(' ');
    } else {
      normalized.push_back(
          static_cast<char>(std::tolower(static_cast<unsigned char>(value))));
    }
  }
  return normalized;
}

bool contains_any(const std::string &value,
                  std::span<const std::string_view> tokens) {
  for (const std::string_view token : tokens) {
    if (value.find(token) != std::string::npos) {
      return true;
    }
  }
  return false;
}

std::string read_identity_file(const std::string &path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    return {};
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::string kernel_architecture() {
  struct utsname identity {};
  if (::uname(&identity) != 0) {
    return {};
  }
  return identity.machine;
}

} // namespace

RemarkableDeviceIdentity classify_remarkable_device_identity(
    const RemarkableDeviceIdentityEvidence &evidence) {
  const std::string board =
      normalized_identity(evidence.machine + " " + evidence.device_tree_model);
  const std::string compatible =
      normalized_identity(evidence.device_tree_compatible);
  std::string architecture = normalized_identity(evidence.architecture);
  architecture.erase(
      std::remove_if(architecture.begin(), architecture.end(),
                     [](unsigned char value) { return std::isspace(value); }),
      architecture.end());

  const GeneratedDeviceProfile *match = nullptr;
  for (const GeneratedDeviceProfile &profile : kGeneratedDeviceProfiles) {
    const bool architecture_matches =
        std::find(profile.architectures.begin(), profile.architectures.end(),
                  architecture) != profile.architectures.end();
    if (!architecture_matches || !contains_any(board, profile.board_tokens) ||
        !contains_any(compatible, profile.compatible_tokens)) {
      continue;
    }
    if (match != nullptr) {
      return {};
    }
    match = &profile;
  }
  if (match != nullptr) {
    return {
        .profile_id = std::string(match->id),
        .model = std::string(match->wire_model),
        .codename = std::string(match->codename),
    };
  }
  return {};
}

RemarkableDeviceIdentity
probe_remarkable_device_identity(const RemarkableDeviceIdentityPaths &paths) {
  return classify_remarkable_device_identity({
      .machine = read_identity_file(paths.soc_machine),
      .device_tree_model = read_identity_file(paths.device_tree_model),
      .device_tree_compatible =
          read_identity_file(paths.device_tree_compatible),
      .architecture = paths.architecture_override.empty()
                          ? kernel_architecture()
                          : paths.architecture_override,
  });
}

} // namespace pluto
