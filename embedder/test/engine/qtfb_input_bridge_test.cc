#include "engine/qtfb_input_bridge.h"

#include <cstddef>
#include <string>

#include "gtest/gtest.h"

namespace {

using pluto::QtfbInputPolicy;
using pluto::QtfbInputTranslator;
using pluto::QtfbKeyBatch;
using pluto::QtfbKeyTranslator;
using pluto::QtfbPointerBatch;
using pluto::qtfb::UserInputContents;

UserInputContents input(int type, int device, int x, int y, int detail = 0) {
  return UserInputContents{type, device, x, y, detail};
}

void expect_event(const FlutterPointerEvent& event, FlutterPointerPhase phase,
                  FlutterPointerDeviceKind kind, int32_t device,
                  std::size_t timestamp_us, double x, double y,
                  double pressure) {
  EXPECT_EQ(event.struct_size, sizeof(FlutterPointerEvent));
  EXPECT_EQ(event.phase, phase);
  EXPECT_EQ(event.device_kind, kind);
  EXPECT_EQ(event.device, device);
  EXPECT_EQ(event.timestamp, timestamp_us);
  EXPECT_EQ(event.x, x);
  EXPECT_EQ(event.y, y);
  EXPECT_EQ(event.pressure, pressure);
  EXPECT_EQ(event.pressure_min, 0.0);
  EXPECT_EQ(event.pressure_max, 1.0);
}

void expect_key(const pluto::QtfbKeyEvent& event, FlutterKeyEventType type,
                std::size_t timestamp_us, std::uint64_t physical,
                std::uint64_t logical, const char* character,
                FlutterKeyEventDeviceType device_type,
                bool synthesized = false) {
  EXPECT_EQ(event.type, type);
  EXPECT_EQ(event.timestamp, static_cast<double>(timestamp_us));
  EXPECT_EQ(event.physical, physical);
  EXPECT_EQ(event.logical, logical);
  EXPECT_EQ(event.has_character, character != nullptr);
  if (character != nullptr) {
    EXPECT_EQ(std::string(event.character.data()), std::string(character));
  }
  EXPECT_EQ(event.device_type, device_type);
  EXPECT_EQ(event.synthesized, synthesized);

  const FlutterKeyEvent flutter = event.flutter_event();
  EXPECT_EQ(flutter.struct_size, sizeof(FlutterKeyEvent));
  EXPECT_EQ(flutter.type, type);
  EXPECT_EQ(flutter.timestamp, static_cast<double>(timestamp_us));
  EXPECT_EQ(flutter.physical, physical);
  EXPECT_EQ(flutter.logical, logical);
  if (character == nullptr) {
    EXPECT_TRUE(flutter.character == nullptr);
  } else {
    EXPECT_EQ(std::string(flutter.character), std::string(character));
  }
  EXPECT_EQ(flutter.device_type, device_type);
  EXPECT_EQ(flutter.synthesized, synthesized);
}

TEST(QtfbInputSelection, MissingCooperativeKeyCanNeverFallBackToEvdev) {
  EXPECT_EQ(
      static_cast<int>(pluto::qtfb_input_policy("qtfb", "7171298", true, true)),
      static_cast<int>(QtfbInputPolicy::kCooperative));
  EXPECT_EQ(static_cast<int>(
                pluto::qtfb_input_policy("qtfb", "7171298", false, true)),
            static_cast<int>(QtfbInputPolicy::kCooperative));
  // A keyed display-only app still reads AppLoad keyboard/button packets.
  EXPECT_EQ(static_cast<int>(
                pluto::qtfb_input_policy("qtfb", "7171298", false, false)),
            static_cast<int>(QtfbInputPolicy::kCooperative));

  EXPECT_EQ(
      static_cast<int>(pluto::qtfb_input_policy("qtfb", nullptr, true, true)),
      static_cast<int>(QtfbInputPolicy::kRejectMissingKey));
  EXPECT_EQ(static_cast<int>(pluto::qtfb_input_policy("qtfb", "", false, true)),
            static_cast<int>(QtfbInputPolicy::kRejectMissingKey));
  EXPECT_EQ(
      static_cast<int>(pluto::qtfb_input_policy("qtfb", nullptr, false, false)),
      static_cast<int>(QtfbInputPolicy::kDisabled));
  EXPECT_EQ(static_cast<int>(
                pluto::qtfb_input_policy("swtcon", "7171298", true, true)),
            static_cast<int>(QtfbInputPolicy::kUseEvdev));
}

TEST(QtfbInputTranslator, TouchLifecyclePreservesMultitouchIdentity) {
  QtfbInputTranslator translator(true, false);

  QtfbPointerBatch first = translator.consume(
      input(pluto::qtfb::kInputTouchPress, 7, 120, 230), 1000);
  ASSERT_EQ(first.event_count, 2u);
  EXPECT_TRUE(first.touch_active);
  EXPECT_FALSE(first.pen_active);
  expect_event(first.events[0], kAdd, kFlutterPointerDeviceKindTouch, 100, 1000,
               120.0, 230.0, 0.0);
  expect_event(first.events[1], kDown, kFlutterPointerDeviceKindTouch, 100,
               1000, 120.0, 230.0, 1.0);

  QtfbPointerBatch second = translator.consume(
      input(pluto::qtfb::kInputTouchPress, 42, 800, 900), 1010);
  ASSERT_EQ(second.event_count, 2u);
  EXPECT_TRUE(second.touch_active);
  expect_event(second.events[0], kAdd, kFlutterPointerDeviceKindTouch, 101,
               1010, 800.0, 900.0, 0.0);
  expect_event(second.events[1], kDown, kFlutterPointerDeviceKindTouch, 101,
               1010, 800.0, 900.0, 1.0);

  // AppLoad labels stationary points as PRESS while another contact changes.
  // That must not restart an already-active Flutter pointer lifecycle.
  QtfbPointerBatch repeated = translator.consume(
      input(pluto::qtfb::kInputTouchPress, 7, 120, 230), 1015);
  ASSERT_EQ(repeated.event_count, 1u);
  expect_event(repeated.events[0], kMove, kFlutterPointerDeviceKindTouch, 100,
               1015, 120.0, 230.0, 1.0);

  QtfbPointerBatch move = translator.consume(
      input(pluto::qtfb::kInputTouchUpdate, 7, 130, 250), 1020);
  ASSERT_EQ(move.event_count, 1u);
  EXPECT_TRUE(move.touch_active);
  expect_event(move.events[0], kMove, kFlutterPointerDeviceKindTouch, 100, 1020,
               130.0, 250.0, 1.0);

  QtfbPointerBatch release_first = translator.consume(
      input(pluto::qtfb::kInputTouchRelease, 7, 135, 255), 1030);
  ASSERT_EQ(release_first.event_count, 2u);
  EXPECT_TRUE(release_first.touch_active);
  expect_event(release_first.events[0], kUp, kFlutterPointerDeviceKindTouch,
               100, 1030, 135.0, 255.0, 0.0);
  expect_event(release_first.events[1], kRemove, kFlutterPointerDeviceKindTouch,
               100, 1030, 135.0, 255.0, 0.0);

  QtfbPointerBatch release_second = translator.consume(
      input(pluto::qtfb::kInputTouchRelease, 42, 810, 910), 1040);
  ASSERT_EQ(release_second.event_count, 2u);
  EXPECT_FALSE(release_second.touch_active);

  // Reusing an AppLoad devId reuses its Flutter device identity.
  QtfbPointerBatch reused =
      translator.consume(input(pluto::qtfb::kInputTouchPress, 7, 10, 20), 1050);
  ASSERT_EQ(reused.event_count, 2u);
  EXPECT_EQ(reused.events[0].device, 100);
}

TEST(QtfbInputTranslator, PenUsesStylusPhasesAndPercentPressure) {
  QtfbInputTranslator translator(false, true);

  QtfbPointerBatch down = translator.consume(
      input(pluto::qtfb::kInputPenPress, 3, 400, 500, 25), 2000);
  ASSERT_EQ(down.event_count, 2u);
  EXPECT_FALSE(down.touch_active);
  EXPECT_TRUE(down.pen_active);
  expect_event(down.events[0], kAdd, kFlutterPointerDeviceKindStylus, 500, 2000,
               400.0, 500.0, 0.0);
  expect_event(down.events[1], kDown, kFlutterPointerDeviceKindStylus, 500,
               2000, 400.0, 500.0, 0.25);

  QtfbPointerBatch move = translator.consume(
      input(pluto::qtfb::kInputPenUpdate, 3, 405, 510, 125), 2010);
  ASSERT_EQ(move.event_count, 1u);
  expect_event(move.events[0], kMove, kFlutterPointerDeviceKindStylus, 500,
               2010, 405.0, 510.0, 1.0);

  QtfbPointerBatch up = translator.consume(
      input(pluto::qtfb::kInputPenRelease, 3, 410, 515, 0), 2020);
  ASSERT_EQ(up.event_count, 2u);
  EXPECT_FALSE(up.pen_active);
  expect_event(up.events[0], kUp, kFlutterPointerDeviceKindStylus, 500, 2020,
               410.0, 515.0, 0.0);
  expect_event(up.events[1], kRemove, kFlutterPointerDeviceKindStylus, 500,
               2020, 410.0, 515.0, 0.0);
}

TEST(QtfbInputTranslator, ShutdownCancelsEveryActivePointer) {
  QtfbInputTranslator translator(true, true);
  translator.consume(input(pluto::qtfb::kInputTouchPress, 1, 20, 30), 10);
  translator.consume(input(pluto::qtfb::kInputTouchPress, 2, 40, 50), 11);
  translator.consume(input(pluto::qtfb::kInputPenPress, 4, 60, 70, 50), 12);

  QtfbPointerBatch cancelled = translator.cancel_all(99);
  ASSERT_EQ(cancelled.event_count, 6u);
  EXPECT_FALSE(cancelled.touch_active);
  EXPECT_FALSE(cancelled.pen_active);
  for (std::size_t i = 0; i < cancelled.event_count; i += 2) {
    EXPECT_EQ(cancelled.events[i].phase, kCancel);
    EXPECT_EQ(cancelled.events[i + 1].phase, kRemove);
    EXPECT_EQ(cancelled.events[i].device, cancelled.events[i + 1].device);
    EXPECT_EQ(cancelled.events[i].timestamp, 99u);
  }
}

TEST(QtfbInputTranslator, RecyclesFlutterSlotsAcrossTrackingIds) {
  QtfbInputTranslator translator(true, false);
  for (int tracking_id = 0; tracking_id < 1000; ++tracking_id) {
    const QtfbPointerBatch down = translator.consume(
        input(pluto::qtfb::kInputTouchPress, tracking_id, 1, 2),
        static_cast<std::size_t>(tracking_id * 2));
    ASSERT_EQ(down.event_count, 2u);
    EXPECT_EQ(down.events[0].device, 100);
    const QtfbPointerBatch up = translator.consume(
        input(pluto::qtfb::kInputTouchRelease, tracking_id, 1, 2),
        static_cast<std::size_t>(tracking_id * 2 + 1));
    ASSERT_EQ(up.event_count, 2u);
    EXPECT_FALSE(up.touch_active);
  }
}

TEST(QtfbInputTranslator, DisabledOrOutOfSequenceInputsAreIgnored) {
  QtfbInputTranslator touch_only(true, false);
  EXPECT_TRUE(
      touch_only.consume(input(pluto::qtfb::kInputPenPress, 1, 2, 3, 50), 1)
          .event_count == 0);
  EXPECT_TRUE(
      touch_only.consume(input(pluto::qtfb::kInputTouchUpdate, 8, 2, 3), 2)
          .event_count == 0);
  EXPECT_TRUE(
      touch_only.consume(input(pluto::qtfb::kInputTouchRelease, 8, 2, 3), 3)
          .event_count == 0);
}

TEST(QtfbKeyTranslator, VirtualKeyboardUsesFlutterPhysicalLogicalAndCharacter) {
  QtfbKeyTranslator translator;

  QtfbKeyBatch down = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardPress, 0, 'Q', 0), 3000);
  ASSERT_EQ(down.event_count, 1u);
  expect_key(down.events[0], kFlutterKeyEventTypeDown, 3000, 0x00070014,
             0x00000071, "q", kFlutterKeyEventDeviceTypeKeyboard);

  QtfbKeyBatch repeat = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardPress, 0, 'Q', 0), 3010);
  ASSERT_EQ(repeat.event_count, 1u);
  expect_key(repeat.events[0], kFlutterKeyEventTypeRepeat, 3010, 0x00070014,
             0x00000071, "q", kFlutterKeyEventDeviceTypeKeyboard);

  QtfbKeyBatch up = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardRelease, 0, 'Q', 0), 3020);
  ASSERT_EQ(up.event_count, 1u);
  expect_key(up.events[0], kFlutterKeyEventTypeUp, 3020, 0x00070014, 0x00000071,
             nullptr, kFlutterKeyEventDeviceTypeKeyboard);

  EXPECT_EQ(
      translator
          .consume(input(pluto::qtfb::kInputVirtualKeyboardRelease, 0, 'Q', 0),
                   3030)
          .event_count,
      0u);
}

