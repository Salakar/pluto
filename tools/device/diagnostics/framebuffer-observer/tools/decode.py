#!/usr/bin/env python3
"""Decode a Pluto framebuffer-observer trace without target-specific headers."""

from __future__ import annotations

import argparse
import json
import pathlib
import struct
import sys
from dataclasses import dataclass
from typing import Any, Iterator

MAGIC = b"PFOBSV1\0"
SCHEMA_VERSION = 1
ENDIAN_TAG = 0x01020304
HEADER_SIZE = 64
RECORD_SIZE = 416
PAYLOAD_SIZE = 320

HEADER = struct.Struct("<8sHHHHIIIIQIIQQ")
RECORD_PREFIX = struct.Struct("<IHHIIiIQQiiHHHHQQq")
MXCFB_UPDATE = struct.Struct("<7IiIi8I")
MXCFB_MARKER = struct.Struct("<II")
FB_VAR = struct.Struct("<40I")
FB_FIX = struct.Struct("<16sIIIIIHHH2xIIIIH2H2x")
U32 = struct.Struct("<I")

PROFILE_NAMES = {0: "unknown", 1: "remarkable1", 2: "remarkable2"}
RECORD_NAMES = {
    1: "open",
    2: "mmap",
    3: "munmap",
    4: "ioctl",
    5: "phase_hash",
}
PAYLOAD_NAMES = {
    0: "none",
    1: "mxcfb_update",
    2: "mxcfb_marker",
    3: "fb_var_screeninfo",
    4: "fb_fix_screeninfo",
    5: "u32",
    6: "phase_hash",
}


class TraceFormatError(ValueError):
    """The trace does not implement the fixed observer schema."""


@dataclass(frozen=True)
class TraceHeader:
    schema_version: int
    flags: int
    capacity: int
    next_index: int
    dropped_records: int
    profile: int
    start_monotonic_ns: int
    process_id: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "flags": self.flags,
            "capacity": self.capacity,
            "next_index": self.next_index,
            "dropped_records": self.dropped_records,
            "profile": PROFILE_NAMES.get(self.profile, f"unknown:{self.profile}"),
            "start_monotonic_ns": self.start_monotonic_ns,
            "process_id": self.process_id,
        }


def parse_header(data: bytes) -> TraceHeader:
    if len(data) < HEADER_SIZE:
        raise TraceFormatError("trace is shorter than the 64-byte header")
    (
        magic,
        schema_version,
        header_size,
        record_size,
        flags,
        capacity,
        next_index,
        dropped_records,
        profile,
        start_monotonic_ns,
        process_id,
        endian_tag,
        _reserved0,
        _reserved1,
    ) = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise TraceFormatError(f"invalid trace magic: {magic!r}")
    if schema_version != SCHEMA_VERSION:
        raise TraceFormatError(
            f"unsupported schema version {schema_version}; expected {SCHEMA_VERSION}"
        )
    if header_size != HEADER_SIZE or record_size != RECORD_SIZE:
        raise TraceFormatError(
            f"incompatible sizes: header={header_size}, record={record_size}"
        )
    if endian_tag != ENDIAN_TAG:
        raise TraceFormatError(f"invalid little-endian tag: 0x{endian_tag:08x}")
    required_size = HEADER_SIZE + capacity * RECORD_SIZE
    if len(data) < required_size:
        raise TraceFormatError(
            f"trace is truncated: {len(data)} bytes; expected at least {required_size}"
        )
    return TraceHeader(
        schema_version=schema_version,
        flags=flags,
        capacity=capacity,
        next_index=next_index,
        dropped_records=dropped_records,
        profile=profile,
        start_monotonic_ns=start_monotonic_ns,
        process_id=process_id,
    )


def _decode_mxcfb_update(payload: bytes) -> dict[str, Any]:
    values = MXCFB_UPDATE.unpack(payload)
    return {
        "update_region": {
            "top": values[0],
            "left": values[1],
            "width": values[2],
            "height": values[3],
        },
        "waveform_mode": values[4],
        "update_mode": values[5],
        "update_marker": values[6],
        "temperature": values[7],
        "flags": values[8],
        "dither_mode": values[9],
        "quant_bit": values[10],
        "alt_buffer": {
            "phys_addr": values[11],
            "width": values[12],
            "height": values[13],
            "update_region": {
                "top": values[14],
                "left": values[15],
                "width": values[16],
                "height": values[17],
            },
        },
    }


