#include "presenter/native/rm2/rm2_waveform_program.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <new>
#include <span>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace pluto::native::rm2 {
namespace {

constexpr std::uint32_t kModeFast = 6;
constexpr std::uint32_t kModeUi = 3;
constexpr std::uint32_t kModeText = 2;
constexpr std::uint32_t kModeFull = 2;
constexpr std::array<std::uint32_t, 3> kRequiredRefreshModes = {
    kModeText,
    kModeUi,
    kModeFast,
};
constexpr std::array<std::string_view, 16> kSy7636aFaultStates = {
    "no fault event",   "UVP at VP rail",    "UVP at VN rail",
    "UVP at VPOS rail", "UVP at VNEG rail",  "UVP at VDDH rail",
    "UVP at VEE rail",  "SCP at VP rail",    "SCP at VN rail",
    "SCP at VPOS rail", "SCP at VNEG rail",  "SCP at VDDH rail",
    "SCP at VEE rail",  "SCP at V COM rail", "UVLO",
    "Thermal shutdown",
};

bool fail(std::string *error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
  return false;
}

Rm2PanelPowerState unavailable_power_state(std::string *error,
                                           std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
  return {};
}

int hex_nibble(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  return -1;
}

bool parse_sha256(std::string_view text,
                  std::array<std::uint8_t, kSha256DigestBytes> *out) {
  if (out == nullptr || text.size() != kSha256DigestBytes * 2) {
    return false;
  }
  for (std::size_t index = 0; index < out->size(); ++index) {
    const int high = hex_nibble(text[index * 2]);
    const int low = hex_nibble(text[index * 2 + 1]);
    if (high < 0 || low < 0) {
      return false;
    }
    (*out)[index] = static_cast<std::uint8_t>((high << 4) | low);
  }
  return true;
}

bool parse_fpl_lot(std::string_view path, std::uint16_t *out_lot) {
  if (out_lot == nullptr) {
    return false;
  }
  const std::size_t marker = path.rfind("_R");
  if (marker == std::string_view::npos || marker + 2 >= path.size()) {
    return false;
  }
  const std::size_t begin = marker + 2;
  const std::size_t end = path.find('_', begin);
  if (end == std::string_view::npos || end == begin) {
    return false;
  }
  unsigned int parsed = 0;
  const auto result =
      std::from_chars(path.data() + begin, path.data() + end, parsed);
  if (result.ec != std::errc() || result.ptr != path.data() + end ||
      parsed == 0 || parsed > std::numeric_limits<std::uint16_t>::max()) {
    return false;
  }
  *out_lot = static_cast<std::uint16_t>(parsed);
  return true;
}

bool read_file(std::string_view path, std::vector<std::uint8_t> *out,
               std::string *error) {
  if (out == nullptr) {
    return fail(error, "missing WBF output buffer");
  }
  std::ifstream input(std::string(path), std::ios::binary | std::ios::ate);
  if (!input) {
    return fail(error, "cannot open the accepted RM2 WBF");
  }
  const std::streamoff end = input.tellg();
  if (end <= 0 || static_cast<std::uint64_t>(end) > kMaxWbfFileBytes) {
    return fail(error, "accepted RM2 WBF size is out of bounds");
  }
  out->resize(static_cast<std::size_t>(end));
  input.seekg(0, std::ios::beg);
  input.read(reinterpret_cast<char *>(out->data()), end);
  if (!input || input.gcount() != end) {
    out->clear();
    return fail(error, "accepted RM2 WBF read was incomplete");
  }
  return true;
}

std::optional<std::uint32_t> mode_for(PlutoRefreshClass refresh_class) {
  switch (refresh_class) {
  case kPlutoRefreshFast:
    return kModeFast;
  case kPlutoRefreshUi:
    return kModeUi;
  case kPlutoRefreshText:
    return kModeText;
  case kPlutoRefreshFull:
    return kModeFull;
  }
  return std::nullopt;
}

std::optional<int> parse_temperature_file(const std::filesystem::path &path,
                                          bool value_is_millidegrees) {
  std::ifstream input(path);
  std::string text;
  if (!input || !std::getline(input, text)) {
    return std::nullopt;
  }
  int value = 0;
  const char *begin = text.data();
  const char *end = begin + text.size();
  while (begin < end && std::isspace(static_cast<unsigned char>(*begin))) {
    ++begin;
  }
  while (end > begin && std::isspace(static_cast<unsigned char>(end[-1]))) {
    --end;
  }
  const auto parsed = std::from_chars(begin, end, value);
  if (parsed.ec != std::errc() || parsed.ptr != end) {
    return std::nullopt;
  }
  if (!value_is_millidegrees) {
    if (value < std::numeric_limits<int>::min() / 1000 ||
        value > std::numeric_limits<int>::max() / 1000) {
      return std::nullopt;
    }
    value *= 1000;
  }
  return value;
}

std::optional<std::string> read_trimmed_file(const std::filesystem::path &path,
                                             std::size_t maximum_bytes = 64U) {
  std::ifstream input(path);
  std::string text;
  if (!input || !std::getline(input, text) || text.size() > maximum_bytes) {
    return std::nullopt;
  }
  const auto first = std::find_if_not(text.begin(), text.end(), [](char value) {
    return std::isspace(static_cast<unsigned char>(value));
  });
  const auto last =
      std::find_if_not(text.rbegin(), text.rend(), [](char value) {
        return std::isspace(static_cast<unsigned char>(value));
      }).base();
  if (first >= last) {
    return std::nullopt;
  }
  return std::string(first, last);
}

bool sy7636a_i2c_entry_name(std::string_view name) {
  constexpr std::string_view kAddressSuffix = "-0062";
  if (!name.ends_with(kAddressSuffix) || name.size() == kAddressSuffix.size()) {
    return false;
  }
  return std::all_of(name.begin(), name.end() - kAddressSuffix.size(),
                     [](char value) {
                       return std::isdigit(static_cast<unsigned char>(value));
                     });
}

} // namespace

