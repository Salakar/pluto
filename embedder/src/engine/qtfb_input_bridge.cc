#include "engine/qtfb_input_bridge.h"

#include <algorithm>
#include <cctype>

namespace pluto {
namespace {

constexpr int32_t kNoDevice = -1;

constexpr std::uint64_t kVirtualKeySource = std::uint64_t{1} << 62;
constexpr std::uint64_t kTabletButtonSource = std::uint64_t{2} << 62;

constexpr int kVkbShiftModifier = 0x100000;
constexpr int kVkbControlModifier = 0x200000;
constexpr int kVkbAltModifier = 0x400000;
constexpr int kVkbModifierMask =
    kVkbShiftModifier | kVkbControlModifier | kVkbAltModifier;

constexpr std::uint64_t kPhysicalKeyA = 0x00070004;
constexpr std::uint64_t kPhysicalDigit1 = 0x0007001e;
constexpr std::uint64_t kPhysicalDigit0 = 0x00070027;
constexpr std::uint64_t kPhysicalEnter = 0x00070028;
constexpr std::uint64_t kPhysicalEscape = 0x00070029;
constexpr std::uint64_t kPhysicalBackspace = 0x0007002a;
constexpr std::uint64_t kPhysicalTab = 0x0007002b;
constexpr std::uint64_t kPhysicalSpace = 0x0007002c;
constexpr std::uint64_t kPhysicalMinus = 0x0007002d;
constexpr std::uint64_t kPhysicalEqual = 0x0007002e;
constexpr std::uint64_t kPhysicalBracketLeft = 0x0007002f;
constexpr std::uint64_t kPhysicalBracketRight = 0x00070030;
constexpr std::uint64_t kPhysicalBackslash = 0x00070031;
constexpr std::uint64_t kPhysicalSemicolon = 0x00070033;
constexpr std::uint64_t kPhysicalQuote = 0x00070034;
constexpr std::uint64_t kPhysicalBackquote = 0x00070035;
constexpr std::uint64_t kPhysicalComma = 0x00070036;
constexpr std::uint64_t kPhysicalPeriod = 0x00070037;
constexpr std::uint64_t kPhysicalSlash = 0x00070038;
constexpr std::uint64_t kPhysicalHome = 0x0007004a;
constexpr std::uint64_t kPhysicalPageUp = 0x0007004b;
constexpr std::uint64_t kPhysicalDelete = 0x0007004c;
constexpr std::uint64_t kPhysicalEnd = 0x0007004d;
constexpr std::uint64_t kPhysicalPageDown = 0x0007004e;
constexpr std::uint64_t kPhysicalArrowRight = 0x0007004f;
constexpr std::uint64_t kPhysicalArrowLeft = 0x00070050;
constexpr std::uint64_t kPhysicalArrowDown = 0x00070051;
constexpr std::uint64_t kPhysicalArrowUp = 0x00070052;
constexpr std::uint64_t kPhysicalControlLeft = 0x000700e0;
constexpr std::uint64_t kPhysicalShiftLeft = 0x000700e1;
constexpr std::uint64_t kPhysicalAltLeft = 0x000700e2;

constexpr std::uint64_t kLogicalBackspace = 0x00100000008;
constexpr std::uint64_t kLogicalTab = 0x00100000009;
constexpr std::uint64_t kLogicalEnter = 0x0010000000d;
constexpr std::uint64_t kLogicalEscape = 0x0010000001b;
constexpr std::uint64_t kLogicalDelete = 0x0010000007f;
constexpr std::uint64_t kLogicalArrowDown = 0x00100000301;
constexpr std::uint64_t kLogicalArrowLeft = 0x00100000302;
constexpr std::uint64_t kLogicalArrowRight = 0x00100000303;
constexpr std::uint64_t kLogicalArrowUp = 0x00100000304;
constexpr std::uint64_t kLogicalEnd = 0x00100000305;
constexpr std::uint64_t kLogicalHome = 0x00100000306;
constexpr std::uint64_t kLogicalPageDown = 0x00100000307;
constexpr std::uint64_t kLogicalPageUp = 0x00100000308;
constexpr std::uint64_t kLogicalControlLeft = 0x00200000100;
constexpr std::uint64_t kLogicalShiftLeft = 0x00200000102;
constexpr std::uint64_t kLogicalAltLeft = 0x00200000104;

struct KeyMapping {
  std::uint64_t source = 0;
  std::uint64_t physical = 0;
  std::uint64_t logical = 0;
  char character = '\0';
  bool has_character = false;
  FlutterKeyEventDeviceType device_type = kFlutterKeyEventDeviceTypeKeyboard;
};

std::uint64_t printable_physical_key(unsigned char code) {
  const unsigned char lower =
      static_cast<unsigned char>(std::tolower(static_cast<int>(code)));
  if (lower >= 'a' && lower <= 'z') {
    return kPhysicalKeyA + (lower - 'a');
  }
  if (code >= '1' && code <= '9') {
    return kPhysicalDigit1 + (code - '1');
  }
  switch (code) {
    case '0':
      return kPhysicalDigit0;
    case '!':
      return kPhysicalDigit1;
    case '@':
      return kPhysicalDigit1 + 1;
    case '#':
      return kPhysicalDigit1 + 2;
    case '$':
      return kPhysicalDigit1 + 3;
    case '%':
      return kPhysicalDigit1 + 4;
    case '^':
      return kPhysicalDigit1 + 5;
    case '&':
      return kPhysicalDigit1 + 6;
    case '*':
      return kPhysicalDigit1 + 7;
    case '(':
      return kPhysicalDigit1 + 8;
    case ')':
      return kPhysicalDigit0;
    case ' ':
      return kPhysicalSpace;
    case '-':
    case '_':
      return kPhysicalMinus;
    case '=':
    case '+':
      return kPhysicalEqual;
    case '[':
    case '{':
      return kPhysicalBracketLeft;
    case ']':
    case '}':
      return kPhysicalBracketRight;
    case '\\':
    case '|':
      return kPhysicalBackslash;
    case ';':
    case ':':
      return kPhysicalSemicolon;
    case '\'':
    case '"':
      return kPhysicalQuote;
    case '`':
    case '~':
      return kPhysicalBackquote;
    case ',':
    case '<':
      return kPhysicalComma;
    case '.':
    case '>':
      return kPhysicalPeriod;
    case '/':
    case '?':
      return kPhysicalSlash;
    default:
      return 0;
  }
}

bool map_virtual_key(int raw_code, KeyMapping* mapping) {
  if (mapping == nullptr || raw_code < 0) {
    return false;
  }
  mapping->source = kVirtualKeySource;
  mapping->device_type = kFlutterKeyEventDeviceTypeKeyboard;

  switch (raw_code) {
    case kVkbShiftModifier:
      mapping->source |= kVkbShiftModifier;
      mapping->physical = kPhysicalShiftLeft;
      mapping->logical = kLogicalShiftLeft;
      return true;
    case kVkbControlModifier:
      mapping->source |= kVkbControlModifier;
      mapping->physical = kPhysicalControlLeft;
      mapping->logical = kLogicalControlLeft;
      return true;
    case kVkbAltModifier:
      mapping->source |= kVkbAltModifier;
      mapping->physical = kPhysicalAltLeft;
      mapping->logical = kLogicalAltLeft;
      return true;
    default:
      break;
  }

  if ((raw_code & ~(kVkbModifierMask | 0xff)) != 0) {
    return false;
  }
  const unsigned char code = static_cast<unsigned char>(raw_code & 0xff);
  mapping->source |= code;

  switch (code) {
    case 8:
      mapping->physical = kPhysicalBackspace;
      mapping->logical = kLogicalBackspace;
      return true;
    case 9:
      mapping->physical = kPhysicalTab;
      mapping->logical = kLogicalTab;
      return true;
    case 13:
      mapping->physical = kPhysicalEnter;
      mapping->logical = kLogicalEnter;
      return true;
    case 27:
      mapping->physical = kPhysicalEscape;
      mapping->logical = kLogicalEscape;
      return true;
    case 127:
      mapping->physical = kPhysicalDelete;
      mapping->logical = kLogicalDelete;
      return true;
    // AppLoad's shipped default.layout.json uses this contiguous sequence.
    // It is offset from the stale symbolic values in qtfb/common.h; following
    // the actual wire producer makes its visible Backspace/navigation keys
    // behave as labelled.
    case 128:
      mapping->physical = kPhysicalBackspace;
      mapping->logical = kLogicalBackspace;
      return true;
    case 129:
      mapping->physical = kPhysicalPageUp;
      mapping->logical = kLogicalPageUp;
      return true;
    case 130:
      mapping->physical = kPhysicalPageDown;
      mapping->logical = kLogicalPageDown;
      return true;
    case 131:
      mapping->physical = kPhysicalArrowDown;
      mapping->logical = kLogicalArrowDown;
      return true;
    case 132:
      mapping->physical = kPhysicalArrowUp;
      mapping->logical = kLogicalArrowUp;
      return true;
    case 133:
      mapping->physical = kPhysicalArrowLeft;
      mapping->logical = kLogicalArrowLeft;
      return true;
    case 134:
      mapping->physical = kPhysicalArrowRight;
      mapping->logical = kLogicalArrowRight;
      return true;
    case 135:
      mapping->physical = kPhysicalHome;
      mapping->logical = kLogicalHome;
      return true;
    case 136:
      mapping->physical = kPhysicalEnd;
      mapping->logical = kLogicalEnd;
      return true;
    default:
      break;
  }

  if (code < 0x20 || code > 0x7e) {
    return false;
  }
  mapping->physical = printable_physical_key(code);
  if (mapping->physical == 0) {
    return false;
  }
  const bool letter =
      (code >= 'a' && code <= 'z') || (code >= 'A' && code <= 'Z');
  const unsigned char lower =
      letter ? static_cast<unsigned char>(std::tolower(static_cast<int>(code)))
             : code;
  mapping->logical = lower;
  mapping->character =
      letter && (raw_code & kVkbShiftModifier) != 0
          ? static_cast<char>(std::toupper(static_cast<int>(lower)))
          : static_cast<char>(lower);
  mapping->has_character = true;
  return true;
}

bool map_tablet_button(int code, KeyMapping* mapping) {
  if (mapping == nullptr) {
    return false;
  }
  mapping->source = kTabletButtonSource | static_cast<std::uint32_t>(code);
  mapping->device_type = kFlutterKeyEventDeviceTypeDirectionalPad;
  switch (code) {
    case 0:
      mapping->physical = kPhysicalArrowLeft;
      mapping->logical = kLogicalArrowLeft;
      return true;
    case 1:
      mapping->physical = kPhysicalHome;
      mapping->logical = kLogicalHome;
      return true;
    case 2:
      mapping->physical = kPhysicalArrowRight;
      mapping->logical = kLogicalArrowRight;
      return true;
    default:
      return false;
  }
}

void append_key_event(QtfbKeyBatch* batch, FlutterKeyEventType type,
                      std::size_t timestamp_us, const KeyMapping& mapping,
                      bool include_character, bool synthesized) {
  if (batch == nullptr || batch->event_count >= batch->events.size()) {
    return;
  }
  QtfbKeyEvent& event = batch->events[batch->event_count++];
  event.type = type;
  event.timestamp = static_cast<double>(timestamp_us);
  event.physical = mapping.physical;
  event.logical = mapping.logical;
  event.has_character = include_character && mapping.has_character;
  event.character[0] = '\0';
  if (event.has_character) {
    event.character[0] = mapping.character;
    event.character[1] = '\0';
  }
  event.synthesized = synthesized;
  event.device_type = mapping.device_type;
}

}  // namespace

QtfbInputPolicy qtfb_input_policy(std::string_view presenter_name,
                                  const char* qtfb_key, bool touch_enabled,
                                  bool pen_enabled) {
  if (presenter_name != "qtfb") {
    return QtfbInputPolicy::kUseEvdev;
  }
  if (qtfb_key != nullptr && *qtfb_key != '\0') {
    // Keep the reader alive even for pointer-disabled apps: tablet buttons and
    // AppLoad's virtual keyboard use the same qtfb input stream.
    return QtfbInputPolicy::kCooperative;
  }
  return touch_enabled || pen_enabled ? QtfbInputPolicy::kRejectMissingKey
                                      : QtfbInputPolicy::kDisabled;
}

QtfbInputTranslator::QtfbInputTranslator(bool touch_enabled, bool pen_enabled)
    : touch_enabled_(touch_enabled), pen_enabled_(pen_enabled) {}

int32_t QtfbInputTranslator::touch_device_for(int source_device) {
  const auto existing = active_touches_.find(source_device);
  if (existing != active_touches_.end()) {
    return existing->second.flutter_device;
  }
  // QEventPoint ids may be kernel tracking ids rather than reusable slots.
  // Keep only active ids and assign the first free Flutter touch device.
  for (int32_t candidate = 100; candidate < 132; ++candidate) {
    const bool used =
        std::any_of(active_touches_.begin(), active_touches_.end(),
                    [candidate](const auto& entry) {
                      return entry.second.flutter_device == candidate;
                    });
    if (!used) {
      return candidate;
    }
  }
  return kNoDevice;
}

int32_t QtfbInputTranslator::pen_device_for(int source_device) {
  const auto existing = active_pens_.find(source_device);
  if (existing != active_pens_.end()) {
    return existing->second.flutter_device;
  }
  for (int32_t candidate = 500; candidate < 504; ++candidate) {
    const bool used =
        std::any_of(active_pens_.begin(), active_pens_.end(),
                    [candidate](const auto& entry) {
                      return entry.second.flutter_device == candidate;
                    });
    if (!used) {
      return candidate;
    }
  }
  return kNoDevice;
}

FlutterPointerEvent QtfbInputTranslator::pointer_event(
    FlutterPointerPhase phase, std::size_t timestamp_us, const Contact& contact,
    FlutterPointerDeviceKind kind, double pressure) {
  FlutterPointerEvent event{};
  event.struct_size = sizeof(event);
  event.phase = phase;
  event.timestamp = timestamp_us;
  event.x = contact.x;
  event.y = contact.y;
  event.device = contact.flutter_device;
  event.signal_kind = kFlutterPointerSignalKindNone;
  event.device_kind = kind;
  event.view_id = 0;
  event.pressure = pressure;
  event.pressure_min = 0.0;
  event.pressure_max = 1.0;
  return event;
}

void QtfbInputTranslator::append_terminal_events(
    QtfbPointerBatch* batch, std::size_t timestamp_us, const Contact& contact,
    FlutterPointerDeviceKind kind, FlutterPointerPhase first_phase) {
  append_event(batch,
               pointer_event(first_phase, timestamp_us, contact, kind, 0.0));
  append_event(batch, pointer_event(kRemove, timestamp_us, contact, kind, 0.0));
}

void QtfbInputTranslator::append_event(QtfbPointerBatch* batch,
                                       const FlutterPointerEvent& event) {
  if (batch != nullptr && batch->event_count < batch->events.size()) {
    batch->events[batch->event_count++] = event;
  }
}

void QtfbInputTranslator::finish(QtfbPointerBatch* batch) const {
  if (batch != nullptr) {
    batch->touch_active = !active_touches_.empty();
    batch->pen_active = !active_pens_.empty();
  }
}

QtfbPointerBatch QtfbInputTranslator::consume(
    const qtfb::UserInputContents& input, std::size_t timestamp_us) {
  QtfbPointerBatch batch;
  const double x = static_cast<double>(input.x);
  const double y = static_cast<double>(input.y);

  if (touch_enabled_ && input.inputType == qtfb::kInputTouchPress) {
    const int32_t device = touch_device_for(input.devId);
    if (device == kNoDevice) {
      finish(&batch);
      return batch;
    }
    auto active = active_touches_.find(input.devId);
    if (active != active_touches_.end()) {
      // AppLoad 0.5.3 initializes each QEventPoint packet as PRESS, including
      // stationary points that fall through its state switch. Preserve the
      // existing Flutter contact instead of tearing multitouch down.
      active->second.x = x;
      active->second.y = y;
      append_event(&batch, pointer_event(kMove, timestamp_us, active->second,
                                         kFlutterPointerDeviceKindTouch, 1.0));
      finish(&batch);
      return batch;
    }
    const Contact contact{device, x, y, 1.0};
    active_touches_[input.devId] = contact;
    append_event(&batch, pointer_event(kAdd, timestamp_us, contact,
                                       kFlutterPointerDeviceKindTouch, 0.0));
    append_event(&batch, pointer_event(kDown, timestamp_us, contact,
                                       kFlutterPointerDeviceKindTouch, 1.0));
  } else if (touch_enabled_ && input.inputType == qtfb::kInputTouchUpdate) {
    auto active = active_touches_.find(input.devId);
    if (active != active_touches_.end()) {
      active->second.x = x;
      active->second.y = y;
      append_event(&batch, pointer_event(kMove, timestamp_us, active->second,
                                         kFlutterPointerDeviceKindTouch, 1.0));
    }
  } else if (touch_enabled_ && input.inputType == qtfb::kInputTouchRelease) {
    auto active = active_touches_.find(input.devId);
    if (active != active_touches_.end()) {
      active->second.x = x;
      active->second.y = y;
      append_terminal_events(&batch, timestamp_us, active->second,
                             kFlutterPointerDeviceKindTouch, kUp);
      active_touches_.erase(active);
    }
  } else if (pen_enabled_ && input.inputType == qtfb::kInputPenPress) {
    const int32_t device = pen_device_for(input.devId);
    if (device == kNoDevice) {
      finish(&batch);
      return batch;
    }
    auto active = active_pens_.find(input.devId);
    if (active != active_pens_.end()) {
      active->second.x = x;
      active->second.y = y;
      active->second.pressure =
          std::clamp(static_cast<double>(input.d) / 100.0, 0.0, 1.0);
      append_event(&batch, pointer_event(kMove, timestamp_us, active->second,
                                         kFlutterPointerDeviceKindStylus,
                                         active->second.pressure));
      finish(&batch);
      return batch;
    }
    const double pressure =
        std::clamp(static_cast<double>(input.d) / 100.0, 0.0, 1.0);
    const Contact contact{device, x, y, pressure};
    active_pens_[input.devId] = contact;
    append_event(&batch, pointer_event(kAdd, timestamp_us, contact,
                                       kFlutterPointerDeviceKindStylus, 0.0));
    append_event(&batch,
                 pointer_event(kDown, timestamp_us, contact,
                               kFlutterPointerDeviceKindStylus, pressure));
  } else if (pen_enabled_ && input.inputType == qtfb::kInputPenUpdate) {
    auto active = active_pens_.find(input.devId);
    if (active != active_pens_.end()) {
      active->second.x = x;
      active->second.y = y;
      active->second.pressure =
          std::clamp(static_cast<double>(input.d) / 100.0, 0.0, 1.0);
      append_event(&batch, pointer_event(kMove, timestamp_us, active->second,
                                         kFlutterPointerDeviceKindStylus,
                                         active->second.pressure));
    }
  } else if (pen_enabled_ && input.inputType == qtfb::kInputPenRelease) {
    auto active = active_pens_.find(input.devId);
    if (active != active_pens_.end()) {
      active->second.x = x;
      active->second.y = y;
      append_terminal_events(&batch, timestamp_us, active->second,
                             kFlutterPointerDeviceKindStylus, kUp);
      active_pens_.erase(active);
    }
  }

  finish(&batch);
  return batch;
}

QtfbPointerBatch QtfbInputTranslator::cancel_all(std::size_t timestamp_us) {
  QtfbPointerBatch batch;
  for (const auto& [source_device, contact] : active_touches_) {
    (void)source_device;
    append_terminal_events(&batch, timestamp_us, contact,
                           kFlutterPointerDeviceKindTouch, kCancel);
  }
  for (const auto& [source_device, contact] : active_pens_) {
    (void)source_device;
    append_terminal_events(&batch, timestamp_us, contact,
                           kFlutterPointerDeviceKindStylus, kCancel);
  }
  active_touches_.clear();
  active_pens_.clear();
  finish(&batch);
  return batch;
}

FlutterKeyEvent QtfbKeyEvent::flutter_event() const {
  FlutterKeyEvent event{};
  event.struct_size = sizeof(event);
  event.timestamp = timestamp;
  event.type = type;
  event.physical = physical;
  event.logical = logical;
  event.character = has_character ? character.data() : nullptr;
  event.synthesized = synthesized;
  event.device_type = device_type;
  return event;
}

QtfbKeyBatch QtfbKeyTranslator::consume(const qtfb::UserInputContents& input,
                                        std::size_t timestamp_us) {
  QtfbKeyBatch batch;
  KeyMapping mapping;
  bool pressed = false;
  if (input.inputType == qtfb::kInputVirtualKeyboardPress ||
      input.inputType == qtfb::kInputVirtualKeyboardRelease) {
    pressed = input.inputType == qtfb::kInputVirtualKeyboardPress;
    int virtual_code = input.x;
    const int modifier_bits = virtual_code & kVkbModifierMask;
    if ((virtual_code & 0xff) == 0 && modifier_bits != 0 &&
        modifier_bits != kVkbShiftModifier &&
        modifier_bits != kVkbControlModifier &&
        modifier_bits != kVkbAltModifier) {
      // Key.qml ORs already-sticky modifiers into the next modifier-down
      // packet. Recover the one newly pressed bit from our regularized state.
      int selected = 0;
      for (const int bit :
           {kVkbShiftModifier, kVkbControlModifier, kVkbAltModifier}) {
        if ((modifier_bits & bit) == 0) {
          continue;
        }
        const bool held =
            pressed_.find(kVirtualKeySource | bit) != pressed_.end();
        if ((pressed && !held) || (!pressed && held)) {
          if (selected != 0) {
            return batch;
          }
          selected = bit;
        }
      }
      if (selected == 0) {
        return batch;
      }
      virtual_code = selected;
    }
    if (!map_virtual_key(virtual_code, &mapping)) {
      return batch;
    }
  } else if (input.inputType == qtfb::kInputButtonPress ||
             input.inputType == qtfb::kInputButtonRelease) {
    if (!map_tablet_button(input.x, &mapping)) {
      return batch;
    }
    pressed = input.inputType == qtfb::kInputButtonPress;
  } else {
    return batch;
  }

  const auto existing = pressed_.find(mapping.source);
  if (pressed) {
    if (existing != pressed_.end()) {
      mapping.physical = existing->second.physical;
      mapping.logical = existing->second.logical;
      mapping.device_type = existing->second.device_type;
      append_key_event(&batch, kFlutterKeyEventTypeRepeat, timestamp_us,
                       mapping, true, false);
      return batch;
    }
    const auto same_physical =
        std::find_if(pressed_.begin(), pressed_.end(), [&](const auto& entry) {
          return entry.second.physical == mapping.physical;
        });
    if (same_physical != pressed_.end()) {
      // Flutter tracks one logical key per physical key. Ignore a second qtfb
      // source until the original releases instead of emitting an irregular
      // duplicate down (possible when holding a bezel key and its VKB twin).
      return batch;
    }
    pressed_.emplace(
        mapping.source,
        PressedKey{mapping.physical, mapping.logical, mapping.device_type});
    append_key_event(&batch, kFlutterKeyEventTypeDown, timestamp_us, mapping,
                     true, false);
    return batch;
  }

  if (existing == pressed_.end()) {
    return batch;
  }
  mapping.physical = existing->second.physical;
  mapping.logical = existing->second.logical;
  mapping.device_type = existing->second.device_type;
  append_key_event(&batch, kFlutterKeyEventTypeUp, timestamp_us, mapping, false,
                   false);
  pressed_.erase(existing);
  return batch;
}

QtfbKeyBatch QtfbKeyTranslator::cancel_all(std::size_t timestamp_us) {
  QtfbKeyBatch batch;
  for (const auto& [source, pressed] : pressed_) {
    (void)source;
    KeyMapping mapping;
    mapping.physical = pressed.physical;
    mapping.logical = pressed.logical;
    mapping.device_type = pressed.device_type;
    append_key_event(&batch, kFlutterKeyEventTypeUp, timestamp_us, mapping,
                     false, true);
  }
  pressed_.clear();
  return batch;
}

}  // namespace pluto