def _decode_fb_var(payload: bytes) -> dict[str, Any]:
    values = FB_VAR.unpack(payload)
    names = (
        "xres",
        "yres",
        "xres_virtual",
        "yres_virtual",
        "xoffset",
        "yoffset",
        "bits_per_pixel",
        "grayscale",
    )
    decoded: dict[str, Any] = dict(zip(names, values[:8]))
    for index, color in enumerate(("red", "green", "blue", "transp")):
        start = 8 + index * 3
        decoded[color] = {
            "offset": values[start],
            "length": values[start + 1],
            "msb_right": values[start + 2],
        }
    tail_names = (
        "nonstd",
        "activate",
        "height_mm",
        "width_mm",
        "accel_flags",
        "pixclock",
        "left_margin",
        "right_margin",
        "upper_margin",
        "lower_margin",
        "hsync_len",
        "vsync_len",
        "sync",
        "vmode",
        "rotate",
        "colorspace",
    )
    decoded.update(zip(tail_names, values[20:36]))
    decoded["reserved"] = list(values[36:40])
    return decoded


def _decode_fb_fix(payload: bytes) -> dict[str, Any]:
    values = FB_FIX.unpack(payload)
    return {
        "id": values[0].split(b"\0", 1)[0].decode("ascii", errors="replace"),
        "smem_start": values[1],
        "smem_len": values[2],
        "type": values[3],
        "type_aux": values[4],
        "visual": values[5],
        "xpanstep": values[6],
        "ypanstep": values[7],
        "ywrapstep": values[8],
        "line_length": values[9],
        "mmio_start": values[10],
        "mmio_len": values[11],
        "accel": values[12],
        "capabilities": values[13],
        "reserved": [values[14], values[15]],
    }


def decode_payload(kind: int, payload: bytes) -> Any:
    if kind == 0:
        return None
    if kind == 1 and len(payload) == MXCFB_UPDATE.size:
        return _decode_mxcfb_update(payload)
    if kind == 2 and len(payload) == MXCFB_MARKER.size:
        marker, collision_test = MXCFB_MARKER.unpack(payload)
        return {"update_marker": marker, "collision_test": collision_test}
    if kind == 3 and len(payload) == FB_VAR.size:
        return _decode_fb_var(payload)
    if kind == 4 and len(payload) == FB_FIX.size:
        return _decode_fb_fix(payload)
    if kind == 5 and len(payload) == U32.size:
        return U32.unpack(payload)[0]
    return {"raw_hex": payload.hex()}


def decode_record(slot: bytes) -> dict[str, Any] | None:
    if len(slot) != RECORD_SIZE:
        raise TraceFormatError(f"record slot has {len(slot)} bytes; expected {RECORD_SIZE}")
    (
        commit_sequence,
        record_type,
        payload_kind,
        sequence,
        thread_id,
        fd,
        request,
        entry_ns,
        exit_ns,
        result,
        error_number,
        payload_size,
        pre_size,
        post_size,
        flags,
        map_address,
        map_length,
        map_offset,
    ) = RECORD_PREFIX.unpack_from(slot)
    if commit_sequence == 0:
        return None
    if commit_sequence != sequence:
        return None
    if payload_size > PAYLOAD_SIZE or pre_size + post_size != payload_size:
        raise TraceFormatError(
            f"record {sequence} has invalid payload sizes "
            f"total={payload_size}, pre={pre_size}, post={post_size}"
        )
    payload = slot[RECORD_PREFIX.size : RECORD_PREFIX.size + payload_size]
    pre = payload[:pre_size]
    post = payload[pre_size:]
    return {
        "sequence": sequence,
        "type": RECORD_NAMES.get(record_type, f"unknown:{record_type}"),
        "payload_kind": PAYLOAD_NAMES.get(payload_kind, f"unknown:{payload_kind}"),
        "thread_id": thread_id,
        "fd": fd,
        "request": f"0x{request:08x}",
        "entry_monotonic_ns": entry_ns,
        "exit_monotonic_ns": exit_ns,
        "duration_ns": max(0, exit_ns - entry_ns),
        "result": result,
        "errno": error_number,
        "flags": flags,
        "map_address": f"0x{map_address:x}",
        "map_length": map_length,
        "map_offset": map_offset,
        "pre": decode_payload(payload_kind, pre),
        "post": decode_payload(payload_kind, post),
    }


def iter_records(data: bytes, header: TraceHeader) -> Iterator[dict[str, Any]]:
    slot_count = min(header.next_index, header.capacity)
    for index in range(slot_count):
        offset = HEADER_SIZE + index * RECORD_SIZE
        decoded = decode_record(data[offset : offset + RECORD_SIZE])
        if decoded is not None:
            yield decoded


def decode_trace(path: pathlib.Path) -> tuple[TraceHeader, list[dict[str, Any]]]:
    data = path.read_bytes()
    header = parse_header(data)
    return header, list(iter_records(data, header))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=pathlib.Path)
    parser.add_argument(
        "--pretty", action="store_true", help="indent the JSON document"
    )
    arguments = parser.parse_args(argv)
    try:
        header, records = decode_trace(arguments.trace)
    except (OSError, TraceFormatError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    document = {"header": header.as_dict(), "records": records}
    json.dump(document, sys.stdout, indent=2 if arguments.pretty else None)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