TEST(QtfbKeyTranslator, ShiftAndPrintableKeyHaveRegularIndependentLifecycles) {
  constexpr int kShift = 0x100000;
  QtfbKeyTranslator translator;

  QtfbKeyBatch shift_down = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardPress, 0, kShift, 0), 4000);
  ASSERT_EQ(shift_down.event_count, 1u);
  expect_key(shift_down.events[0], kFlutterKeyEventTypeDown, 4000, 0x000700e1,
             0x00200000102, nullptr, kFlutterKeyEventDeviceTypeKeyboard);

  QtfbKeyBatch letter_down = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardPress, 0, kShift | 'Q', 0), 4010);
  ASSERT_EQ(letter_down.event_count, 1u);
  expect_key(letter_down.events[0], kFlutterKeyEventTypeDown, 4010, 0x00070014,
             0x00000071, "Q", kFlutterKeyEventDeviceTypeKeyboard);

  QtfbKeyBatch letter_up = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardRelease, 0, kShift | 'Q', 0),
      4020);
  ASSERT_EQ(letter_up.event_count, 1u);
  expect_key(letter_up.events[0], kFlutterKeyEventTypeUp, 4020, 0x00070014,
             0x00000071, nullptr, kFlutterKeyEventDeviceTypeKeyboard);

  QtfbKeyBatch shift_up = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardRelease, 0, kShift, 0), 4030);
  ASSERT_EQ(shift_up.event_count, 1u);
  expect_key(shift_up.events[0], kFlutterKeyEventTypeUp, 4030, 0x000700e1,
             0x00200000102, nullptr, kFlutterKeyEventDeviceTypeKeyboard);
}

