#!/usr/bin/env python3
"""Validate and hash one atomic stock-Xochitl mapper capture bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import struct
import sys
from pathlib import Path
from typing import Any


EXPECTED_SIZES = {
    "cap.ctx.bin": 0xB0,
    "cap.srcdesc.bin": 0x30,
    "cap.delta.bin": 0x800,
    "cap.wavedesc.bin": 0x38,
    "cap.abdesc.bin": 0x30,
    "cap.ab.before.bin": 0x645240,
    "cap.ab.after.bin": 0x645240,
    "cap.outdesc.bin": 0x30,
    "cap.palette.bin": 0x10,
}
EXPECTED_XOCHITL_SHA256 = (
    "4646e0aef1cef2b3417889073ad5faba9259ae6b41f68326e75ef9a5c520c322"
)
EXPECTED_XOCHITL_BUILD_ID = "f04525824e27e75d7a579b18c4007a3a76384789"
EXPECTED_GDBSERVER_SHA256 = (
    "f5154a1d16d577c90d794199a2bacf66954e6306e4b09281fb7ca1ecaa2fe8be"
)
EXPECTED_BREAKPOINT_SITES = [
    {
        "name": "mapper",
        "virtual_address": "0x004814a0",
        "file_offset": "0x000814a0",
        "instruction_hex": "3f2303d5",
    },
    {
        "name": "pre_worker",
        "virtual_address": "0x009adbd0",
        "file_offset": "0x005adbd0",
        "instruction_hex": "3f2303d5",
    },
    {
        "name": "post_worker",
        "virtual_address": "0x009ade2c",
        "file_offset": "0x005ade2c",
        "instruction_hex": "e0234239",
    },
]
EXPECTED_RESTORED_INSTRUCTIONS = {
    site["virtual_address"]: site["instruction_hex"]
    for site in EXPECTED_BREAKPOINT_SITES
}

START_RE = re.compile(
    r"^CAPTURE_START: thread=(?P<thread>\d+) ctx=0x(?P<ctx>[0-9a-f]+) "
    r"mode=(?P<mode>-?\d+) ct33_bytes=0x(?P<ct33>[0-9a-f]+) "
    r"src=0x(?P<src>[0-9a-f]+) out_pending=1 wave=0x(?P<wave>[0-9a-f]+) "
    r"delta=0x(?P<delta>[0-9a-f]+) ab_bytes=0x(?P<ab>[0-9a-f]+) "
    r"palette_override=(?P<override>[01]) "
    r"expected_palette=0x(?P<expected_palette>[0-9a-f]+)$",
    re.MULTILINE,
)
MAPPER_RE = re.compile(
    r"^MAPPER_HIT (?P<hit>\d+): ctx=0x(?P<ctx>[0-9a-f]+) "
    r"palette=0x(?P<palette>[0-9a-f]+) rows=(?P<first>\d+)\.\.(?P<last>\d+) "
    r"barrier=0x(?P<barrier>[0-9a-f]+) out=0x(?P<out>[0-9a-f]+)$",
    re.MULTILINE,
)
COMPLETE_RE = re.compile(
    r"^CAPTURE_COMPLETE: mapper_hits=(?P<hits>\d+) "
    r"out_bytes=0x(?P<out>[0-9a-f]+) ab_bytes=0x(?P<ab>[0-9a-f]+) "
    r"valid=(?P<valid>[01]) detached=(?P<detached>[01])$",
    re.MULTILINE,
)
GDB_PID_RE = re.compile(r"^TARGET_GDB_PID: (?P<pid>\d+)$", re.MULTILINE)

PALETTES = {
    2: bytes.fromhex("020c04140810181c0f13021e20202020"),
    3: bytes.fromhex("002020202020201e0f13001e20202020"),
    5: bytes.fromhex("020d05150911191c0f13001e20202020"),
}
LIVE_PROCESS_STATES = {"R", "S", "D", "I"}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_desc(data: bytes) -> dict[str, Any]:
    begin, end, capacity, left, top, right, bottom, stride = struct.unpack(
        "<QQQiiiiQ", data
    )
    return {
        "begin": begin,
        "end": end,
        "capacity": capacity,
        "rect": [left, top, right, bottom],
        "stride": stride,
        "bytes": end - begin if end >= begin else -1,
    }


def ab_diff(before: bytes, after: bytes) -> dict[str, int | None]:
    count = 0
    first = None
    last = None
    for index, (old, new) in enumerate(zip(before, after)):
        if old != new:
            count += 1
            first = index if first is None else first
            last = index
    return {"count": count, "first_offset": first, "last_offset": last}


def validate(args: argparse.Namespace) -> tuple[dict[str, Any], list[str]]:
    root = args.capture_dir.resolve()
    errors: list[str] = []
    names = set(EXPECTED_SIZES) | {"cap.ct33.bin", "cap.out.bin", "cap.gdb.log"}
    if not args.fixture:
        names.add("cap.target.json")
        names.add("cap.recovery.json")
    missing = sorted(name for name in names if not (root / name).is_file())
    if missing:
        return {"capture_dir": str(root), "missing": missing}, [
            f"missing required file: {name}" for name in missing
        ]

    blobs = {
        name: (root / name).read_bytes()
        for name in names
        if name.endswith(".bin")
    }
    controls = {
        name: (root / name).read_bytes()
        for name in names
        if not name.endswith(".bin")
    }
    for name, expected in EXPECTED_SIZES.items():
        actual = len(blobs[name])
        if actual != expected:
            errors.append(f"{name}: size 0x{actual:x}, expected 0x{expected:x}")

    files = {
        name: {"bytes": len(data), "sha256": sha256(data)}
        for name, data in sorted({**blobs, **controls}.items())
    }
    structural_files = (
        "cap.ctx.bin",
        "cap.srcdesc.bin",
        "cap.outdesc.bin",
        "cap.wavedesc.bin",
        "cap.abdesc.bin",
    )
    if any(len(blobs[name]) != EXPECTED_SIZES[name] for name in structural_files):
        return {
            "schema": 1,
            "capture_dir": str(root),
            "valid": False,
            "files": files,
            "errors": errors,
        }, errors

    log = controls["cap.gdb.log"].decode("utf-8", errors="replace")
    start_matches = list(START_RE.finditer(log))
    complete_matches = list(COMPLETE_RE.finditer(log))
    gdb_pid_matches = list(GDB_PID_RE.finditer(log))
    start_match = start_matches[0] if len(start_matches) == 1 else None
    complete_match = complete_matches[0] if len(complete_matches) == 1 else None
    mapper_matches = list(MAPPER_RE.finditer(log))
    if len(start_matches) != 1:
        errors.append(f"cap.gdb.log: expected one CAPTURE_START, found {len(start_matches)}")
    if len(complete_matches) != 1:
        errors.append(
            f"cap.gdb.log: expected one detached CAPTURE_COMPLETE, found "
            f"{len(complete_matches)}"
        )
    if len(gdb_pid_matches) != 1:
        errors.append(f"cap.gdb.log: expected one TARGET_GDB_PID, found {len(gdb_pid_matches)}")
    if not mapper_matches:
        errors.append("cap.gdb.log: missing MAPPER_HIT")
    if (
        "MAPPER_FOREIGN:" in log
        or "CAPTURE_REJECT:" in log
        or "MAPPER_REJECT:" in log
        or "CAPTURE_CLEANUP_ERROR:" in log
    ):
        errors.append("cap.gdb.log records a rejected or foreign mapper operation")
    if start_match and complete_match:
        if not (
            len(gdb_pid_matches) == 1
            and gdb_pid_matches[0].start() < start_match.start()
            and start_match.start() < complete_match.start()
            and all(
                start_match.start() < match.start() < complete_match.start()
                for match in mapper_matches
            )
        ):
            errors.append("cap.gdb.log capture events are out of order")

    ctx = blobs["cap.ctx.bin"]
    src_desc = parse_desc(blobs["cap.srcdesc.bin"])
    out_desc = parse_desc(blobs["cap.outdesc.bin"])
    ab_desc = parse_desc(blobs["cap.abdesc.bin"])
    wave_desc_delta_ptr = struct.unpack_from(
        "<Q", blobs["cap.wavedesc.bin"], 0x30
    )[0]
    source_desc_ptr = struct.unpack_from("<Q", ctx, 0x00)[0]
    ct33_ptr = struct.unpack_from("<Q", ctx, 0x10)[0]
    ct33_rect = list(struct.unpack_from("<iiii", ctx, 0x18))
    ct33_stride = struct.unpack_from("<Q", ctx, 0x28)[0]
    ct33_stride_copy = struct.unpack_from("<Q", ctx, 0x30)[0]
    update_rect = list(struct.unpack_from("<iiii", ctx, 0x38))
    wave_ptr = struct.unpack_from("<Q", ctx, 0x58)[0]
    mode = struct.unpack_from("<h", ctx, 0x68)[0]
    temperature = struct.unpack_from("<f", ctx, 0x6C)[0]
    output_desc_ptr = struct.unpack_from("<Q", ctx, 0x70)[0]
    flag_a0 = ctx[0xA0]
    flag_a1 = ctx[0xA1]
    flag_a2 = ctx[0xA2]
    palette_override = flag_a2 & 1
    expected_palette_address = 0x014FB560 + (
        0x30 if palette_override else mode * 16
    )

    if src_desc["bytes"] != len(blobs["cap.ct33.bin"]):
        errors.append("ct33 dump length does not match source descriptor end-begin")
    if out_desc["bytes"] != len(blobs["cap.out.bin"]):
        errors.append("output dump length does not match output descriptor end-begin")
    if ct33_ptr != src_desc["begin"]:
        errors.append("ctx ct33 pointer does not equal source descriptor begin")
    if ct33_stride != ct33_stride_copy:
        errors.append("ctx duplicated ct33 strides disagree")
    if ct33_stride != src_desc["stride"]:
        errors.append("ctx ct33 stride does not match source descriptor stride")
    if ct33_rect != src_desc["rect"]:
        errors.append("ctx ct33 rect does not match source descriptor rect")
    if mode not in (2, 5):
        errors.append(f"ctx mode {mode} is not Content/UI mode 2 or 5")
    if not math.isfinite(temperature):
        errors.append("ctx temperature is not finite")
    if source_desc_ptr == 0 or wave_ptr == 0 or output_desc_ptr == 0:
        errors.append("ctx contains a null required object pointer")
    if flag_a0 != 0 or flag_a1 != 0:
        errors.append("ctx routes away from the active legacy mapper via flags a0/a1")
    for label, desc in (("source", src_desc), ("output", out_desc)):
        if desc["bytes"] <= 0 or desc["capacity"] < desc["end"]:
            errors.append(f"{label} descriptor pointer ordering is invalid")
        left, top, right, bottom = desc["rect"]
        if right < left or bottom < top or desc["stride"] == 0:
            errors.append(f"{label} descriptor geometry/stride is invalid")

    src_left, src_top, src_right, src_bottom = src_desc["rect"]
    update_left, update_top, update_right, update_bottom = update_rect
    if (
        update_right < update_left
        or update_bottom < update_top
        or src_left > update_left
        or src_top > update_top
        or src_right < update_right
        or src_bottom < update_bottom
    ):
        errors.append("update rect is invalid or is not contained by the ct33 source rect")

    if ab_desc["bytes"] != len(blobs["cap.ab.before.bin"]):
        errors.append("A/B descriptor length does not match snapshots")
    if (
        ab_desc["rect"] != [0, 0, 959, 1695]
        or ab_desc["stride"] != 968
        or ab_desc["bytes"] != 0x645240
        or ab_desc["capacity"] < ab_desc["end"]
    ):
        errors.append("A/B descriptor geometry/stride/capacity is invalid")

    update_width = update_rect[2] - update_rect[0] + 1
    update_height_with_guards = update_rect[3] - update_rect[1] + 3
    expected_out_stride = (update_width + 15) & ~7
    expected_out_bytes = update_height_with_guards * expected_out_stride * 2
    if (
        out_desc["rect"] != update_rect
        or out_desc["stride"] != expected_out_stride
        or out_desc["bytes"] != expected_out_bytes
    ):
        errors.append("output descriptor violates Xochitl constructor formula")

    palette_key = 3 if palette_override else mode
    expected_palette = PALETTES.get(palette_key)
    if expected_palette is None or blobs["cap.palette.bin"] != expected_palette:
        errors.append("captured palette bytes do not match the selected stock palette")
    if not any(blobs["cap.delta.bin"]):
        errors.append("delta table is all zero")

    start: dict[str, int] | None = None
    if start_match:
        hex_fields = {"ctx", "ct33", "src", "wave", "delta", "ab", "expected_palette"}
        start = {
            key: int(value, 16 if key in hex_fields else 10)
            for key, value in start_match.groupdict().items()
        }
        if start["ctx"] == 0:
            errors.append("CAPTURE_START ctx is invalid")
        if start["mode"] != mode:
            errors.append("CAPTURE_START mode disagrees with dumped context")
        if start["ct33"] != len(blobs["cap.ct33.bin"]):
            errors.append("CAPTURE_START ct33 length disagrees with dump")
        if start["ab"] != len(blobs["cap.ab.before.bin"]):
            errors.append("CAPTURE_START A/B length disagrees with dump")
        if start["src"] != source_desc_ptr:
            errors.append("CAPTURE_START source pointer disagrees with context")
        if start["wave"] != wave_ptr or start["delta"] == 0:
            errors.append("CAPTURE_START waveform/delta pointers are invalid")
        if wave_desc_delta_ptr != start["delta"]:
            errors.append(
                "waveform descriptor delta pointer disagrees with CAPTURE_START"
            )
        if start["override"] != palette_override:
            errors.append("CAPTURE_START palette override disagrees with context")
        if start["expected_palette"] != expected_palette_address:
            errors.append("CAPTURE_START expected palette address is incorrect")

    mapper_rows: list[list[int]] = []
    mapper_ctxs: set[int] = set()
    mapper_palettes: set[int] = set()
    mapper_barriers: set[int] = set()
    mapper_outputs: set[int] = set()
    mapper_labels: list[int] = []
    for match in mapper_matches:
        mapper_labels.append(int(match.group("hit")))
        mapper_ctxs.add(int(match.group("ctx"), 16))
        mapper_palettes.add(int(match.group("palette"), 16))
        mapper_barriers.add(int(match.group("barrier"), 16))
        mapper_outputs.add(int(match.group("out"), 16))
        first = int(match.group("first"))
        last = int(match.group("last"))
        mapper_rows.append([first, last])
        if last < first:
            errors.append("mapper row range is reversed")
    mapper_rows.sort()
    if len(mapper_matches) not in (1, 2):
        errors.append("mapper hit count must be one or two")
    if mapper_labels != list(range(1, len(mapper_labels) + 1)):
        errors.append("mapper hit labels are not consecutive from one")
    if start and mapper_ctxs != {start["ctx"]}:
        errors.append("mapper hit context does not match CAPTURE_START")
    if mapper_palettes != {expected_palette_address}:
        errors.append("mapper palette pointer does not match selected stock palette")
    if len(mapper_barriers) != 1 or 0 in mapper_barriers:
        errors.append("mapper workers do not share one nonzero barrier")
    if mapper_outputs != {output_desc_ptr}:
        errors.append("mapper output pointer does not match dumped context")
    if mapper_rows:
        for previous, current in zip(mapper_rows, mapper_rows[1:]):
            if current[0] != previous[1] + 1:
                errors.append("mapper row ranges overlap or leave a gap")
        if mapper_rows[0][0] != update_rect[1] or mapper_rows[-1][1] != update_rect[3]:
            errors.append("mapper rows do not exactly cover update rect top..bottom")

    complete: dict[str, int] | None = None
    if complete_match:
        complete = {key: int(value, 16 if key in {"out", "ab"} else 10)
                    for key, value in complete_match.groupdict().items()}
        if complete["valid"] != 1:
            errors.append("GDB script marked capture invalid")
        if complete["detached"] != 1:
            errors.append("GDB script did not prove successful detach")
        if complete["hits"] != len(mapper_matches):
            errors.append("CAPTURE_COMPLETE hit count disagrees with log")
        if complete["out"] != len(blobs["cap.out.bin"]):
            errors.append("CAPTURE_COMPLETE output length disagrees with dump")
        if complete["ab"] != len(blobs["cap.ab.after.bin"]):
            errors.append("CAPTURE_COMPLETE A/B length disagrees with dump")

    differences = ab_diff(blobs["cap.ab.before.bin"], blobs["cap.ab.after.bin"])
    if differences["count"] == 0:
        errors.append("A/B pre/post snapshots are identical; not a useful mapper golden")

    if not any(blobs["cap.out.bin"]):
        errors.append("output dump is all zero; controlled update did not yield a useful golden")

    xochitl: dict[str, Any] | None = None
    target: dict[str, Any] | None = None
    recovery: dict[str, Any] | None = None
    if not args.fixture:
        binary_path = args.xochitl.resolve()
        if not binary_path.is_file():
            errors.append(f"Xochitl binary does not exist: {binary_path}")
            xochitl = {"path": str(binary_path), "sha256": None}
        else:
            digest = sha256(binary_path.read_bytes())
            xochitl = {"path": str(binary_path), "sha256": digest}
            if digest != args.expected_xochitl_sha256:
                errors.append(
                    f"Xochitl SHA-256 {digest} != expected "
                    f"{args.expected_xochitl_sha256}"
                )
        try:
            parsed_target = json.loads(
                controls["cap.target.json"].decode("utf-8")
            )
            if not isinstance(parsed_target, dict):
                errors.append("cap.target.json root is not an object")
                target = {}
            else:
                target = parsed_target
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            errors.append(f"cap.target.json is invalid: {error}")
            target = {}
        gdb_pid = (
            int(gdb_pid_matches[0].group("pid"))
            if len(gdb_pid_matches) == 1
            else None
        )
        if target.get("schema") != 2:
            errors.append("target identity schema is not 2")
        if target.get("breakpoint_kind") != "software":
            errors.append("target identity does not pin software breakpoints")
        if target.get("breakpoint_sites") != EXPECTED_BREAKPOINT_SITES:
            errors.append("target identity breakpoint sites do not match pinned ELF bytes")
        target_pid = target.get("pid")
        if (
            target_pid != gdb_pid
            or not isinstance(target_pid, int)
            or isinstance(target_pid, bool)
        ):
            errors.append("target identity PID does not match GDB remote PID")
        if Path(str(target.get("exe", ""))).name != "xochitl":
            errors.append("target executable basename is not xochitl")
        if target.get("remote_sha256") != args.expected_xochitl_sha256:
            errors.append("running target SHA-256 is not the expected Xochitl hash")
        if target.get("local_sha256") != args.expected_xochitl_sha256:
            errors.append("target identity local SHA-256 is not the expected hash")
        if target.get("build_id") != EXPECTED_XOCHITL_BUILD_ID:
            errors.append("target identity Build ID is not the expected Xochitl Build ID")
        target_start_time = target.get("start_time_ticks")
        if (
            not isinstance(target_start_time, int)
            or isinstance(target_start_time, bool)
            or target_start_time <= 0
        ):
            errors.append("target identity has no valid process start time")
        target_tracer = target.get("tracer_pid")
        if (
            not isinstance(target_tracer, int)
            or isinstance(target_tracer, bool)
            or target_tracer != 0
        ):
            errors.append("target identity did not prove TracerPid zero before attach")
        if target.get("state") not in LIVE_PROCESS_STATES:
            errors.append("target identity did not prove a live pre-attach state")
        remote_server_pid = target.get("gdbserver_pid")
        if (
            not isinstance(remote_server_pid, int)
            or isinstance(remote_server_pid, bool)
            or remote_server_pid <= 0
        ):
            errors.append("target identity has no valid remote gdbserver PID")
        remote_server_start = target.get("gdbserver_start_time_ticks")
        if (
            not isinstance(remote_server_start, int)
            or isinstance(remote_server_start, bool)
            or remote_server_start <= 0
        ):
            errors.append("target identity has no valid remote gdbserver start time")
        if Path(str(target.get("gdbserver_exe", ""))).name != (
            "pluto-gdbserver-aarch64"
        ):
            errors.append("target identity has the wrong remote gdbserver executable")
        if target.get("gdbserver_sha256") != EXPECTED_GDBSERVER_SHA256:
            errors.append("target identity has the wrong gdbserver SHA-256")
        try:
            parsed_recovery = json.loads(
                controls["cap.recovery.json"].decode("utf-8")
            )
            if not isinstance(parsed_recovery, dict):
                errors.append("cap.recovery.json root is not an object")
                recovery = {}
            else:
                recovery = parsed_recovery
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            errors.append(f"cap.recovery.json is invalid: {error}")
            recovery = {}
        if recovery.get("pid") != target_pid:
            errors.append("recovery PID does not match captured target")
        recovery_tracer = recovery.get("tracer_pid")
        if (
            not isinstance(recovery_tracer, int)
            or isinstance(recovery_tracer, bool)
            or recovery_tracer != 0
        ):
            errors.append("recovery did not prove TracerPid zero")
        if recovery.get("state") not in LIVE_PROCESS_STATES:
            errors.append("recovery did not prove Xochitl resumed")
        if recovery.get("start_time_ticks") != target_start_time:
            errors.append("recovery process start time does not match captured target")
        if recovery.get("exe") != target.get("exe"):
            errors.append("recovery executable path does not match captured target")
        if recovery.get("remote_sha256") != target.get("remote_sha256"):
            errors.append("recovery executable hash does not match captured target")
        if (
            recovery.get("restored_instruction_bytes")
            != EXPECTED_RESTORED_INSTRUCTIONS
        ):
            errors.append(
                "recovery did not prove all software-breakpoint instructions restored"
            )
    manifest: dict[str, Any] = {
        "schema": 1,
        "profile": "fixture" if args.fixture else "stock-xochitl-3.27.1",
        "capture_dir": str(root),
        "valid": not errors,
        "xochitl": xochitl,
        "target": target,
        "recovery": recovery,
        "context": {
            "source_desc_ptr": source_desc_ptr,
            "ct33_ptr": ct33_ptr,
            "ct33_rect": ct33_rect,
            "ct33_stride": ct33_stride,
            "update_rect": update_rect,
            "wave_ptr": wave_ptr,
            "mode": mode,
            "temperature_c": temperature,
            "output_desc_ptr": output_desc_ptr,
        },
        "source_descriptor": src_desc,
        "output_descriptor": out_desc,
        "waveform_descriptor": {"delta_ptr": wave_desc_delta_ptr},
        "ab_descriptor": ab_desc,
        "mapper": {
            "hit_count": len(mapper_matches),
            "labels": mapper_labels,
            "contexts": sorted(mapper_ctxs),
            "palettes": sorted(mapper_palettes),
            "barriers": sorted(mapper_barriers),
            "outputs": sorted(mapper_outputs),
            "rows": mapper_rows,
        },
        "mapper_rows": mapper_rows,
        "ab_diff": differences,
        "files": files,
        "errors": errors,
    }
    return manifest, errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_dir", type=Path)
    identity = parser.add_mutually_exclusive_group(required=True)
    identity.add_argument("--xochitl", type=Path)
    identity.add_argument(
        "--fixture",
        action="store_true",
        help="accept the synthetic fixture profile without target provenance",
    )
    parser.add_argument(
        "--expected-xochitl-sha256", default=EXPECTED_XOCHITL_SHA256
    )
    parser.add_argument("--write-manifest", action="store_true")
    args = parser.parse_args()

    manifest, errors = validate(args)
    rendered = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    if args.write_manifest:
        destination = args.capture_dir.resolve() / "capture-manifest.json"
        destination.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
