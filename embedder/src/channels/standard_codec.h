#ifndef PLUTO_CHANNELS_STANDARD_CODEC_H_
#define PLUTO_CHANNELS_STANDARD_CODEC_H_

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace pluto {

class StandardValue {
 public:
  using Bytes = std::vector<uint8_t>;
  using List = std::vector<StandardValue>;
  using Map = std::vector<std::pair<StandardValue, StandardValue>>;
  using Storage =
      std::variant<std::monostate, bool, int64_t, double, std::string, Bytes,
                   List, Map>;

  StandardValue() = default;
  StandardValue(std::nullptr_t) {}
  StandardValue(bool value) : value_(value) {}
  StandardValue(int32_t value) : value_(static_cast<int64_t>(value)) {}
  StandardValue(int64_t value) : value_(value) {}
  StandardValue(double value) : value_(value) {}
  StandardValue(const char* value) : value_(std::string(value)) {}
  StandardValue(std::string value) : value_(std::move(value)) {}
  StandardValue(Bytes value) : value_(std::move(value)) {}
  StandardValue(List value) : value_(std::move(value)) {}
  StandardValue(Map value) : value_(std::move(value)) {}

  const Storage& storage() const { return value_; }
  bool is_null() const { return std::holds_alternative<std::monostate>(value_); }

  const std::string* string() const {
    return std::get_if<std::string>(&value_);
  }
  const Map* map() const { return std::get_if<Map>(&value_); }
  const List* list() const { return std::get_if<List>(&value_); }
  const int64_t* integer() const { return std::get_if<int64_t>(&value_); }
  const bool* boolean() const { return std::get_if<bool>(&value_); }

  friend bool operator==(const StandardValue& a, const StandardValue& b) {
    return a.value_ == b.value_;
  }

 private:
  Storage value_;
};

struct MethodCall {
  std::string method;
  StandardValue arguments;
};

struct MethodError {
  std::string code;
  std::string message;
  StandardValue details;
};

class StandardMessageCodec {
 public:
  static std::vector<uint8_t> encode(const StandardValue& value);
  static std::optional<StandardValue> decode(const uint8_t* data, size_t size);
};

class StandardMethodCodec {
 public:
  static std::vector<uint8_t> encode_method_call(const MethodCall& call);
  static std::optional<MethodCall> decode_method_call(const uint8_t* data,
                                                      size_t size);
  static std::vector<uint8_t> encode_success_envelope(
      const StandardValue& result);
  static std::optional<StandardValue> decode_success_envelope(
      const uint8_t* data, size_t size);
  static std::vector<uint8_t> encode_error_envelope(const MethodError& error);
};

StandardValue make_map(
    std::initializer_list<std::pair<StandardValue, StandardValue>> entries);

}  // namespace pluto

#endif  // PLUTO_CHANNELS_STANDARD_CODEC_H_