TEST(QtfbKeyTranslator, StickyModifierBitsIdentifyTheNewModifier) {
  constexpr int kShift = 0x100000;
  constexpr int kControl = 0x200000;
  QtfbKeyTranslator translator;
  translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardPress, 0, kShift, 0), 4500);

  const QtfbKeyBatch control_down = translator.consume(
      input(pluto::qtfb::kInputVirtualKeyboardPress, 0, kShift | kControl, 0),
      4510);
  ASSERT_EQ(control_down.event_count, 1u);
  expect_key(control_down.events[0], kFlutterKeyEventTypeDown, 4510, 0x000700e0,
             0x00200000100, nullptr, kFlutterKeyEventDeviceTypeKeyboard);

  EXPECT_EQ(translator
                .consume(input(pluto::qtfb::kInputVirtualKeyboardRelease, 0,
                               kControl, 0),
                         4520)
                .event_count,
            1u);
  EXPECT_EQ(translator
                .consume(input(pluto::qtfb::kInputVirtualKeyboardRelease, 0,
                               kShift, 0),
                         4530)
                .event_count,
            1u);
}

TEST(QtfbKeyTranslator, AppLoadDefaultBackspaceAndNavigationCodesAreMapped) {
  QtfbKeyTranslator translator;
  struct Case {
    int code;
    std::uint64_t physical;
    std::uint64_t logical;
  };
  const Case cases[] = {
      {128, 0x0007002a, 0x00100000008}, {129, 0x0007004b, 0x00100000308},
      {130, 0x0007004e, 0x00100000307}, {131, 0x00070051, 0x00100000301},
      {132, 0x00070052, 0x00100000304}, {133, 0x00070050, 0x00100000302},
      {134, 0x0007004f, 0x00100000303}, {135, 0x0007004a, 0x00100000306},
      {136, 0x0007004d, 0x00100000305},
  };
  std::size_t timestamp = 5000;
  for (const Case& entry : cases) {
    const QtfbKeyBatch down = translator.consume(
        input(pluto::qtfb::kInputVirtualKeyboardPress, 0, entry.code, 0),
        timestamp);
    ASSERT_EQ(down.event_count, 1u);
    expect_key(down.events[0], kFlutterKeyEventTypeDown, timestamp,
               entry.physical, entry.logical, nullptr,
               kFlutterKeyEventDeviceTypeKeyboard);
    ++timestamp;
    const QtfbKeyBatch up = translator.consume(
        input(pluto::qtfb::kInputVirtualKeyboardRelease, 0, entry.code, 0),
        timestamp);
    ASSERT_EQ(up.event_count, 1u);
    expect_key(up.events[0], kFlutterKeyEventTypeUp, timestamp, entry.physical,
               entry.logical, nullptr, kFlutterKeyEventDeviceTypeKeyboard);
    ++timestamp;
  }
}

