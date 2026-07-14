#include "channels/standard_codec.h"

#include "gtest/gtest.h"

namespace {

TEST(StandardCodec, RoundTripsNestedValues) {
  pluto::StandardValue value = pluto::make_map({
      {"name", "pluto"},
      {"debug", true},
      {"count", static_cast<int64_t>(42)},
      {"bytes", pluto::StandardValue::Bytes{1, 2, 3, 4}},
      {"items", pluto::StandardValue::List{"a", "b"}},
  });

  const std::vector<uint8_t> bytes =
      pluto::StandardMessageCodec::encode(value);
  std::optional<pluto::StandardValue> decoded =
      pluto::StandardMessageCodec::decode(bytes.data(), bytes.size());

  ASSERT_TRUE(decoded.has_value());
  EXPECT_TRUE(*decoded == value);
}

TEST(StandardMethodCodec, EncodesMethodCallsAndErrorEnvelopes) {
  pluto::MethodCall call{"setOrientation", int64_t{90}};
  const std::vector<uint8_t> bytes =
      pluto::StandardMethodCodec::encode_method_call(call);
  std::optional<pluto::MethodCall> decoded =
      pluto::StandardMethodCodec::decode_method_call(bytes.data(), bytes.size());

  ASSERT_TRUE(decoded.has_value());
  EXPECT_EQ(decoded->method, "setOrientation");
  ASSERT_TRUE(decoded->arguments.integer() != nullptr);
  EXPECT_EQ(*decoded->arguments.integer(), 90);

  const std::vector<uint8_t> error =
      pluto::StandardMethodCodec::encode_error_envelope(
          pluto::MethodError{"unimplemented", "not ready", {}});
  ASSERT_TRUE(!error.empty());
  EXPECT_EQ(error[0], 1);
}

TEST(StandardMethodCodec, DecodesSuccessEnvelopeWithAlignedDouble) {
  const pluto::StandardValue value = pluto::make_map({
      {"ssid", "HomeNet"},
      {"signal", 0.82},
  });
  const std::vector<uint8_t> envelope =
      pluto::StandardMethodCodec::encode_success_envelope(value);
  const std::optional<pluto::StandardValue> decoded =
      pluto::StandardMethodCodec::decode_success_envelope(
          envelope.data(), envelope.size());

  ASSERT_TRUE(decoded.has_value());
  EXPECT_TRUE(*decoded == value);
}

}  // namespace