bool Rm2WaveformProgram::open(const GeneratedDeviceProfile &profile,
                              std::string_view path, std::string *error) {
  clear();
  if (profile.id != "rm2" ||
      profile.display_driver != NativeDisplayDriverKind::kLcdifTcon ||
      profile.panel.signature.empty() ||
      profile.runtime.waveform.accepted_sources.size() != 1) {
    return fail(error, "profile is not the accepted RM2 waveform contract");
  }
  const GeneratedWaveformSourceProfile &source =
      profile.runtime.waveform.accepted_sources.front();
  if (path != source.path ||
      source.panel_signature != profile.panel.signature) {
    return fail(error, "RM2 WBF path or panel signature is not accepted");
  }

  WbfExpectedIdentity expected;
  expected.panel_signature = std::string(source.panel_signature);
  if (!parse_sha256(source.sha256, &expected.sha256) ||
      !parse_fpl_lot(source.path, &expected.fpl_lot)) {
    return fail(error, "generated RM2 WBF identity is malformed");
  }

  std::vector<std::uint8_t> bytes;
  if (!read_file(path, &bytes, error) ||
      !decoder_.open(bytes, expected, error)) {
    clear();
    return false;
  }
  if (decoder_.metadata().mode_count <= kModeFast ||
      decoder_.metadata().temperature_count == 0) {
    clear();
    return fail(error, "accepted RM2 WBF lacks required native modes");
  }
  if (!build_expanded_records(error)) {
    clear();
    return false;
  }
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

void Rm2WaveformProgram::clear() {
  expanded_records_.clear();
  decoder_.clear();
}

bool Rm2WaveformProgram::build_expanded_records(std::string *error) {
  const std::size_t mode_count = decoder_.metadata().mode_count;
  const std::size_t temperature_count = decoder_.metadata().temperature_count;
  try {
    expanded_records_.clear();
    expanded_records_.resize(mode_count * temperature_count);
    for (const std::uint32_t mode : kRequiredRefreshModes) {
      for (std::uint32_t temperature = 0; temperature < temperature_count;
           ++temperature) {
        ExpandedRecord &record =
            expanded_records_[static_cast<std::size_t>(mode) *
                                  temperature_count +
                              temperature];
        const std::uint32_t phases = decoder_.phase_count(mode, temperature);
        if (phases == 0 || phases > std::numeric_limits<std::uint16_t>::max()) {
          return fail(error,
                      "required RM2 WBF record has an invalid phase count");
        }
        const std::size_t cells = static_cast<std::size_t>(phases) * 16U * 16U;
        record.drive_lut.resize(cells);
        record.partial_drive_lut.resize(cells);
        record.phase_count = static_cast<std::uint16_t>(phases);
        for (std::uint32_t phase = 0; phase < phases; ++phase) {
          const std::size_t phase_base =
              static_cast<std::size_t>(phase) * 16U * 16U;
          for (std::uint32_t new_level = 0; new_level < 16; ++new_level) {
            for (std::uint32_t old_level = 0; old_level < 16; ++old_level) {
              std::uint8_t code = 0;
              if (!decoder_.drive_code(
                      mode, temperature,
                      static_cast<std::uint8_t>(old_level * 2U),
                      static_cast<std::uint8_t>(new_level * 2U), phase,
                      &code)) {
                return fail(error,
                            "required RM2 WBF transition cannot be expanded");
              }
              const std::size_t index =
                  phase_base + new_level * 16U + old_level;
              record.drive_lut[index] = code;
              record.partial_drive_lut[index] =
                  old_level == new_level ? 0 : code;
            }
          }
        }
      }
    }
  } catch (const std::bad_alloc &) {
    expanded_records_.clear();
    return fail(error, "RM2 WBF transition LUT allocation failed");
  }
  return true;
}

const Rm2WaveformProgram::ExpandedRecord *
Rm2WaveformProgram::expanded_record(std::uint32_t mode,
                                    std::uint32_t temperature) const {
  const std::size_t temperature_count = decoder_.metadata().temperature_count;
  if (!decoder_.valid() || mode >= decoder_.metadata().mode_count ||
      temperature >= temperature_count) {
    return nullptr;
  }
  const std::size_t index =
      static_cast<std::size_t>(mode) * temperature_count + temperature;
  if (index >= expanded_records_.size() ||
      expanded_records_[index].phase_count == 0) {
    return nullptr;
  }
  return &expanded_records_[index];
}

bool Rm2WaveformProgram::temperature_supported(int milli_celsius) const {
  const auto &metadata = decoder_.metadata();
  if (!valid() || metadata.temperature_count == 0 ||
      metadata.temperature_boundaries_celsius.size() !=
          static_cast<std::size_t>(metadata.temperature_count) + 1U) {
    return false;
  }
  const int minimum =
      static_cast<int>(metadata.temperature_boundaries_celsius.front()) * 1000;
  const int maximum =
      static_cast<int>(metadata.temperature_boundaries_celsius.back()) * 1000;
  return milli_celsius >= minimum && milli_celsius < maximum;
}

bool Rm2WaveformProgram::select(PlutoRefreshClass refresh_class,
                                int milli_celsius,
                                Rm2WaveformSelection *out_selection) const {
  if (out_selection == nullptr || !temperature_supported(milli_celsius)) {
    return false;
  }
  const std::optional<std::uint32_t> mode = mode_for(refresh_class);
  std::uint32_t temperature = 0;
  if (!mode.has_value() ||
      !decoder_.select_temperature(milli_celsius, &temperature)) {
    return false;
  }
  const ExpandedRecord *record = expanded_record(*mode, temperature);
  if (record == nullptr ||
      record->drive_lut.size() !=
          static_cast<std::size_t>(record->phase_count) * 16U * 16U ||
      record->partial_drive_lut.size() != record->drive_lut.size()) {
    return false;
  }
  *out_selection = {
      .mode = *mode,
      .temperature = temperature,
      .phase_count = record->phase_count,
      .drive_lut = record->drive_lut,
      .partial_drive_lut = record->partial_drive_lut,
  };
  return true;
}

bool Rm2WaveformProgram::init_pan_codes(
    int milli_celsius, std::vector<std::uint8_t> *out_codes) const {
  if (out_codes == nullptr || !temperature_supported(milli_celsius)) {
    return false;
  }
  std::uint32_t temperature = 0;
  if (!decoder_.select_temperature(milli_celsius, &temperature)) {
    return false;
  }
  const std::uint32_t phases = decoder_.phase_count(0, temperature);
  if (phases == 0) {
    return false;
  }
  out_codes->clear();
  out_codes->reserve(phases);
  for (std::uint32_t phase = 0; phase < phases; ++phase) {
    std::uint8_t code = 0;
    if (!decoder_.drive_code(0, temperature, 0, 0, phase, &code) || code > 2) {
      out_codes->clear();
      return false;
    }
    out_codes->push_back(code);
  }
  return true;
}

std::optional<int> read_rm2_panel_temperature_millidegrees(std::string *error) {
  namespace fs = std::filesystem;
  std::error_code filesystem_error;
  const fs::directory_iterator end;
  for (fs::directory_iterator entry("/sys/class/hwmon", filesystem_error);
       !filesystem_error && entry != end; entry.increment(filesystem_error)) {
    std::ifstream name_file(entry->path() / "name");
    std::string name;
    if (!name_file || !std::getline(name_file, name) ||
        name != "sy7636a_temperature") {
      continue;
    }
    if (const auto value =
            parse_temperature_file(entry->path() / "temp0", false)) {
      if (error != nullptr) {
        error->clear();
      }
      return value;
    }
    if (const auto value =
            parse_temperature_file(entry->path() / "temp1_input", true)) {
      if (error != nullptr) {
        error->clear();
      }
      return value;
    }
    if (error != nullptr) {
      *error = "SY7636A hwmon node has no readable accepted temperature file";
    }
    return std::nullopt;
  }
  if (error != nullptr) {
    *error = filesystem_error
                 ? "cannot enumerate RM2 hwmon nodes"
                 : "SY7636A panel temperature sensor was not found";
  }
  return std::nullopt;
}

Rm2PanelPowerState
read_rm2_panel_power_state(std::string *error,
                           std::string_view i2c_devices_root) {
  namespace fs = std::filesystem;
  std::error_code filesystem_error;
  std::optional<fs::path> sy7636a_path;
  const fs::directory_iterator end;
  for (fs::directory_iterator entry(fs::path(i2c_devices_root),
                                    filesystem_error);
       !filesystem_error && entry != end; entry.increment(filesystem_error)) {
    if (!sy7636a_i2c_entry_name(entry->path().filename().string())) {
      continue;
    }
    const std::optional<std::string> name =
        read_trimmed_file(entry->path() / "name");
    if (!name.has_value() || *name != "sy7636a") {
      continue;
    }
    if (sy7636a_path.has_value()) {
      return unavailable_power_state(
          error, "multiple SY7636A I2C parents are ambiguous");
    }
    sy7636a_path = entry->path();
  }
  if (filesystem_error) {
    return unavailable_power_state(error, "cannot enumerate RM2 I2C devices");
  }
  if (!sy7636a_path.has_value()) {
    return unavailable_power_state(error, "SY7636A I2C parent was not found");
  }

  const std::optional<std::string> power_good =
      read_trimmed_file(*sy7636a_path / "power_good");
  const std::optional<std::string> state =
      read_trimmed_file(*sy7636a_path / "state");
  if (!power_good.has_value() || !state.has_value()) {
    return unavailable_power_state(
        error, "SY7636A power/fault attributes are unreadable");
  }
  if (*power_good != "ON" && *power_good != "OFF") {
    return unavailable_power_state(
        error,
        "SY7636A power-good attribute has unknown value='" + *power_good + "'");
  }
  if (std::find(kSy7636aFaultStates.begin(), kSy7636aFaultStates.end(),
                std::string_view(*state)) == kSy7636aFaultStates.end()) {
    return unavailable_power_state(
        error,
        "SY7636A fault-state attribute has unknown value='" + *state + "'");
  }
  const std::string latched_fault_event =
      *state == "no fault event" ? std::string{} : *state;
  if (*power_good != "ON") {
    if (error != nullptr) {
      *error = "SY7636A panel power-good='" + *power_good + "' state='" +
               *state + "'";
    }
    return {true, false, latched_fault_event};
  }
  if (error != nullptr) {
    error->clear();
  }
  return {true, true, latched_fault_event};
}

} // namespace pluto::native::rm2
