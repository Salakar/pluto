#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
DECODER_PATH = ROOT / "tools" / "decode.py"
SPEC = importlib.util.spec_from_file_location("fb_observer_decode", DECODER_PATH)
assert SPEC is not None and SPEC.loader is not None
decode = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = decode
SPEC.loader.exec_module(decode)


def make_header(*, capacity: int = 1, next_index: int = 1, dropped: int = 0) -> bytes:
    return decode.HEADER.pack(
        decode.MAGIC,
        decode.SCHEMA_VERSION,
        decode.HEADER_SIZE,
        decode.RECORD_SIZE,
        0,
        capacity,
        next_index,
        dropped,
        1,
        123456789,
        314,
        decode.ENDIAN_TAG,
        0,
        0,
    )


def make_update(marker: int) -> bytes:
    return decode.MXCFB_UPDATE.pack(
        10,
        20,
        300,
        400,
        7,
        1,
        marker,
        -5,
        0xA5,
        -3,
        9,
        0x12340000,
        1404,
        1872,
        1,
        2,
        3,
        4,
    )


def make_record(*, commit: int = 1, sequence: int = 1) -> bytes:
    pre = make_update(100)
    post = make_update(101)
    payload = pre + post
    prefix = decode.RECORD_PREFIX.pack(
        commit,
        4,
        1,
        sequence,
        99,
        12,
        0x4048462E,
        1000,
        1300,
        0,
        0,
        len(payload),
        len(pre),
        len(post),
        0x13,
        0,
        0,
        0,
    )
    return prefix + payload + bytes(decode.PAYLOAD_SIZE - len(payload)) + bytes(16)


class DecoderTest(unittest.TestCase):
    def test_schema_struct_sizes_are_exact(self) -> None:
        self.assertEqual(decode.HEADER.size, 64)
        self.assertEqual(decode.RECORD_PREFIX.size, 80)
        self.assertEqual(decode.MXCFB_UPDATE.size, 72)
        self.assertEqual(decode.MXCFB_MARKER.size, 8)
        self.assertEqual(decode.FB_VAR.size, 160)
        self.assertEqual(decode.FB_FIX.size, 68)
        self.assertEqual(len(make_record()), 416)

    def test_known_fixture_decodes_pre_and_post(self) -> None:
        data = make_header() + make_record()
        header = decode.parse_header(data)
        records = list(decode.iter_records(data, header))
        self.assertEqual(header.profile, 1)
        self.assertEqual(header.process_id, 314)
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["sequence"], 1)
        self.assertEqual(record["type"], "ioctl")
        self.assertEqual(record["request"], "0x4048462e")
        self.assertEqual(record["duration_ns"], 300)
        self.assertEqual(record["pre"]["update_marker"], 100)
        self.assertEqual(record["post"]["update_marker"], 101)
        self.assertEqual(record["pre"]["temperature"], -5)
        self.assertEqual(record["pre"]["alt_buffer"]["width"], 1404)

    def test_uncommitted_or_torn_slot_is_ignored(self) -> None:
        header = decode.parse_header(make_header() + make_record(commit=2, sequence=1))
        records = list(
            decode.iter_records(make_header() + make_record(commit=2, sequence=1), header)
        )
        self.assertEqual(records, [])

    def test_truncated_trace_is_rejected(self) -> None:
        with self.assertRaisesRegex(decode.TraceFormatError, "truncated"):
            decode.parse_header(make_header(capacity=2) + make_record())

    def test_cli_emits_json_document(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = pathlib.Path(directory) / "trace.bin"
            trace.write_bytes(make_header() + make_record())
            completed = subprocess.run(
                ["python3", str(DECODER_PATH), str(trace)],
                check=True,
                text=True,
                capture_output=True,
            )
        document = json.loads(completed.stdout)
        self.assertEqual(document["header"]["profile"], "remarkable1")
        self.assertEqual(document["records"][0]["post"]["update_marker"], 101)


if __name__ == "__main__":
    unittest.main()
