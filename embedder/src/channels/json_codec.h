#ifndef PLUTO_CHANNELS_JSON_CODEC_H_
#define PLUTO_CHANNELS_JSON_CODEC_H_

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace pluto {

class JsonValue {
 public:
  using List = std::vector<JsonValue>;
  using Object = std::vector<std::pair<std::string, JsonValue>>;
  using Storage =
      std::variant<std::monostate, bool, double, std::string, List, Object>;

  JsonValue() = default;
  JsonValue(std::nullptr_t) {}
  JsonValue(bool value) : value_(value) {}
  JsonValue(int value) : value_(static_cast<double>(value)) {}
  JsonValue(double value) : value_(value) {}
  JsonValue(const char* value) : value_(std::string(value)) {}
  JsonValue(std::string value) : value_(std::move(value)) {}
  JsonValue(List value) : value_(std::move(value)) {}
  JsonValue(Object value) : value_(std::move(value)) {}

  const Storage& storage() const { return value_; }
  const Object* object() const { return std::get_if<Object>(&value_); }
  const std::string* string() const { return std::get_if<std::string>(&value_); }

 private:
  Storage value_;
};

struct JsonMethodCall {
  std::string method;
  JsonValue arguments;
};

std::string json_encode(const JsonValue& value);
std::optional<JsonValue> json_decode(const uint8_t* data, size_t size);

std::vector<uint8_t> json_method_success(const JsonValue& value);
std::vector<uint8_t> json_method_error(const std::string& code,
                                       const std::string& message,
                                       const JsonValue& details = {});
std::optional<JsonMethodCall> json_method_decode(const uint8_t* data,
                                                 size_t size);

}  // namespace pluto

#endif  // PLUTO_CHANNELS_JSON_CODEC_H_