TEST(QtfbKeyTranslator, TabletButtonsUseDirectionalPadKeyEvents) {
  QtfbKeyTranslator translator;
  const QtfbKeyBatch left =
      translator.consume(input(pluto::qtfb::kInputButtonPress, 0, 0, 0), 6000);
  ASSERT_EQ(left.event_count, 1u);
  expect_key(left.events[0], kFlutterKeyEventTypeDown, 6000, 0x00070050,
             0x00100000302, nullptr, kFlutterKeyEventDeviceTypeDirectionalPad);
  const QtfbKeyBatch left_up = translator.consume(
      input(pluto::qtfb::kInputButtonRelease, 0, 0, 0), 6010);
  ASSERT_EQ(left_up.event_count, 1u);
  expect_key(left_up.events[0], kFlutterKeyEventTypeUp, 6010, 0x00070050,
             0x00100000302, nullptr, kFlutterKeyEventDeviceTypeDirectionalPad);

  EXPECT_EQ(
      translator.consume(input(pluto::qtfb::kInputButtonPress, 0, 9, 0), 6020)
          .event_count,
      0u);
}

TEST(QtfbKeyTranslator, ShutdownSynthesizesReleaseForEveryPressedKey) {
  QtfbKeyTranslator translator;
  translator.consume(input(pluto::qtfb::kInputVirtualKeyboardPress, 0, 'A', 0),
                     7000);
  translator.consume(input(pluto::qtfb::kInputButtonPress, 0, 2, 0), 7010);

  const QtfbKeyBatch cancelled = translator.cancel_all(7020);
  ASSERT_EQ(cancelled.event_count, 2u);
  for (std::size_t index = 0; index < cancelled.event_count; ++index) {
    EXPECT_EQ(cancelled.events[index].type, kFlutterKeyEventTypeUp);
    EXPECT_EQ(cancelled.events[index].timestamp, 7020.0);
    EXPECT_FALSE(cancelled.events[index].has_character);
    EXPECT_TRUE(cancelled.events[index].synthesized);
  }
  EXPECT_EQ(translator.cancel_all(7030).event_count, 0u);
}

}  // namespace
