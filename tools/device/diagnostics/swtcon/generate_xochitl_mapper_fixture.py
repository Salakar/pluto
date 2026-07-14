#!/usr/bin/env python3
"""Generate deterministic production-geometry inputs for the Xochitl oracle.

The active mapper consumes ct33 bytes from an operation-local pointer but
updates the process-wide 968x1698 interleaved A/B plane at absolute update
coordinates.  These fixtures deliberately use an already aligned 8x2 update
so every authored lane is observable without an additional rounding case.
They are diagnostic inputs only and do not enable the production presenter.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


PANEL_WIDTH = 960
PANEL_HEIGHT = 1696
RAW_STRIDE = 960
RAW_BYTES = RAW_STRIDE * PANEL_HEIGHT
AB_STRIDE = 968
AB_ROWS = 1698
AB_BYTES = AB_STRIDE * AB_ROWS * 4
MODE2_PALETTE = bytes((2, 12, 4, 20, 8, 16, 24, 28,
                       15, 19, 2, 30, 32, 32, 32, 32))


def transition(source: int, destination: int) -> int:
    return (source & 31) * 32 + (destination & 31)


def sha256(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def set_ab(ab: bytearray, x: int, y: int, a: int, b: int) -> None:
    struct.pack_into("<HH", ab, 4 * (y * AB_STRIDE + x), a & 0xFFFF, b & 0xFFFF)


def build(case: str, left: int, top: int) -> tuple[dict[str, object], dict[str, bytes]]:
    if left < 0 or top < 0 or left + 8 > PANEL_WIDTH or top + 2 > PANEL_HEIGHT:
        raise ValueError("8x2 fixture must be contained by the active 960x1696 panel")

    raw = bytearray(RAW_BYTES)
    ab = bytearray(AB_BYTES)
    delta = bytearray(2048)
    expected: dict[str, object] = {
        "schema": 1,
        "case": case,
        "panel_rect": [left, top, 8, 2],
        "source_contract": "operation-local rows at offsets 0 and raw_stride",
        "raw_stride": RAW_STRIDE,
        "ab_stride": AB_STRIDE,
    }

    if case == "normal_pattern":
        raw[0:8] = bytes(range(8))
        raw[RAW_STRIDE:RAW_STRIDE + 8] = bytes(reversed(range(8)))
        forward = list(MODE2_PALETTE[:8])
        expected["transitions"] = forward + list(reversed(forward))
        expected["ab_after"] = [
            {"x": left + x, "y": top + y, "a": expected["transitions"][y * 8 + x], "b": 0}
            for y in range(2)
            for x in range(8)
        ]
    elif case == "force27":
        t = transition(2, 27)
        struct.pack_into("<h", delta, 2 * t, -2)
        for y in range(2):
            for x in range(8):
                set_ab(ab, left + x, top + y, 2, 3)
        expected["transitions"] = [t] * 16
        expected["ab_after"] = [
            {"x": left + x, "y": top + y, "a": 2, "b": 0xFFFB}
            for y in range(2)
            for x in range(8)
        ]
    elif case == "pair31":
        raw[0:8] = b"\x07" * 8
        raw[RAW_STRIDE:RAW_STRIDE + 8] = b"\x07" * 8
        for y in range(2):
            for x in range(8):
                set_ab(ab, left + x, top + y, 28, 0)
        # Centre of interest is local (3,0).  Its west neighbour is the one
        # old-low member of the von-Neumann cross; every new mapped state is
        # high.  Exact-white markers make C true.
        set_ab(ab, left + 2, top, 2, 0)
        set_ab(ab, left + 3, top, 0x80 | 28, 0x13)
        raw[3] = 0x80 | 7
        t = transition(28, 31)
        struct.pack_into("<h", delta, 2 * t, 5)
        expected["focus"] = {
            "local_x": 3,
            "local_y": 0,
            "transition": t,
            "a_after": 0x9C,
            "b_after": 0x24,
        }
    elif case == "set6_low_source":
        raw[0:8] = b"\x07" * 8
        raw[RAW_STRIDE:RAW_STRIDE + 8] = b"\x07" * 8
        for y in range(2):
            for x in range(8):
                set_ab(ab, left + x, top + y, 2, 0)
        # A raw exact-white marker plus an all-high new cross establishes bit
        # 6 even though the old logical source is low.  This distinguishes the
        # setup predicate from the old-high-only carry predicate.
        raw[0] = 0x80 | 7
        t = transition(2, 28)
        expected["transitions"] = [t] * 16
        expected["focus"] = {
            "local_x": 0,
            "local_y": 0,
            "transition": t,
            "a_after": 0xDC,
            "b_after": 0,
        }
    else:
        raise ValueError(f"unsupported case: {case}")

    payloads = {
        "palette.bin": MODE2_PALETTE,
        "ct33.bin": bytes(raw),
        "delta.bin": bytes(delta),
        "ab.bin": bytes(ab),
    }
    expected["inputs"] = {
        name: {"bytes": len(data), "sha256": sha256(data)}
        for name, data in payloads.items()
    }
    return expected, payloads


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--case",
        required=True,
        choices=("normal_pattern", "force27", "pair31", "set6_low_source"),
    )
    parser.add_argument("--left", type=int, default=64)
    parser.add_argument("--top", type=int, default=64)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.expanduser().resolve(strict=False)
    if output.exists() or output.is_symlink():
        parser.error(f"output must not already exist: {output}")
    if not output.parent.is_dir():
        parser.error(f"output parent does not exist: {output.parent}")

    expected, payloads = build(args.case, args.left, args.top)
    output.mkdir(mode=0o700)
    for name, data in payloads.items():
        (output / name).write_bytes(data)
    (output / "expected.json").write_text(
        json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
