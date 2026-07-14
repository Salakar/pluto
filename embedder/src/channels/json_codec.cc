#include "channels/json_codec.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <sstream>

namespace pluto {
namespace {

void append_escaped(std::string* out, const std::string& value) {
  out->push_back('"');
  for (char ch : value) {
    switch (ch) {
      case '"':
        out->append("\\\"");
        break;
      case '\\':
        out->append("\\\\");
        break;
      case '\n':
        out->append("\\n");
        break;
      case '\r':
        out->append("\\r");
        break;
      case '\t':
        out->append("\\t");
        break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20u) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x",
                        static_cast<unsigned char>(ch));
          out->append(buffer);
        } else {
          out->push_back(ch);
        }
        break;
    }
  }
  out->push_back('"');
}

class Parser {
 public:
  explicit Parser(std::string_view input) : input_(input) {}

  std::optional<JsonValue> parse() {
    skip_ws();
    std::optional<JsonValue> value = parse_value();
    skip_ws();
    if (!value.has_value() || offset_ != input_.size()) {
      return std::nullopt;
    }
    return value;
  }

 private:
  void skip_ws() {
    while (offset_ < input_.size() &&
           std::isspace(static_cast<unsigned char>(input_[offset_]))) {
      ++offset_;
    }
  }

  bool consume(char expected) {
    skip_ws();
    if (offset_ >= input_.size() || input_[offset_] != expected) {
      return false;
    }
    ++offset_;
    return true;
  }

  std::optional<JsonValue> parse_value() {
    skip_ws();
    if (offset_ >= input_.size()) {
      return std::nullopt;
    }
    const char ch = input_[offset_];
    if (ch == '"') {
      return parse_string();
    }
    if (ch == '{') {
      return parse_object();
    }
    if (ch == '[') {
      return parse_list();
    }
    if (input_.substr(offset_, 4) == "null") {
      offset_ += 4;
      return JsonValue();
    }
    if (input_.substr(offset_, 4) == "true") {
      offset_ += 4;
      return JsonValue(true);
    }
    if (input_.substr(offset_, 5) == "false") {
      offset_ += 5;
      return JsonValue(false);
    }
    return parse_number();
  }

  std::optional<JsonValue> parse_string() {
    if (!consume('"')) {
      return std::nullopt;
    }
    std::string out;
    while (offset_ < input_.size()) {
      const char ch = input_[offset_++];
      if (ch == '"') {
        return JsonValue(std::move(out));
      }
      if (ch != '\\') {
        out.push_back(ch);
        continue;
      }
      if (offset_ >= input_.size()) {
        return std::nullopt;
      }
      const char escaped = input_[offset_++];
      switch (escaped) {
        case '"':
        case '\\':
        case '/':
          out.push_back(escaped);
          break;
        case 'n':
          out.push_back('\n');
          break;
        case 'r':
          out.push_back('\r');
          break;
        case 't':
          out.push_back('\t');
          break;
        default:
          return std::nullopt;
      }
    }
    return std::nullopt;
  }

  std::optional<JsonValue> parse_number() {
    const size_t start = offset_;
    if (offset_ < input_.size() && input_[offset_] == '-') {
      ++offset_;
    }
    while (offset_ < input_.size() &&
           std::isdigit(static_cast<unsigned char>(input_[offset_]))) {
      ++offset_;
    }
    if (offset_ < input_.size() && input_[offset_] == '.') {
      ++offset_;
      while (offset_ < input_.size() &&
             std::isdigit(static_cast<unsigned char>(input_[offset_]))) {
        ++offset_;
      }
    }
    if (start == offset_) {
      return std::nullopt;
    }
    return JsonValue(std::strtod(std::string(input_.substr(start, offset_ - start))
                                     .c_str(),
                                 nullptr));
  }

  std::optional<JsonValue> parse_list() {
    if (!consume('[')) {
      return std::nullopt;
    }
    JsonValue::List list;
    skip_ws();
    if (consume(']')) {
      return JsonValue(std::move(list));
    }
    while (true) {
      std::optional<JsonValue> value = parse_value();
      if (!value.has_value()) {
        return std::nullopt;
      }
      list.push_back(std::move(*value));
      if (consume(']')) {
        return JsonValue(std::move(list));
      }
      if (!consume(',')) {
        return std::nullopt;
      }
    }
  }

