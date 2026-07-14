#!/usr/bin/env python3
"""Host-only safety tests for the stock-Xochitl capture orchestrator."""

from __future__ import annotations

import importlib.util
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "capture_xochitl_mapper.py"
SPEC = importlib.util.spec_from_file_location("capture_xochitl_mapper", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)
VALIDATOR_PATH = MODULE_PATH.with_name("validate_xochitl_capture.py")
VALIDATOR_SPEC = importlib.util.spec_from_file_location(
    "validate_xochitl_capture", VALIDATOR_PATH
)
assert VALIDATOR_SPEC is not None and VALIDATOR_SPEC.loader is not None
validator = importlib.util.module_from_spec(VALIDATOR_SPEC)
VALIDATOR_SPEC.loader.exec_module(validator)


class CaptureOrchestratorTest(unittest.TestCase):
    def test_breakpoint_sites_are_elf_mapped_and_byte_pinned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture"
            payload = bytearray(0x200)
            payload[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<Q", payload, 32, 64)
            struct.pack_into("<H", payload, 54, 56)
            struct.pack_into("<H", payload, 56, 1)
            struct.pack_into(
                "<IIQQQQQQ",
                payload,
                64,
                1,
                5,
                0,
                0x400000,
                0x400000,
                len(payload),
                len(payload),
                0x1000,
            )
            payload[0x100:0x104] = bytes.fromhex("01020304")
            path.write_bytes(payload)
            site = (("test", 0x400100, 0x100, "01020304"),)
            self.assertEqual(
                capture.verify_breakpoint_sites(path, site),
                {"0x00400100": "01020304"},
            )

            wrong_offset = (("test", 0x400100, 0x104, "01020304"),)
            with self.assertRaises(capture.CaptureError):
                capture.verify_breakpoint_sites(path, wrong_offset)
            wrong_bytes = (("test", 0x400100, 0x100, "01020305"),)
            with self.assertRaises(capture.CaptureError):
                capture.verify_breakpoint_sites(path, wrong_bytes)

    def test_gdb_script_deliberately_uses_software_breakpoints(self) -> None:
        script = MODULE_PATH.with_name("capture_xochitl_mapper.gdb").read_text()
        self.assertIn("set breakpoint auto-hw off", script)
        for _name, address, _offset, _instruction in capture.BREAKPOINT_SITES:
            self.assertIn(f"break *0x{address:08x}", script)
            self.assertNotIn(f"hbreak *0x{address:08x}", script)

    def test_validator_independently_pins_same_breakpoint_provenance(self) -> None:
        records = capture.breakpoint_site_records()
        instructions = {
            record["virtual_address"]: record["instruction_hex"]
            for record in records
        }
        self.assertEqual(validator.EXPECTED_BREAKPOINT_SITES, records)
        self.assertEqual(
            validator.EXPECTED_RESTORED_INSTRUCTIONS, instructions
        )

    def test_attach_shell_is_loopback_only_and_identity_bound(self) -> None:
        command = capture.attach_command(123, "a" * 64, 3456, 99)
        self.assertIn("127.0.0.1:3456", command)
        self.assertNotIn("0.0.0.0", command)
        self.assertIn("sleep 99", command)
        self.assertIn("gdbserver-cleanup-identity-changed", command)
        self.assertIn("server_start", command)
        parsed = subprocess.run(
            ["sh", "-n"], input=command, text=True, check=False
        )
        self.assertEqual(parsed.returncode, 0)

    def test_ssh_forward_fails_closed(self) -> None:
        command = capture.ssh_prefix(
            "root@10.11.99.1",
            local_forward="127.0.0.1:23456:127.0.0.1:2345",
        )
        self.assertEqual(command[-1], "root@10.11.99.1")
        self.assertIn("ExitOnForwardFailure=yes", command)
        self.assertIn("127.0.0.1:23456:127.0.0.1:2345", command)

    def test_remote_identity_requires_live_process(self) -> None:
        response = (
            "PID=41\nEXE=/usr/bin/xochitl\nSHA256=abc\nTRACER=0\n"
            "STATE=S\nSTART_TIME=123456\n"
        )
        with mock.patch.object(capture, "run_ssh", return_value=response):
            identity = capture.remote_identity("device")
        self.assertEqual(identity["pid"], 41)
        self.assertEqual(identity["start_time_ticks"], 123456)

        zombie = response.replace("STATE=S", "STATE=Z")
        with mock.patch.object(capture, "run_ssh", return_value=zombie):
            with self.assertRaises(capture.CaptureError):
                capture.remote_identity("device")

    def test_listener_requires_full_gdbserver_identity(self) -> None:
        process = subprocess.Popen(
            [
                "sh",
                "-c",
                "printf 'PLUTO_GDBSERVER_PID=77\\n"
                "PLUTO_GDBSERVER_EXE=/tmp/pluto-gdbserver-aarch64\\n"
                "PLUTO_GDBSERVER_START_TIME=987\\n"
                "Listening on port 2345\\n'; exec sleep 30",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            identity = capture.wait_until_listening(process, 2345, timeout=1)
        finally:
            process.terminate()
            process.communicate(timeout=2)
        self.assertEqual(
            identity,
            {
                "pid": 77,
                "exe": "/tmp/pluto-gdbserver-aarch64",
                "start_time_ticks": 987,
            },
        )

    def test_recovery_rejects_process_reuse(self) -> None:
        expected = {
            "pid": 41,
            "exe": "/usr/bin/xochitl",
            "remote_sha256": "abc",
            "start_time_ticks": 123456,
        }
        server = {
            "pid": 77,
            "exe": "/tmp/pluto-gdbserver-aarch64",
            "start_time_ticks": 987,
        }
        good = (
            "PID=41\nEXE=/usr/bin/xochitl\nSHA256=abc\nTRACER=0\n"
            "STATE=S\nSTART_TIME=123456\n"
            "CODE_004814A0=3f2303d5\n"
            "CODE_009ADBD0=3f2303d5\n"
            "CODE_009ADE2C=e0234239\n"
        )
        instructions = {
            capture.breakpoint_address_key(address): instruction
            for _name, address, _offset, instruction in capture.BREAKPOINT_SITES
        }
        with mock.patch.object(capture, "run_ssh", return_value=good) as run:
            recovered = capture.recover_and_verify(
                "device", expected, server, instructions
            )
        self.assertEqual(recovered["tracer_pid"], 0)
        self.assertEqual(recovered["restored_instruction_bytes"], instructions)
        recovery_shell = run.call_args.args[1]
        self.assertIn("unexpected-tracer", recovery_shell)
        self.assertIn("gdbserver-identity-changed", recovery_shell)
        self.assertIn("software-breakpoint-not-restored", recovery_shell)
        self.assertIn("/proc/$pid/mem", recovery_shell)
        self.assertIn("/usr/bin/hexdump", recovery_shell)
        parsed = subprocess.run(
            ["sh", "-n"], input=recovery_shell, text=True, check=False
        )
        self.assertEqual(parsed.returncode, 0)

        reused = good.replace("START_TIME=123456", "START_TIME=123457")
        with mock.patch.object(capture, "run_ssh", return_value=reused):
            with self.assertRaises(capture.CaptureError):
                capture.recover_and_verify(
                    "device", expected, server, instructions
                )

        missing_instruction = good.replace(
            "CODE_009ADE2C=e0234239\n", ""
        )
        with mock.patch.object(
            capture, "run_ssh", return_value=missing_instruction
        ):
            with self.assertRaises(capture.CaptureError):
                capture.recover_and_verify(
                    "device", expected, server, instructions
                )

        with mock.patch.object(capture, "run_ssh", return_value=good):
            with self.assertRaises(capture.CaptureError):
                capture.recover_and_verify("device", expected, server, {})


if __name__ == "__main__":
    unittest.main()
