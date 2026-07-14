#!/usr/bin/env python3
"""Host-only safety and contract tests for the disposable mapper oracle."""

from __future__ import annotations

import importlib.util
import json
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "run_xochitl_mapper_oracle.py"
)
SPEC = importlib.util.spec_from_file_location("run_xochitl_mapper_oracle", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
oracle = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = oracle
SPEC.loader.exec_module(oracle)


IMAGE = "ubuntu@sha256:" + "a" * 64


def descriptor(
    begin: int,
    size: int,
    stride: int,
    rectangle: tuple[int, int, int, int],
) -> bytes:
    result = bytearray(0x30)
    struct.pack_into("<QQQ", result, 0, begin, begin + size, begin + size)
    struct.pack_into("<iiii", result, 0x18, *rectangle)
    struct.pack_into("<Q", result, 0x28, stride)
    return bytes(result)


def make_elf_fixture(path: Path) -> oracle.BinaryPin:
    size = 4096
    blob = bytearray(size)
    blob[:16] = b"\x7fELF\x02\x01\x01\x03" + b"\0" * 8
    phoff = 64
    phentsize = 56
    phnum = 3
    entry = 0x1000
    struct.pack_into(
        "<HHIQQQIHHHHHH",
        blob,
        16,
        2,
        183,
        1,
        entry,
        phoff,
        0,
        0,
        64,
        phentsize,
        phnum,
        0,
        0,
        0,
    )
    # One synthetic RXW load segment covers the pinned direct-call addresses
    # in memory while only this 4 KiB fixture is file-backed.
    struct.pack_into(
        "<IIQQQQQQ",
        blob,
        phoff,
        1,
        7,
        0,
        0,
        0,
        size,
        0x02000000,
        0x1000,
    )
    interpreter = b"/lib/ld-linux-aarch64.so.1\0"
    interpreter_offset = 0x200
    blob[interpreter_offset : interpreter_offset + len(interpreter)] = interpreter
    struct.pack_into(
        "<IIQQQQQQ",
        blob,
        phoff + phentsize,
        3,
        4,
        interpreter_offset,
        interpreter_offset,
        0,
        len(interpreter),
        len(interpreter),
        1,
    )
    build_id = bytes.fromhex("0123456789abcdef0123456789abcdef01234567")
    note_offset = 0x240
    note = struct.pack("<III", 4, len(build_id), 3) + b"GNU\0" + build_id
    blob[note_offset : note_offset + len(note)] = note
    struct.pack_into(
        "<IIQQQQQQ",
        blob,
        phoff + 2 * phentsize,
        4,
        4,
        note_offset,
        note_offset,
        0,
        len(note),
        len(note),
        4,
    )
    range_start = 0x300
    range_end = 0x340
    blob[range_start:range_end] = bytes(range(range_end - range_start))
    path.write_bytes(blob)
    return oracle.BinaryPin(
        size=size,
        sha256=oracle.sha256_file(path),
        build_id=build_id.hex(),
        entry=entry,
        range_start=range_start,
        range_end=range_end,
        range_offset=range_start,
        range_sha256=oracle.hashlib.sha256(blob[range_start:range_end]).hexdigest(),
    )


class MapperOracleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.scratch.name)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def test_pins_are_the_static_back_slice_contract(self) -> None:
        self.assertEqual(
            oracle.XOCHITL_PIN.sha256,
            "4646e0aef1cef2b3417889073ad5faba9259ae6b41f68326e75ef9a5c520c322",
        )
        self.assertEqual(
            oracle.XOCHITL_PIN.build_id,
            "f04525824e27e75d7a579b18c4007a3a76384789",
        )
        self.assertEqual(
            (
                oracle.XOCHITL_PIN.range_start,
                oracle.XOCHITL_PIN.range_end,
                oracle.XOCHITL_PIN.range_offset,
                oracle.XOCHITL_PIN.range_sha256,
            ),
            (
                0x4814A0,
                0x483B30,
                0x814A0,
                "3526e104129db479e5218f5f54a9fed2d7b655a6a8632b9d0868f54dfa0859fc",
            ),
        )
        self.assertEqual(oracle.MAIN_READY, 0x483B34)
        self.assertEqual(oracle.POST_STORE, 0x483280)
        self.assertEqual(oracle.FAST_DISPATCHER_ENTRY, 0x9AF7C0)
        self.assertEqual(oracle.AB_DESCRIPTOR, 0x1A18FD8)

    def test_elf_build_id_and_mapper_range_reject_deterministically(self) -> None:
        fixture = self.root / "xochitl-fixture"
        pin = make_elf_fixture(fixture)
        record = oracle.verify_xochitl(fixture, pin)
        self.assertEqual(record["build_id"], pin.build_id)
        self.assertEqual(record["mapper_range"]["sha256"], pin.range_sha256)

        wrong_build = oracle.dataclasses.replace(pin, build_id="00" * 20)
        with self.assertRaisesRegex(oracle.OracleError, "Build ID mismatch"):
            oracle.verify_xochitl(fixture, wrong_build)

        data = bytearray(fixture.read_bytes())
        data[pin.range_start] ^= 0xFF
        fixture.write_bytes(data)
        range_tamper = oracle.dataclasses.replace(
            pin, sha256=oracle.sha256_file(fixture)
        )
        with self.assertRaisesRegex(oracle.OracleError, "mapper range SHA-256 mismatch"):
            oracle.verify_xochitl(fixture, range_tamper)

    def test_one_and_two_row_layouts_are_exact_and_aligned(self) -> None:
        one = oracle.FixtureLayout.for_rows(1)
        two = oracle.FixtureLayout.for_rows(2)
        self.assertEqual(
            (
                one.storage_rows,
                one.ct33_bytes,
                one.ab_bytes,
                one.output_bytes,
                one.arena_bytes,
            ),
            (3, 24, 96, 96, 0xCC0),
        )
        self.assertEqual(
            (
                two.storage_rows,
                two.ct33_bytes,
                two.ab_bytes,
                two.output_bytes,
                two.arena_bytes,
            ),
            (2, 16, 64, 64, 0xC70),
        )
        self.assertEqual(one.arena_bytes & 0xF, 0)
        self.assertEqual(two.arena_bytes & 0xF, 0)
        with self.assertRaises(oracle.OracleError):
            oracle.FixtureLayout.for_rows(3)

    def test_panel_layout_uses_exact_production_planes_and_output_formula(self) -> None:
        layout = oracle.FixtureLayout.for_panel(953, 1688, 7, 8)
        self.assertEqual(layout.profile, "panel")
        self.assertEqual(
            (
                layout.source_right,
                layout.source_bottom,
                layout.source_stride,
                layout.ct33_bytes,
            ),
            (959, 1695, 960, 960 * 1696),
        )
        self.assertEqual(
            (
                layout.ab_right,
                layout.ab_bottom,
                layout.ab_stride,
                layout.ab_bytes,
            ),
            (959, 1695, 968, 968 * 1698 * 4),
        )
        self.assertEqual(
            (
                layout.update_left,
                layout.update_top,
                layout.update_right,
                layout.update_bottom,
                layout.output_stride,
                layout.output_bytes,
            ),
            (953, 1688, 959, 1695, 16, 2 * 10 * 16),
        )
        self.assertEqual(layout.arena_bytes & 0xF, 0)
        for invalid in ((-1, 0, 1, 1), (0, 0, 0, 1), (959, 0, 2, 1)):
            with self.assertRaises(oracle.OracleError):
                oracle.FixtureLayout.for_panel(*invalid)

    def test_input_sizes_fail_closed(self) -> None:
        exact = self.root / "delta.bin"
        exact.write_bytes(b"d" * oracle.DELTA_BYTES)
        record = oracle.verify_input(exact, oracle.DELTA_BYTES, "delta")
        self.assertEqual(record["size"], oracle.DELTA_BYTES)
        self.assertEqual(len(record["sha256"]), 64)

        short = self.root / "short.bin"
        short.write_bytes(b"d" * (oracle.DELTA_BYTES - 1))
        with self.assertRaisesRegex(oracle.OracleError, "exactly 2048 bytes"):
            oracle.verify_input(short, oracle.DELTA_BYTES, "delta")
        link = self.root / "link.bin"
        link.symlink_to(exact.name)
        with self.assertRaisesRegex(oracle.OracleError, "non-symlink"):
            oracle.verify_input(link, oracle.DELTA_BYTES, "delta")

    def test_container_commands_have_no_network_device_or_attach_path(self) -> None:
        docker = Path("/usr/local/bin/docker")
        xochitl = Path("/private/tmp/xochitl")
        usr_lib = Path("/private/tmp/usr-lib")
        gdbserver = Path("/private/tmp/gdbserver")
        name = "pluto-xochitl-oracle-test"
        debug = oracle.debugger_container_command(
            docker, IMAGE, xochitl, usr_lib, gdbserver, name
        )
        joined = " ".join(debug)
        self.assertIn("--network none", joined)
        self.assertIn("--read-only", debug)
        self.assertIn("--pull=never", debug)
        self.assertIn("--cap-drop ALL", joined)
        self.assertIn("--cap-add SYS_PTRACE", joined)
        self.assertIn("--interactive", debug)
        self.assertNotIn("--privileged", debug)
        self.assertNotIn("--device", debug)
        self.assertNotIn("ssh", joined.lower())
        self.assertNotIn("--attach", debug)
        self.assertNotIn("127.0.0.1", joined)
        self.assertEqual(
            debug[-7:],
            [
                "--once",
                "stdio",
                "/oracle/usr-lib/ld-linux-aarch64.so.1",
                "--inhibit-cache",
                "--library-path",
                "/oracle/usr-lib",
                "/oracle/xochitl",
            ],
        )

        loader = oracle.loader_list_command(
            docker,
            IMAGE,
            xochitl,
            usr_lib,
            gdbserver,
            "pluto-xochitl-closure-test",
        )
        self.assertIn("--network none", " ".join(loader))
        self.assertNotIn("--cap-add", loader)
        self.assertNotIn("--interactive", loader)
        self.assertEqual(loader[-2:], ["--list", "/oracle/xochitl"])

    def test_image_reference_and_inspection_are_immutable_arm64(self) -> None:
        oracle.verify_image_reference(IMAGE)
        for invalid in ("ubuntu:24.04", "sha256:" + "a" * 64, IMAGE.upper()):
            with self.assertRaises(oracle.OracleError):
                oracle.verify_image_reference(invalid)

        completed = mock.Mock(
            returncode=0,
            stdout=json.dumps(
                [
                    {
                        "Architecture": "arm64",
                        "Os": "linux",
                        "Id": "sha256:" + "b" * 64,
                    }
                ]
            ),
            stderr="",
        )
        with mock.patch.object(oracle.subprocess, "run", return_value=completed) as run:
            record = oracle.inspect_container_image(Path("/docker"), IMAGE)
        self.assertEqual(record["architecture"], "arm64")
        self.assertEqual(run.call_args.args[0], ["/docker", "image", "inspect", IMAGE])

    def test_cleanup_targets_only_the_named_disposable_container(self) -> None:
        present = mock.Mock(returncode=0, stdout="abc123\n", stderr="")
        removed = mock.Mock(returncode=0, stdout="abc123\n", stderr="")
        absent = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(
            oracle.subprocess, "run", side_effect=(present, removed, absent)
        ) as run:
            oracle.prove_container_absent(
                Path("/docker"), "pluto-xochitl-oracle-test"
            )
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(
            commands[1],
            [
                "/docker",
                "container",
                "rm",
                "--force",
                "pluto-xochitl-oracle-test",
            ],
        )
        self.assertEqual(commands[0], commands[2])
        self.assertIn("name=^/pluto-xochitl-oracle-test$", commands[0])

    def test_gdb_command_uses_stdio_pipe_and_exact_layout_values(self) -> None:
        layout = oracle.FixtureLayout.for_rows(2)
        container = oracle.debugger_container_command(
            Path("/docker"),
            IMAGE,
            Path("/xochitl"),
            Path("/usr-lib"),
            Path("/gdbserver"),
            "pluto-xochitl-oracle-test",
        )
        command = oracle.build_gdb_command(
            Path("/gdb"),
            Path("/xochitl"),
            Path("/usr-lib"),
            Path("/oracle.gdb"),
            container,
            layout,
        )
        joined = "\n".join(command)
        self.assertIn("target remote | /docker run", joined)
        self.assertIn("set $oracle_rows = 2", command)
        self.assertIn("set $oracle_storage_rows = 2", command)
        self.assertIn("set $oracle_split_row = -1", command)
        self.assertIn("set $oracle_split_reverse = 0", command)
        self.assertIn("set $oracle_kind = 0", command)
        self.assertIn("set $oracle_ct33_bytes = 16", command)
        self.assertIn("set $oracle_ab_bytes = 64", command)
        self.assertIn("set $oracle_output_bytes = 64", command)
        self.assertIn("set $oracle_palette_offset = 400", command)
        self.assertIn("set $oracle_delta_offset = 544", command)
        self.assertIn("set $oracle_ct33_offset = 2720", command)
        self.assertIn("set $oracle_ab_offset = 2864", command)
        self.assertIn("set $oracle_output_offset = 3056", command)
        self.assertIn("set $oracle_redzone_bytes = 64", command)
        self.assertIn("set $oracle_arena_bytes = 3184", command)
        self.assertNotIn("target remote 127", joined)

        panel = oracle.FixtureLayout.for_panel(64, 64, 8, 4)
        split = oracle.build_gdb_command(
            Path("/gdb"),
            Path("/xochitl"),
            Path("/usr-lib"),
            Path("/oracle.gdb"),
            container,
            panel,
            split_row=66,
            split_reverse=True,
        )
        self.assertIn("set $oracle_split_row = 66", split)
        self.assertIn("set $oracle_split_reverse = 1", split)
        self.assertIn("set $oracle_y_first = 64", split)
        self.assertIn("set $oracle_y_last = 67", split)

        fast = oracle.build_gdb_command(
            Path("/gdb"),
            Path("/xochitl"),
            Path("/usr-lib"),
            Path("/oracle.gdb"),
            container,
            panel,
            mode7_sequence=True,
            temperature_c=38.25,
        )
        self.assertIn("set $oracle_kind = 1", fast)
        self.assertIn("set $oracle_temperature_c = 38.25", fast)

        for sequence, kind in oracle.BRIDGE_SEQUENCE_KINDS.items():
            bridge = oracle.build_gdb_command(
                Path("/gdb"),
                Path("/xochitl"),
                Path("/usr-lib"),
                Path("/oracle.gdb"),
                container,
                panel,
                temperature_c=25.0,
                bridge_sequence=sequence,
            )
            self.assertIn(f"set $oracle_kind = {kind}", bridge)
        with self.assertRaisesRegex(oracle.OracleError, "mutually exclusive"):
            oracle.build_gdb_command(
                Path("/gdb"),
                Path("/xochitl"),
                Path("/usr-lib"),
                Path("/oracle.gdb"),
                container,
                panel,
                mode7_sequence=True,
                bridge_sequence="fast-legacy",
            )

    def test_mode7_scalar_sequence_matches_cold_source_and_continuation(self) -> None:
        layout = oracle.FixtureLayout.for_rows(2)
        raw = bytearray(layout.ct33_bytes)
        raw[:8] = bytes((0, 7, 0, 7, 0, 7, 0, 7))
        raw[8:16] = bytes((7, 0, 7, 0, 7, 0, 7, 0))
        ab = bytearray(layout.ab_bytes)
        for index in range(16):
            struct.pack_into("<HH", ab, index * 4, 2, 0)

        ab_source, out_source, ab_cont, out_cont = oracle._simulate_mode7_sequence(
            layout, bytes(raw), bytes(ab), 25.0
        )

        # Dark same-group lanes stay at 2 and have no countdown.  White lanes
        # cross groups, enter physical 28, and initialize cold countdown 3.
        self.assertEqual(struct.unpack_from("<HH", ab_source, 0), (2, 0))
        self.assertEqual(struct.unpack_from("<H", out_source, 0)[0], 2 * 32 + 2)
        self.assertEqual(struct.unpack_from("<HH", ab_source, 4), (28, 0x0903))
        self.assertEqual(struct.unpack_from("<H", out_source, 2)[0], 2 * 32 + 28)
        # First null-source continuation advances white 28->30 and flags 3->2.
        self.assertEqual(struct.unpack_from("<HH", ab_cont, 4), (30, 0x1202))
        self.assertEqual(struct.unpack_from("<H", out_cont, 2)[0], 28 * 32 + 30)
        self.assertEqual(oracle._fast_thermal(37.9999999), (704, 2016, 2))
        self.assertEqual(oracle._fast_thermal(37.999998), (576, 3456, 3))

    def test_composed_legacy_fast_legacy_scalar_uses_each_physical_prestate(self) -> None:
        layout = oracle.FixtureLayout.for_rows(2)
        palette = bytes((2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 30, 32, 32, 32, 32))
        raw = bytearray(layout.ct33_bytes)
        raw[:8] = bytes(range(8))
        raw[8:16] = bytes(reversed(range(8)))
        initial_ab = bytes(layout.ab_bytes)
        delta = bytes(oracle.DELTA_BYTES)

        legacy_ab, legacy_output = oracle._simulate_legacy_operation(
            layout, bytes(raw), initial_ab, palette, delta
        )
        self.assertEqual(
            list(struct.unpack_from("<8H", legacy_output)), list(palette[:8])
        )
        self.assertEqual(struct.unpack_from("<HH", legacy_ab, 7 * 4), (28, 0))

        fast_ab, fast_output, continuation_ab, _ = oracle._simulate_mode7_sequence(
            layout, bytes(raw), legacy_ab, 25.0
        )
        self.assertEqual(struct.unpack_from("<HH", fast_ab, 0), (2, 0))
        self.assertEqual(struct.unpack_from("<HH", fast_ab, 4), (2, 3))
        self.assertEqual(struct.unpack_from("<HH", fast_ab, 7 * 4), (28, 0))
        self.assertEqual(struct.unpack_from("<H", fast_output, 2)[0], 12 * 32 + 2)
        self.assertEqual(oracle._mode7_pending_expected(layout, fast_ab), 1)
        self.assertNotEqual(continuation_ab, fast_ab)

        final_ab, final_output = oracle._simulate_legacy_operation(
            layout, bytes(raw), fast_ab, palette, delta
        )
        self.assertEqual(struct.unpack_from("<H", final_output, 2)[0], 2 * 32 + 12)
        self.assertEqual(struct.unpack_from("<HH", final_ab, 4), (12, 0))

    def test_loader_closure_is_hashed_and_cannot_escape_firmware(self) -> None:
        usr_lib = self.root / "usr-lib"
        usr_lib.mkdir()
        (usr_lib / "libfixture.so").write_bytes(b"fixture")
        (usr_lib / "libc.so.6").write_bytes(b"libc")
        output = "\n".join(
            (
                "libfixture.so => /oracle/usr-lib/libfixture.so (0x1)",
                "libc.so.6 => /oracle/usr-lib/libc.so.6 (0x2)",
                "/lib/ld-linux-aarch64.so.1 => "
                "/oracle/usr-lib/ld-linux-aarch64.so.1 (0x3)",
            )
        )
        (usr_lib / "ld-linux-aarch64.so.1").write_bytes(b"loader")
        records = oracle.verify_runtime_closure(
            output,
            {"needed": ["libfixture.so", "libc.so.6"]},
            usr_lib.resolve(),
        )
        self.assertEqual(len(records), 3)
        self.assertTrue(all(len(record["sha256"]) == 64 for record in records))

        escaped = output.replace(
            "/oracle/usr-lib/libfixture.so", "/usr/lib/libfixture.so"
        )
        with self.assertRaisesRegex(oracle.OracleError, "outside firmware"):
            oracle.verify_runtime_closure(
                escaped,
                {"needed": ["libfixture.so", "libc.so.6"]},
                usr_lib.resolve(),
            )
        escaped_interpreter = output.replace(
            "/oracle/usr-lib/ld-linux-aarch64.so.1",
            "/lib/ld-linux-aarch64.so.1",
        )
        with self.assertRaisesRegex(oracle.OracleError, "outside firmware"):
            oracle.verify_runtime_closure(
                escaped_interpreter,
                {"needed": ["libfixture.so", "libc.so.6"]},
                usr_lib.resolve(),
            )
        bare_host_interpreter = output.replace(
            "/lib/ld-linux-aarch64.so.1 => "
            "/oracle/usr-lib/ld-linux-aarch64.so.1",
            "/lib/ld-linux-aarch64.so.1",
        )
        with self.assertRaisesRegex(oracle.OracleError, "outside firmware"):
            oracle.verify_runtime_closure(
                bare_host_interpreter,
                {"needed": ["libfixture.so", "libc.so.6"]},
                usr_lib.resolve(),
            )
        with self.assertRaisesRegex(oracle.OracleError, "unresolved"):
            oracle.verify_runtime_closure(
                output + "\nlibmissing.so => not found\n",
                {"needed": ["libfixture.so", "libc.so.6"]},
                usr_lib.resolve(),
            )

    def test_output_validator_checks_markers_sizes_pointers_and_restore(self) -> None:
        layout = oracle.FixtureLayout.for_rows(1)
        base = 0x100000
        src = base + 0xB0
        wave = src + 0x30
        outdesc = wave + 0x40
        palette = base + layout.palette_offset
        delta = base + layout.delta_offset
        ct33 = base + layout.ct33_offset
        ab = base + layout.ab_offset
        output = base + layout.output_offset
        self.assertLessEqual(
            output + layout.output_bytes + oracle.REDZONE_BYTES - base,
            layout.arena_bytes,
        )

        context = bytearray(oracle.CTX_BYTES)
        struct.pack_into("<Q", context, 0x00, src)
        struct.pack_into("<Q", context, 0x10, ct33)
        struct.pack_into(
            "<iiii", context, 0x18, 0, 0, 7, layout.storage_rows - 1
        )
        struct.pack_into("<Q", context, 0x28, 8)
        struct.pack_into("<Q", context, 0x30, 8)
        struct.pack_into("<iiii", context, 0x38, 0, 0, 0, 0)
        struct.pack_into("<Q", context, 0x58, wave)
        struct.pack_into("<Q", context, 0x70, outdesc)
        (self.root / "oracle.ctx.bin").write_bytes(context)
        (self.root / "oracle.srcdesc.bin").write_bytes(
            descriptor(
                ct33,
                layout.ct33_bytes,
                8,
                (0, 0, 7, layout.storage_rows - 1),
            )
        )
        wave_bytes = bytearray(oracle.WAVE_DESCRIPTOR_BYTES)
        struct.pack_into("<Q", wave_bytes, 0x30, delta)
        (self.root / "oracle.wavedesc.bin").write_bytes(wave_bytes)
        (self.root / "oracle.outdesc.bin").write_bytes(
            descriptor(output, layout.output_bytes, 16, (0, 0, 0, 0))
        )
        (self.root / "oracle.abdesc.synthetic.bin").write_bytes(
            descriptor(
                ab,
                layout.ab_bytes,
                8,
                (0, 0, 7, layout.storage_rows - 1),
            )
        )
        original = bytes(range(oracle.AB_DESCRIPTOR_BYTES))
        (self.root / "oracle.abdesc.original.bin").write_bytes(original)
        (self.root / "oracle.abdesc.restored.bin").write_bytes(original)

        fixtures = {
            "palette": bytes(range(oracle.PALETTE_BYTES)),
            "ct33": bytes(range(layout.ct33_bytes)),
            "delta": (b"delta" * 410)[: oracle.DELTA_BYTES],
            "ab": bytes(range(layout.ab_bytes)),
        }
        pairs = {
            "palette": ("oracle.palette.input.bin", "oracle.palette.loaded.bin"),
            "ct33": ("oracle.ct33.input.bin", "oracle.ct33.loaded.bin"),
            "delta": ("oracle.delta.input.bin", "oracle.delta.loaded.bin"),
            "ab": ("oracle.ab.input.bin", "oracle.ab.before.loaded.bin"),
        }
        for label, names in pairs.items():
            for name in names:
                (self.root / name).write_bytes(fixtures[label])
        (self.root / "oracle.output.after.bin").write_bytes(
            b"o" * layout.output_bytes
        )
        (self.root / "oracle.ab.after.bin").write_bytes(b"a" * layout.ab_bytes)
        (self.root / "oracle.redzone.input.bin").write_bytes(
            oracle.REDZONE_PATTERN
        )
        for name in oracle.BUFFER_NAMES:
            for side in ("pre", "post"):
                (self.root / f"oracle.redzone.{name}.{side}.bin").write_bytes(
                    oracle.REDZONE_PATTERN
                )
        (self.root / "oracle.gdb.log").write_text(
            "\n".join(
                (
                    "ORACLE_MAIN_READY pc=0x483b34",
                    "ORACLE_CALL_BEGIN entry=0x004814a0 "
                    f"ctx=0x{base:x} palette=0x{palette:x} "
                    "rows=0..0 split=-1 reverse=0 x4=0",
                    "ORACLE_POST_STORE pc=0x483280 hit=1 "
                    f"output=0x{output:x} bytes=0x{layout.output_bytes:x} "
                    f"ab=0x{ab:x} bytes=0x{layout.ab_bytes:x}",
                    "ORACLE_MAPPER_COMPLETE entry=0x004814a0 post_hits=1 "
                    "disposition=post-store-kill",
                    "ORACLE_COMPLETE rows=1 x4=0 inferior_disposition=kill",
                )
            )
            + "\n",
            encoding="utf-8",
        )

        result = oracle.validate_outputs(self.root, layout)
        self.assertEqual(result["markers"], list(oracle.MARKERS))
        self.assertEqual(
            result["dumps"]["oracle.output.after.bin"]["size"],
            layout.output_bytes,
        )
        self.assertNotEqual(
            (self.root / "oracle.ab.input.bin").read_bytes(),
            (self.root / "oracle.ab.after.bin").read_bytes(),
        )

        (self.root / "oracle.ab.before.loaded.bin").write_bytes(
            b"z" * layout.ab_bytes
        )
        with self.assertRaisesRegex(oracle.OracleError, "inferior memory differs"):
            oracle.validate_outputs(self.root, layout)
        (self.root / "oracle.ab.before.loaded.bin").write_bytes(fixtures["ab"])

        damaged_redzone = self.root / "oracle.redzone.output.post.bin"
        damaged_redzone.write_bytes(b"x" + oracle.REDZONE_PATTERN[1:])
        with self.assertRaisesRegex(oracle.OracleError, "redzone was modified"):
            oracle.validate_outputs(self.root, layout)
        damaged_redzone.write_bytes(oracle.REDZONE_PATTERN)

        (self.root / "oracle.ab.after.bin").write_bytes(fixtures["ab"])
        with self.assertRaisesRegex(oracle.OracleError, "no A/B transition"):
            oracle.validate_outputs(self.root, layout)
        (self.root / "oracle.ab.after.bin").write_bytes(b"a" * layout.ab_bytes)

        (self.root / "oracle.output.after.bin").write_bytes(
            b"\0" * layout.output_bytes
        )
        with self.assertRaisesRegex(oracle.OracleError, "all-zero output"):
            oracle.validate_outputs(self.root, layout)
        (self.root / "oracle.output.after.bin").write_bytes(
            b"o" * layout.output_bytes
        )

        (self.root / "oracle.abdesc.restored.bin").write_bytes(b"x" * 0x30)
        with self.assertRaisesRegex(oracle.OracleError, "not restored"):
            oracle.validate_outputs(self.root, layout)

    def test_gdb_script_contains_exact_call_boundaries_and_kill(self) -> None:
        script = MODULE_PATH.with_name("xochitl_mapper_oracle.gdb").read_text()
        self.assertIn("hbreak *0x00483b34", script)
        self.assertIn("hbreak *0x00483280", script)
        self.assertIn("set scheduler-locking on", script)
        self.assertIn("set $oracle_active_first = $oracle_y_first", script)
        self.assertIn("set $w2 = $oracle_active_first", script)
        self.assertIn("set $w3 = $oracle_active_last", script)
        self.assertIn("set $x4 = 0", script)
        self.assertIn("set $x30 = 0x00483b34", script)
        self.assertIn("set $pc = 0x004814a0", script)
        self.assertNotIn("call ((void (*)", script)
        self.assertIn("restore oracle.abdesc.original.bin binary 0x01a18fd8", script)
        self.assertIn("ORACLE_MAPPER_COMPLETE", script)
        self.assertIn("ORACLE_COMPLETE", script)
        self.assertIn("set $pc = 0x009af7c0", script)
        self.assertIn("ORACLE_FAST_SOURCE_BEGIN", script)
        self.assertIn("ORACLE_FAST_CONTINUATION_BEGIN", script)
        self.assertIn("ORACLE_FAST_SEQUENCE_COMPLETE", script)
        self.assertIn("ORACLE_BRIDGE_LEGACY_BEFORE_FAST_BEGIN", script)
        self.assertIn("ORACLE_BRIDGE_FAST_SOURCE_BEGIN", script)
        self.assertIn("ORACLE_BRIDGE_FAST_CONTINUATION_BEGIN", script)
        self.assertIn("ORACLE_BRIDGE_LEGACY_AFTER_FAST_BEGIN", script)
        self.assertIn("ORACLE_BRIDGE_COMPLETE", script)
        self.assertIn("set {unsigned char}($ctx+0xaa) = 0", script)
        self.assertIn("restore oracle.redzone.input.bin binary", script)
        self.assertIn("oracle.redzone.output.post.bin", script)
        self.assertLess(
            script.index("dump binary memory oracle.ab.before.loaded.bin"),
            script.index("ORACLE_CALL_BEGIN"),
        )
        self.assertRegex(script, r"(?m)^\s*kill$")
        self.assertNotIn("target remote", script)
        self.assertNotIn("attach", script.lower())
        self.assertNotIn("ssh", script.lower())

    def test_exact_local_artifacts_when_available(self) -> None:
        xochitl = Path("/private/tmp/xochitl-3.27.1.0")
        if not xochitl.is_file():
            self.skipTest("exact offline Xochitl artifact is not present")
        record = oracle.verify_xochitl(xochitl)
        self.assertEqual(record["build_id"], oracle.XOCHITL_PIN.build_id)
        self.assertEqual(
            record["mapper_range"]["sha256"], oracle.XOCHITL_PIN.range_sha256
        )

        gdbserver = MODULE_PATH.parents[4] / "build/device-tools/pluto-gdbserver-aarch64"
        if gdbserver.is_file():
            server = oracle.verify_gdbserver(gdbserver)
            self.assertEqual(server["build_id"], oracle.EXPECTED_GDBSERVER_BUILD_ID)

        rootfs = Path("/private/tmp/rm-fw-3.27.1.0-usr-lib-offline-oracle-v3")
        if rootfs.is_dir():
            _, firmware = oracle.verify_rootfs(rootfs)
            self.assertEqual(
                firmware["tree"]["sha256"],
                oracle.EXPECTED_USR_LIB_TREE["sha256"],
            )


if __name__ == "__main__":
    unittest.main()
