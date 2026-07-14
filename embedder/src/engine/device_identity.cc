#include "engine/device_identity.h"

#include <cctype>
#include <fstream>
#include <iterator>
#include <string>

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

bool contains(const std::string& value, const char* needle) {
  return value.find(needle) != std::string::npos;
}

std::string read_identity_file(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    return {};
  }
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void append_identity_file(const std::string& path, std::string* combined) {
  if (combined == nullptr) {
    return;
  }
  const std::string value = read_identity_file(path);
  if (value.empty()) {
    return;
  }
  if (!combined->empty()) {
    combined->push_back(' ');
  }
  combined->append(value);
}

}  // namespace

RemarkableDeviceIdentity classify_remarkable_device_identity(
    std::string_view hardware_identity) {
  const std::string identity = normalized_identity(hardware_identity);
  const bool is_move = contains(identity, "chiappa");
  const bool is_paper_pro = contains(identity, "ferrari");
  const bool is_paper_pure = contains(identity, "tatsu");
  const bool is_remarkable_2 =
      contains(identity, "zero-sugar") ||
      contains(identity, "remarkable 2.0") ||
      contains(identity, "fsl,imx7d-sdb");
  const bool is_remarkable_1 = contains(identity, "zero-gravitas") ||
                               contains(identity, "remarkable 1.0") ||
                               contains(identity, "fsl,imx6sl");
  const int matches = static_cast<int>(is_move) +
                      static_cast<int>(is_paper_pro) +
                      static_cast<int>(is_paper_pure) +
                      static_cast<int>(is_remarkable_2) +
                      static_cast<int>(is_remarkable_1);
  if (matches != 1) {
    return {};
  }
  if (is_move) {
    return {.model = "paperProMove", .codename = "chiappa"};
  }
  if (is_paper_pro) {
    return {.model = "paperPro", .codename = "ferrari"};
  }
  if (is_paper_pure) {
    return {.model = "paperPure", .codename = "tatsu"};
  }
  if (is_remarkable_2) {
    return {.model = "remarkable2", .codename = "zero-sugar"};
  }
  if (is_remarkable_1) {
    return {.model = "remarkable1", .codename = "zero-gravitas"};
  }
  return {};
}

RemarkableDeviceIdentity probe_remarkable_device_identity(
    const RemarkableDeviceIdentityPaths& paths) {
  std::string combined;
  append_identity_file(paths.soc_machine, &combined);
  append_identity_file(paths.device_tree_model, &combined);
  append_identity_file(paths.device_tree_compatible, &combined);
  return classify_remarkable_device_identity(combined);
}

}  // namespace pluto