  std::optional<JsonValue> parse_object() {
    if (!consume('{')) {
      return std::nullopt;
    }
    JsonValue::Object object;
    skip_ws();
    if (consume('}')) {
      return JsonValue(std::move(object));
    }
    while (true) {
      std::optional<JsonValue> key = parse_string();
      if (!key.has_value() || key->string() == nullptr || !consume(':')) {
        return std::nullopt;
      }
      std::optional<JsonValue> value = parse_value();
      if (!value.has_value()) {
        return std::nullopt;
      }
      object.emplace_back(*key->string(), std::move(*value));
      if (consume('}')) {
        return JsonValue(std::move(object));
      }
      if (!consume(',')) {
        return std::nullopt;
      }
    }
  }

  std::string_view input_;
  size_t offset_ = 0;
};

const JsonValue* object_get(const JsonValue::Object& object, const char* key) {
  for (const auto& entry : object) {
    if (entry.first == key) {
      return &entry.second;
    }
  }
  return nullptr;
}

}  // namespace

std::string json_encode(const JsonValue& value) {
  const JsonValue::Storage& storage = value.storage();
  if (std::holds_alternative<std::monostate>(storage)) {
    return "null";
  }
  if (const bool* b = std::get_if<bool>(&storage)) {
    return *b ? "true" : "false";
  }
  if (const double* number = std::get_if<double>(&storage)) {
    std::ostringstream out;
    out << *number;
    return out.str();
  }
  if (const std::string* string = std::get_if<std::string>(&storage)) {
    std::string out;
    append_escaped(&out, *string);
    return out;
  }
  if (const JsonValue::List* list = std::get_if<JsonValue::List>(&storage)) {
    std::string out = "[";
    for (size_t i = 0; i < list->size(); ++i) {
      if (i != 0) {
        out.push_back(',');
      }
      out += json_encode((*list)[i]);
    }
    out.push_back(']');
    return out;
  }
  const JsonValue::Object* object = std::get_if<JsonValue::Object>(&storage);
  std::string out = "{";
  if (object != nullptr) {
    for (size_t i = 0; i < object->size(); ++i) {
      if (i != 0) {
        out.push_back(',');
      }
      append_escaped(&out, (*object)[i].first);
      out.push_back(':');
      out += json_encode((*object)[i].second);
    }
  }
  out.push_back('}');
  return out;
}

std::optional<JsonValue> json_decode(const uint8_t* data, size_t size) {
  if (data == nullptr && size != 0) {
    return std::nullopt;
  }
  Parser parser(std::string_view(reinterpret_cast<const char*>(data), size));
  return parser.parse();
}

std::vector<uint8_t> json_method_success(const JsonValue& value) {
  JsonValue envelope(JsonValue::List{value});
  const std::string json = json_encode(envelope);
  return std::vector<uint8_t>(json.begin(), json.end());
}

std::vector<uint8_t> json_method_error(const std::string& code,
                                       const std::string& message,
                                       const JsonValue& details) {
  JsonValue envelope(JsonValue::List{JsonValue(code), JsonValue(message),
                                     details});
  const std::string json = json_encode(envelope);
  return std::vector<uint8_t>(json.begin(), json.end());
}

std::optional<JsonMethodCall> json_method_decode(const uint8_t* data,
                                                 size_t size) {
  std::optional<JsonValue> decoded = json_decode(data, size);
  if (!decoded.has_value() || decoded->object() == nullptr) {
    return std::nullopt;
  }
  const JsonValue* method = object_get(*decoded->object(), "method");
  if (method == nullptr || method->string() == nullptr) {
    return std::nullopt;
  }
  const JsonValue* args = object_get(*decoded->object(), "args");
  return JsonMethodCall{*method->string(), args == nullptr ? JsonValue() : *args};
}

}  // namespace pluto
