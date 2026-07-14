#!/usr/bin/env python3

import importlib.util
import struct
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "generate_xochitl_mapper_fixture.py"
)
SPEC = importlib.util.spec_from_file_location("generate_xochitl_mapper_fixture", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class GenerateXochitlMapperFixtureTest(unittest.TestCase):
    def test_normal_pattern_pins_operation_local_rows(self) -> None:
        expected, payloads = fixture.build("normal_pattern", 64, 64)
        raw = payloads["ct33.bin"]
        self.assertEqual(raw[:8], bytes(range(8)))
        self.assertEqual(raw[fixture.RAW_STRIDE:fixture.RAW_STRIDE + 8],
                         bytes(reversed(range(8))))
        self.assertEqual(expected["transitions"],
                         [2, 12, 4, 20, 8, 16, 24, 28,
                          28, 24, 16, 8, 20, 4, 12, 2])

    def test_force27_pins_delta_and_full_rounded_domain(self) -> None:
        expected, payloads = fixture.build("force27", 64, 64)
        t = fixture.transition(2, 27)
        self.assertEqual(struct.unpack_from("<h", payloads["delta.bin"], 2 * t)[0], -2)
        self.assertEqual(expected["transitions"], [t] * 16)
        self.assertEqual(len(expected["ab_after"]), 16)

    def test_pair31_focus_has_white_markers_and_one_old_low_neighbour(self) -> None:
        expected, payloads = fixture.build("pair31", 64, 64)
        ab = payloads["ab.bin"]
        west = 4 * (64 * fixture.AB_STRIDE + 66)
        center = 4 * (64 * fixture.AB_STRIDE + 67)
        self.assertEqual(struct.unpack_from("<HH", ab, west), (2, 0))
        self.assertEqual(struct.unpack_from("<HH", ab, center), (0x80 | 28, 0x13))
        self.assertEqual(payloads["ct33.bin"][3], 0x80 | 7)
        self.assertEqual(expected["focus"]["transition"], fixture.transition(28, 31))
        self.assertEqual(expected["focus"]["a_after"], 0x9C)
        self.assertEqual(expected["focus"]["b_after"], 0x24)

    def test_set6_low_source_distinguishes_setup_from_carry(self) -> None:
        expected, payloads = fixture.build("set6_low_source", 64, 64)
        raw = payloads["ct33.bin"]
        ab = payloads["ab.bin"]
        focus = 4 * (64 * fixture.AB_STRIDE + 64)

        self.assertEqual(raw[0], 0x87)
        self.assertEqual(raw[fixture.RAW_STRIDE], 7)
        self.assertEqual(struct.unpack_from("<HH", ab, focus), (2, 0))
        self.assertEqual(expected["transitions"], [2 * 32 + 28] * 16)
        self.assertEqual(expected["focus"]["a_after"], 0xDC)
        self.assertEqual(expected["focus"]["b_after"], 0)

    def test_rejects_geometry_outside_active_panel(self) -> None:
        with self.assertRaisesRegex(ValueError, "contained"):
            fixture.build("normal_pattern", 959, 0)
        with self.assertRaisesRegex(ValueError, "contained"):
            fixture.build("normal_pattern", 0, 1695)


if __name__ == "__main__":
    unittest.main()
