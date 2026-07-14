#include "input/record.h"

#include <cctype>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace pluto {
namespace {

bool extract_int64(const std::string& line, const char* key, int64_t* out) {
  const std::string needle = std::string("\"") + key + "\"";
  size_t pos = line.find(needle);
  if (pos == std::string::npos) {
    return false;
  }
  pos = line.find(':', pos + needle.size());
  if (pos == std::string::npos) {
    return false;
  }
  ++pos;
  while (pos < line.size() && std::isspace(static_cast<unsigned char>(line[pos]))) {
    ++pos;
  }
  size_t end = pos;
  if (end < line.size() && (line[end] == '-' || line[end] == '+')) {
    ++end;
  }
  while (end < line.size() && std::isdigit(static_cast<unsigned char>(line[end]))) {
    ++end;
  }
  if (end == pos) {
    return false;
  }
  *out = std::stoll(line.substr(pos, end - pos));
  return true;
}

uint16_t checked_u16(int64_t value, const char* field) {
  if (value < 0 || value > 0xffff) {
    throw std::runtime_error(std::string("jsonl field out of u16 range: ") + field);
  }
  return static_cast<uint16_t>(value);
}

int32_t checked_i32(int64_t value, const char* field) {
  if (value < INT32_MIN || value > INT32_MAX) {
    throw std::runtime_error(std::string("jsonl field out of i32 range: ") + field);
  }
  return static_cast<int32_t>(value);
}

uint64_t read_le_u64(const uint8_t* p) {
  uint64_t value = 0;
  for (int i = 7; i >= 0; --i) {
    value = (value << 8) | p[i];
  }
  return value;
}

uint16_t read_le_u16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
}

int32_t read_le_i32(const uint8_t* p) {
  uint32_t value = static_cast<uint32_t>(p[0]) |
                   (static_cast<uint32_t>(p[1]) << 8) |
                   (static_cast<uint32_t>(p[2]) << 16) |
                   (static_cast<uint32_t>(p[3]) << 24);
  return static_cast<int32_t>(value);
}

}  // namespace

std::vector<RawEvent> parse_jsonl_events(const std::string& jsonl) {
  std::vector<RawEvent> events;
  std::istringstream input(jsonl);
  std::string line;
  size_t line_number = 0;
  while (std::getline(input, line)) {
    ++line_number;
    if (line.empty()) {
      continue;
    }
    int64_t t_us = 0;
    int64_t type = 0;
    int64_t code = 0;
    int64_t value = 0;
    if (!extract_int64(line, "t_us", &t_us) ||
        !extract_int64(line, "type", &type) ||
        !extract_int64(line, "code", &code) ||
        !extract_int64(line, "value", &value)) {
      throw std::runtime_error("invalid input JSONL at line " +
                               std::to_string(line_number));
    }
    events.push_back(RawEvent{
        .ts_us = t_us,
        .type = checked_u16(type, "type"),
        .code = checked_u16(code, "code"),
        .value = checked_i32(value, "value"),
    });
  }
  return events;
}

std::string write_jsonl_events(const std::vector<RawEvent>& events) {
  std::ostringstream out;
  for (const RawEvent& event : events) {
    out << "{\"t_us\":" << event.ts_us << ",\"type\":" << event.type
        << ",\"code\":" << event.code << ",\"value\":" << event.value << "}\n";
  }
  return out.str();
}

std::vector<RawEvent> read_jsonl_events_file(const std::string& path) {
  std::ifstream input(path);
  if (!input) {
    throw std::runtime_error("could not open input fixture: " + path);
  }
  std::ostringstream buffer;
  buffer << input.rdbuf();
  return parse_jsonl_events(buffer.str());
}

void write_jsonl_events_file(const std::string& path,
                             const std::vector<RawEvent>& events) {
  std::ofstream output(path);
  if (!output) {
    throw std::runtime_error("could not write input fixture: " + path);
  }
  output << write_jsonl_events(events);
}

std::vector<RawEvent> parse_linux_input_event_stream(const uint8_t* data,
                                                     size_t size) {
  constexpr size_t kInputEvent64Size = 24;
  if (size % kInputEvent64Size != 0) {
    throw std::runtime_error("input_event stream size is not a 64-bit evdev record multiple");
  }
  std::vector<RawEvent> events;
  for (size_t offset = 0; offset < size; offset += kInputEvent64Size) {
    const uint8_t* p = data + offset;
    const uint64_t sec = read_le_u64(p);
    const uint64_t usec = read_le_u64(p + 8);
    events.push_back(RawEvent{
        .ts_us = static_cast<int64_t>(sec * 1000000ull + usec),
        .type = read_le_u16(p + 16),
        .code = read_le_u16(p + 18),
        .value = read_le_i32(p + 20),
    });
  }
  return events;
}

}  // namespace pluto
