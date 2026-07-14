#include "channels/standard_codec.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace pluto {
namespace {

enum Type : uint8_t {
  kNull = 0,
  kTrue = 1,
  kFalse = 2,
  kInt32 = 3,
  kInt64 = 4,
  kLargeInt = 5,
  kFloat64 = 6,
  kString = 7,
  kUint8List = 8,
  kList = 12,
  kMap = 13,
};

class Writer {
 public:
  void byte(uint8_t value) { out_.push_back(value); }
  void bytes(const uint8_t* data, size_t size) {
    out_.insert(out_.end(), data, data + size);
  }
  void u16(uint16_t value) {
    byte(static_cast<uint8_t>(value & 0xffu));
    byte(static_cast<uint8_t>((value >> 8u) & 0xffu));
  }
  void u32(uint32_t value) {
    for (uint32_t shift = 0; shift < 32; shift += 8) {
      byte(static_cast<uint8_t>((value >> shift) & 0xffu));
    }
  }
  void u64(uint64_t value) {
    for (uint32_t shift = 0; shift < 64; shift += 8) {
      byte(static_cast<uint8_t>((value >> shift) & 0xffu));
    }
  }
  void size(size_t value) {
    if (value < 254u) {
      byte(static_cast<uint8_t>(value));
    } else if (value <= 0xffffu) {
      byte(254u);
      u16(static_cast<uint16_t>(value));
    } else {
      byte(255u);
      u32(static_cast<uint32_t>(std::min<size_t>(
          value, std::numeric_limits<uint32_t>::max())));
    }
  }
  void align(size_t alignment) {
    while (out_.size() % alignment != 0u) {
      byte(0);
    }
  }
  std::vector<uint8_t> take() { return std::move(out_); }

 private:
  std::vector<uint8_t> out_;
};

class Reader {
 public:
  Reader(const uint8_t* data, size_t size) : data_(data), size_(size) {}

  bool byte(uint8_t* out) {
    if (offset_ >= size_) {
      return false;
    }
    *out = data_[offset_++];
    return true;
  }
  bool u16(uint16_t* out) {
    uint8_t b0 = 0;
    uint8_t b1 = 0;
    if (!byte(&b0) || !byte(&b1)) {
      return false;
    }
    *out = static_cast<uint16_t>(b0) | (static_cast<uint16_t>(b1) << 8u);
    return true;
  }
  bool u32(uint32_t* out) {
    uint32_t value = 0;
    for (uint32_t shift = 0; shift < 32; shift += 8) {
      uint8_t b = 0;
      if (!byte(&b)) {
        return false;
      }
      value |= static_cast<uint32_t>(b) << shift;
    }
    *out = value;
    return true;
  }
  bool u64(uint64_t* out) {
    uint64_t value = 0;
    for (uint32_t shift = 0; shift < 64; shift += 8) {
      uint8_t b = 0;
      if (!byte(&b)) {
        return false;
      }
      value |= static_cast<uint64_t>(b) << shift;
    }
    *out = value;
    return true;
  }
  bool bytes(size_t count, const uint8_t** out) {
    if (count > size_ - offset_) {
      return false;
    }
    *out = data_ + offset_;
    offset_ += count;
    return true;
  }
  bool size(size_t* out) {
    uint8_t first = 0;
    if (!byte(&first)) {
      return false;
    }
    if (first < 254u) {
      *out = first;
      return true;
    }
    if (first == 254u) {
      uint16_t value = 0;
      if (!u16(&value)) {
        return false;
      }
      *out = value;
      return true;
    }
    uint32_t value = 0;
    if (!u32(&value)) {
      return false;
    }
    *out = value;
    return true;
  }
  bool align(size_t alignment) {
    const size_t aligned = (offset_ + alignment - 1u) & ~(alignment - 1u);
    if (aligned > size_) {
      return false;
    }
    offset_ = aligned;
    return true;
  }
  bool done() const { return offset_ == size_; }

 private:
  const uint8_t* data_ = nullptr;
  size_t size_ = 0;
  size_t offset_ = 0;
};

void write_value(Writer* writer, const StandardValue& value);

void write_string_payload(Writer* writer, const std::string& value) {
  writer->size(value.size());
  writer->bytes(reinterpret_cast<const uint8_t*>(value.data()), value.size());
}

void write_value(Writer* writer, const StandardValue& value) {
  const StandardValue::Storage& storage = value.storage();
  if (std::holds_alternative<std::monostate>(storage)) {
    writer->byte(kNull);
  } else if (const bool* b = std::get_if<bool>(&storage)) {
    writer->byte(*b ? kTrue : kFalse);
  } else if (const int64_t* i = std::get_if<int64_t>(&storage)) {
    if (*i >= std::numeric_limits<int32_t>::min() &&
        *i <= std::numeric_limits<int32_t>::max()) {
      writer->byte(kInt32);
      writer->u32(static_cast<uint32_t>(static_cast<int32_t>(*i)));
    } else {
      writer->byte(kInt64);
      writer->u64(static_cast<uint64_t>(*i));
    }
  } else if (const double* d = std::get_if<double>(&storage)) {
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(*d));
    std::memcpy(&bits, d, sizeof(bits));
    writer->byte(kFloat64);
    writer->align(8);
    writer->u64(bits);
  } else if (const std::string* s = std::get_if<std::string>(&storage)) {
    writer->byte(kString);
    write_string_payload(writer, *s);
  } else if (const StandardValue::Bytes* bytes =
                 std::get_if<StandardValue::Bytes>(&storage)) {
    writer->byte(kUint8List);
    writer->size(bytes->size());
    writer->bytes(bytes->data(), bytes->size());
  } else if (const StandardValue::List* list =
                 std::get_if<StandardValue::List>(&storage)) {
    writer->byte(kList);
    writer->size(list->size());
    for (const StandardValue& item : *list) {
      write_value(writer, item);
    }
  } else if (const StandardValue::Map* map =
                 std::get_if<StandardValue::Map>(&storage)) {
    writer->byte(kMap);
    writer->size(map->size());
    for (const auto& entry : *map) {
      write_value(writer, entry.first);
      write_value(writer, entry.second);
    }
  }
}

