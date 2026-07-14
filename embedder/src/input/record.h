#ifndef PLUTO_SRC_INPUT_RECORD_H_
#define PLUTO_SRC_INPUT_RECORD_H_

#include <cstdint>
#include <string>
#include <vector>

#include "input/evdev.h"

namespace pluto {

std::vector<RawEvent> parse_jsonl_events(const std::string& jsonl);
std::string write_jsonl_events(const std::vector<RawEvent>& events);
std::vector<RawEvent> read_jsonl_events_file(const std::string& path);
void write_jsonl_events_file(const std::string& path,
                             const std::vector<RawEvent>& events);

std::vector<RawEvent> parse_linux_input_event_stream(const uint8_t* data,
                                                     size_t size);

}  // namespace pluto

#endif  // PLUTO_SRC_INPUT_RECORD_H_