std::optional<StandardValue> read_value(Reader* reader) {
  uint8_t type = 0;
  if (!reader->byte(&type)) {
    return std::nullopt;
  }
  switch (type) {
    case kNull:
      return StandardValue();
    case kTrue:
      return StandardValue(true);
    case kFalse:
      return StandardValue(false);
    case kInt32: {
      uint32_t value = 0;
      if (!reader->u32(&value)) {
        return std::nullopt;
      }
      return StandardValue(static_cast<int64_t>(static_cast<int32_t>(value)));
    }
    case kInt64: {
      uint64_t value = 0;
      if (!reader->u64(&value)) {
        return std::nullopt;
      }
      return StandardValue(static_cast<int64_t>(value));
    }
    case kLargeInt: {
      size_t size = 0;
      const uint8_t* bytes = nullptr;
      if (!reader->size(&size) || !reader->bytes(size, &bytes)) {
        return std::nullopt;
      }
      return StandardValue(std::string(reinterpret_cast<const char*>(bytes), size));
    }
    case kFloat64: {
      if (!reader->align(8)) {
        return std::nullopt;
      }
      uint64_t bits = 0;
      if (!reader->u64(&bits)) {
        return std::nullopt;
      }
      double value = 0.0;
      std::memcpy(&value, &bits, sizeof(value));
      return StandardValue(value);
    }
    case kString: {
      size_t size = 0;
      const uint8_t* bytes = nullptr;
      if (!reader->size(&size) || !reader->bytes(size, &bytes)) {
        return std::nullopt;
      }
      return StandardValue(std::string(reinterpret_cast<const char*>(bytes), size));
    }
    case kUint8List: {
      size_t size = 0;
      const uint8_t* bytes = nullptr;
      if (!reader->size(&size) || !reader->bytes(size, &bytes)) {
        return std::nullopt;
      }
      return StandardValue(StandardValue::Bytes(bytes, bytes + size));
    }
    case kList: {
      size_t count = 0;
      if (!reader->size(&count)) {
        return std::nullopt;
      }
      StandardValue::List list;
      list.reserve(count);
      for (size_t i = 0; i < count; ++i) {
        std::optional<StandardValue> item = read_value(reader);
        if (!item.has_value()) {
          return std::nullopt;
        }
        list.push_back(std::move(*item));
      }
      return StandardValue(std::move(list));
    }
    case kMap: {
      size_t count = 0;
      if (!reader->size(&count)) {
        return std::nullopt;
      }
      StandardValue::Map map;
      map.reserve(count);
      for (size_t i = 0; i < count; ++i) {
        std::optional<StandardValue> key = read_value(reader);
        std::optional<StandardValue> value = read_value(reader);
        if (!key.has_value() || !value.has_value()) {
          return std::nullopt;
        }
        map.emplace_back(std::move(*key), std::move(*value));
      }
      return StandardValue(std::move(map));
    }
    default:
      return std::nullopt;
  }
}

}  // namespace

std::vector<uint8_t> StandardMessageCodec::encode(const StandardValue& value) {
  Writer writer;
  write_value(&writer, value);
  return writer.take();
}

std::optional<StandardValue> StandardMessageCodec::decode(const uint8_t* data,
                                                          size_t size) {
  Reader reader(data, size);
  std::optional<StandardValue> value = read_value(&reader);
  if (!value.has_value() || !reader.done()) {
    return std::nullopt;
  }
  return value;
}

std::vector<uint8_t> StandardMethodCodec::encode_method_call(
    const MethodCall& call) {
  Writer writer;
  write_value(&writer, StandardValue(call.method));
  write_value(&writer, call.arguments);
  return writer.take();
}

std::optional<MethodCall> StandardMethodCodec::decode_method_call(
    const uint8_t* data,
    size_t size) {
  Reader reader(data, size);
  std::optional<StandardValue> method = read_value(&reader);
  std::optional<StandardValue> arguments = read_value(&reader);
  if (!method.has_value() || !arguments.has_value() || !reader.done()) {
    return std::nullopt;
  }
  const std::string* method_name = method->string();
  if (method_name == nullptr) {
    return std::nullopt;
  }
  return MethodCall{*method_name, std::move(*arguments)};
}

std::vector<uint8_t> StandardMethodCodec::encode_success_envelope(
    const StandardValue& result) {
  Writer writer;
  writer.byte(0);
  write_value(&writer, result);
  return writer.take();
}

std::optional<StandardValue> StandardMethodCodec::decode_success_envelope(
    const uint8_t* data,
    size_t size) {
  Reader reader(data, size);
  uint8_t status = 0;
  if (!reader.byte(&status) || status != 0) {
    return std::nullopt;
  }
  std::optional<StandardValue> value = read_value(&reader);
  if (!value.has_value() || !reader.done()) {
    return std::nullopt;
  }
  return value;
}

std::vector<uint8_t> StandardMethodCodec::encode_error_envelope(
    const MethodError& error) {
  Writer writer;
  writer.byte(1);
  write_value(&writer, StandardValue(error.code));
  write_value(&writer, StandardValue(error.message));
  write_value(&writer, error.details);
  return writer.take();
}

StandardValue make_map(
    std::initializer_list<std::pair<StandardValue, StandardValue>> entries) {
  return StandardValue(StandardValue::Map(entries));
}

}  // namespace pluto
