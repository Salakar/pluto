#!/usr/bin/env python3
"""Orchestrate one fail-closed stock Xochitl mapper capture over USB SSH."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import selectors
import shlex
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


EXPECTED_XOCHITL_SHA256 = (
    "4646e0aef1cef2b3417889073ad5faba9259ae6b41f68326e75ef9a5c520c322"
)
EXPECTED_XOCHITL_BUILD_ID = "f04525824e27e75d7a579b18c4007a3a76384789"
EXPECTED_GDBSERVER_SHA256 = (
    "f5154a1d16d577c90d794199a2bacf66954e6306e4b09281fb7ca1ecaa2fe8be"
)
LIVE_PROCESS_STATES = {"R", "S", "D", "I"}
BREAKPOINT_SITES: tuple[tuple[str, int, int, str], ...] = (
    ("mapper", 0x004814A0, 0x000814A0, "3f2303d5"),
    ("pre_worker", 0x009ADBD0, 0x005ADBD0, "3f2303d5"),
    ("post_worker", 0x009ADE2C, 0x005ADE2C, "e0234239"),
)


class CaptureError(RuntimeError):
    pass


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def breakpoint_address_key(address: int) -> str:
    return f"0x{address:08x}"


def breakpoint_site_records() -> list[dict[str, Any]]:
    return [
        {
            "name": name,
            "virtual_address": breakpoint_address_key(address),
            "file_offset": f"0x{file_offset:08x}",
            "instruction_hex": instruction_hex,
        }
        for name, address, file_offset, instruction_hex in BREAKPOINT_SITES
    ]


def verify_breakpoint_sites(
    path: Path,
    sites: tuple[tuple[str, int, int, str], ...] = BREAKPOINT_SITES,
) -> dict[str, str]:
    """Pin each software-breakpoint address to its ELF byte provenance."""
    size = path.stat().st_size
    with path.open("rb") as stream:
        elf_header = stream.read(64)
        if (
            len(elf_header) != 64
            or elf_header[:4] != b"\x7fELF"
            or elf_header[4] != 2
            or elf_header[5] != 1
        ):
            raise CaptureError("local Xochitl is not a little-endian ELF64 file")
        program_offset = struct.unpack_from("<Q", elf_header, 32)[0]
        program_size = struct.unpack_from("<H", elf_header, 54)[0]
        program_count = struct.unpack_from("<H", elf_header, 56)[0]
        if (
            program_size < 56
            or program_count == 0
            or program_offset > size
            or program_count > (size - program_offset) // program_size
        ):
            raise CaptureError("local Xochitl has an invalid program-header table")
        load_segments: list[tuple[int, int, int]] = []
        for index in range(program_count):
            stream.seek(program_offset + index * program_size)
            header = stream.read(56)
            if len(header) != 56:
                raise CaptureError("local Xochitl program header is truncated")
            kind, _flags, offset, virtual, _physical, file_size, _memory_size, _align = (
                struct.unpack("<IIQQQQQQ", header)
            )
            if kind == 1:
                load_segments.append((virtual, offset, file_size))

        verified: dict[str, str] = {}
        for name, address, pinned_offset, expected_hex in sites:
            matches = [
                offset + address - virtual
                for virtual, offset, file_size in load_segments
                if virtual <= address and address + 4 <= virtual + file_size
            ]
            if matches != [pinned_offset]:
                raise CaptureError(
                    f"{name} breakpoint address/file offset mismatch: {matches}"
                )
            if pinned_offset > size - 4:
                raise CaptureError(f"{name} breakpoint instruction is out of file")
            stream.seek(pinned_offset)
            actual_hex = stream.read(4).hex()
            if actual_hex != expected_hex:
                raise CaptureError(
                    f"{name} breakpoint instruction mismatch: {actual_hex}"
                )
            verified[breakpoint_address_key(address)] = actual_hex
    return verified


def ssh_prefix(device: str, *, local_forward: str | None = None) -> list[str]:
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "StrictHostKeyChecking=yes",
    ]
    if local_forward is not None:
        command.extend(
            ["-o", "ExitOnForwardFailure=yes", "-L", local_forward]
        )
    command.append(device)
    return command


def run_ssh(
    device: str,
    command: str,
    *,
    input_bytes: bytes | None = None,
    timeout: int = 15,
) -> str:
    result = subprocess.run(
        [*ssh_prefix(device), command],
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    output = result.stdout.decode("utf-8", errors="replace")
    if result.returncode != 0:
        raise CaptureError(
            f"SSH command failed ({result.returncode}): {command}\n{output}"
        )
    return output


def parse_key_values(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def remote_identity(device: str) -> dict[str, Any]:
    command = r"""
set -- $(pidof xochitl)
if [ "$#" -ne 1 ]; then
  echo "ERROR=expected-one-xochitl-pid"
  exit 41
fi
pid="$1"
exe=$(readlink -f "/proc/$pid/exe") || exit 42
sum=$(sha256sum "/proc/$pid/exe") || exit 43
sum=${sum%% *}
tracer=$(awk '/^TracerPid:/{print $2}' "/proc/$pid/status") || exit 44
state=$(awk '/^State:/{print $2}' "/proc/$pid/status") || exit 45
start=$(awk '{print $22}' "/proc/$pid/stat") || exit 46
printf 'PID=%s\nEXE=%s\nSHA256=%s\nTRACER=%s\nSTATE=%s\nSTART_TIME=%s\n' \
  "$pid" "$exe" "$sum" "$tracer" "$state" "$start"
""".strip()
    values = parse_key_values(run_ssh(device, command))
    try:
        pid = int(values["PID"])
        tracer = int(values["TRACER"])
        start_time = int(values["START_TIME"])
    except (KeyError, ValueError) as error:
        raise CaptureError(f"invalid remote identity response: {values}") from error
    state = values.get("STATE", "")
    if pid <= 0 or tracer < 0 or start_time <= 0 or state not in LIVE_PROCESS_STATES:
        raise CaptureError(f"invalid or non-live remote identity: {values}")
    return {
        "pid": pid,
        "exe": values.get("EXE", ""),
        "remote_sha256": values.get("SHA256", ""),
        "tracer_pid": tracer,
        "state": state,
        "start_time_ticks": start_time,
    }


def verify_local_artifacts(
    xochitl: Path, gdbserver: Path
) -> tuple[str, str, dict[str, str]]:
    if not xochitl.is_file() or not gdbserver.is_file():
        raise CaptureError("local Xochitl or gdbserver artifact is missing")
    xochitl_sha = digest(xochitl)
    server_sha = digest(gdbserver)
    if xochitl_sha != EXPECTED_XOCHITL_SHA256:
        raise CaptureError(f"local Xochitl SHA-256 mismatch: {xochitl_sha}")
    if server_sha != EXPECTED_GDBSERVER_SHA256:
        raise CaptureError(f"local gdbserver SHA-256 mismatch: {server_sha}")
    file_output = subprocess.run(
        ["file", str(xochitl)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    ).stdout
    if EXPECTED_XOCHITL_BUILD_ID not in file_output:
        raise CaptureError("local Xochitl Build ID mismatch")
    breakpoint_bytes = verify_breakpoint_sites(xochitl)
    return xochitl_sha, server_sha, breakpoint_bytes


def stage_gdbserver(device: str, gdbserver: Path) -> None:
    run_ssh(
        device,
        "cat > /tmp/pluto-gdbserver-aarch64",
        input_bytes=gdbserver.read_bytes(),
        timeout=30,
    )
    output = run_ssh(
        device,
        "chmod 0755 /tmp/pluto-gdbserver-aarch64 && "
        "sha256sum /tmp/pluto-gdbserver-aarch64",
    )
    if EXPECTED_GDBSERVER_SHA256 not in output:
        raise CaptureError("staged gdbserver hash mismatch")


def attach_command(
    pid: int, expected_sha: str, remote_port: int, watchdog_seconds: int
) -> str:
    pid_text = shlex.quote(str(pid))
    sha_text = shlex.quote(expected_sha)
    return f"""
set -- $(pidof xochitl)
[ "$#" -eq 1 ] || exit 51
[ "$1" = {pid_text} ] || exit 52
sum=$(sha256sum "/proc/$1/exe") || exit 53
sum=${{sum%% *}}
[ "$sum" = {sha_text} ] || exit 54
server=''
server_exe=''
server_start=''
server_attested=0
watchdog=''
watchdog_start=''
terminate_server_if_same() {{
  [ -n "$server" ] || return 0
  current_exe=$(readlink -f "/proc/$server/exe" 2>/dev/null || true)
  current_start=$(awk '{{print $22}}' "/proc/$server/stat" 2>/dev/null || true)
  if [ -n "$server_start" ] && [ "$current_start" = "$server_start" ] && {{ [ "$server_attested" -eq 0 ] || [ "$current_exe" = "$server_exe" ]; }}; then
    kill -TERM "$server" 2>/dev/null || true
  elif kill -0 "$server" 2>/dev/null; then
    printf 'ERROR=gdbserver-cleanup-identity-changed:%s\n' "$server" >&2
    return 1
  fi
}}
stop_watchdog_if_same() {{
  [ -n "$watchdog" ] || return 0
  current_start=$(awk '{{print $22}}' "/proc/$watchdog/stat" 2>/dev/null || true)
  if [ -n "$watchdog_start" ] && [ "$current_start" = "$watchdog_start" ]; then
    kill "$watchdog" 2>/dev/null || true
  fi
}}
cleanup() {{
  stop_watchdog_if_same
  terminate_server_if_same
}}
trap cleanup HUP INT TERM EXIT
/tmp/pluto-gdbserver-aarch64 --once --attach 127.0.0.1:{remote_port} "$1" &
server=$!
attempt=0
while [ "$attempt" -lt 50 ]; do
  server_start=$(awk '{{print $22}}' "/proc/$server/stat" 2>/dev/null || true)
  [ -n "$server_start" ] && break
  attempt=$((attempt+1))
  sleep 0.02
done
[ -n "$server_start" ] || exit 56
attempt=0
while [ "$attempt" -lt 50 ]; do
  server_exe=$(readlink -f "/proc/$server/exe" 2>/dev/null || true)
  case "$server_exe" in
    */pluto-gdbserver-aarch64) break ;;
  esac
  attempt=$((attempt+1))
  sleep 0.02
done
[ "${{server_exe##*/}}" = pluto-gdbserver-aarch64 ] || exit 55
server_attested=1
printf 'PLUTO_GDBSERVER_PID=%s\nPLUTO_GDBSERVER_EXE=%s\nPLUTO_GDBSERVER_START_TIME=%s\n' \
  "$server" "$server_exe" "$server_start"
( sleep {watchdog_seconds}; terminate_server_if_same ) &
watchdog=$!
watchdog_start=$(awk '{{print $22}}' "/proc/$watchdog/stat") || exit 57
wait "$server"
status=$?
server=''
stop_watchdog_if_same
watchdog=''
watchdog_start=''
exit "$status"
""".strip()


def wait_until_listening(
    process: subprocess.Popen[bytes], remote_port: int, timeout: float = 20.0
) -> dict[str, Any]:
    if process.stdout is None:
        raise CaptureError("gdbserver SSH process has no output pipe")
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    transcript: list[str] = []
    remote_server_pid: int | None = None
    remote_server_exe: str | None = None
    remote_server_start: int | None = None
    listening = False
    pending = b""

    def consume_line(raw_line: bytes) -> dict[str, Any] | None:
        nonlocal listening
        nonlocal remote_server_exe
        nonlocal remote_server_pid
        nonlocal remote_server_start
        line = raw_line.decode("utf-8", errors="replace")
        transcript.append(line)
        print(line, end="", flush=True)
        if line.startswith("PLUTO_GDBSERVER_PID="):
            try:
                remote_server_pid = int(line.split("=", 1)[1])
            except ValueError as error:
                raise CaptureError(
                    f"invalid remote gdbserver PID line: {line.rstrip()}"
                ) from error
        if line.startswith("PLUTO_GDBSERVER_EXE="):
            remote_server_exe = line.split("=", 1)[1].strip()
        if line.startswith("PLUTO_GDBSERVER_START_TIME="):
            try:
                remote_server_start = int(line.split("=", 1)[1])
            except ValueError as error:
                raise CaptureError(
                    f"invalid remote gdbserver start-time line: {line.rstrip()}"
                ) from error
        if f"Listening on port {remote_port}" in line:
            listening = True
        if (
            listening
            and remote_server_pid is not None
            and remote_server_exe is not None
            and remote_server_start is not None
        ):
            if remote_server_pid <= 0 or remote_server_start <= 0:
                raise CaptureError("remote gdbserver identity is invalid")
            if Path(remote_server_exe).name != "pluto-gdbserver-aarch64":
                raise CaptureError(
                    f"unexpected remote gdbserver executable: {remote_server_exe}"
                )
            return {
                "pid": remote_server_pid,
                "exe": remote_server_exe,
                "start_time_ticks": remote_server_start,
            }
        return None

    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(timeout=0.25):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    if pending:
                        identity = consume_line(pending)
                        if identity is not None:
                            return identity
                    raise CaptureError(
                        "gdbserver exited before listening:\n" + "".join(transcript)
                    )
                pending += chunk
                while b"\n" in pending:
                    raw_line, pending = pending.split(b"\n", 1)
                    identity = consume_line(raw_line + b"\n")
                    if identity is not None:
                        return identity
        raise CaptureError("timed out waiting for gdbserver to listen")
    finally:
        selector.close()


def recover_and_verify(
    device: str,
    expected_identity: dict[str, Any],
    expected_server: dict[str, Any] | None,
    expected_instruction_bytes: dict[str, str],
) -> dict[str, Any]:
    expected_pid = int(expected_identity["pid"])
    expected_exe = shlex.quote(str(expected_identity["exe"]))
    expected_sha = shlex.quote(str(expected_identity["remote_sha256"]))
    expected_start = shlex.quote(str(expected_identity["start_time_ticks"]))
    server_pid = "" if expected_server is None else str(expected_server["pid"])
    server_exe = "" if expected_server is None else str(expected_server["exe"])
    server_start = (
        "" if expected_server is None else str(expected_server["start_time_ticks"])
    )
    instruction_checks: list[str] = []
    for name, address, _file_offset, pinned_hex in BREAKPOINT_SITES:
        key = breakpoint_address_key(address)
        expected_hex = expected_instruction_bytes.get(key)
        if expected_hex != pinned_hex:
            raise CaptureError(
                f"missing or wrong pinned instruction for {name}: {expected_hex}"
            )
        shell_name = f"code_{address:08x}"
        instruction_checks.append(
            f"""
{shell_name}=$(dd if=\"/proc/$pid/mem\" bs=4 skip={address // 4} count=1 2>/dev/null | /usr/bin/hexdump -v -e '1/1 \"%02x\"')
if [ \"${shell_name}\" != {shlex.quote(expected_hex)} ]; then
  echo \"ERROR=software-breakpoint-not-restored:{address:08x}:${shell_name}\"
  exit 80
fi
printf 'CODE_{address:08X}=%s\\n' \"${shell_name}\"
""".strip()
        )
    instruction_shell = "\n".join(instruction_checks)
    command = f"""
pid={shlex.quote(str(expected_pid))}
expected_server={shlex.quote(server_pid)}
expected_server_exe={shlex.quote(server_exe)}
expected_server_start={shlex.quote(server_start)}
if ! kill -0 "$pid" 2>/dev/null; then
  echo 'ERROR=target-died'
  exit 61
fi
exe=$(readlink -f "/proc/$pid/exe") || exit 62
sum=$(sha256sum "/proc/$pid/exe") || exit 63
sum=${{sum%% *}}
start=$(awk '{{print $22}}' "/proc/$pid/stat") || exit 64
[ "$exe" = {expected_exe} ] || exit 65
[ "$sum" = {expected_sha} ] || exit 66
[ "$start" = {expected_start} ] || exit 67
tracer=$(awk '/^TracerPid:/{{print $2}}' "/proc/$pid/status") || exit 62
if [ "$tracer" -ne 0 ]; then
  if [ -z "$expected_server" ] || [ "$tracer" != "$expected_server" ]; then
    echo "ERROR=unexpected-tracer:$tracer"
    exit 68
  fi
  tracer_exe=$(readlink -f "/proc/$tracer/exe") || exit 77
  tracer_start=$(awk '{{print $22}}' "/proc/$tracer/stat") || exit 78
  if [ "$tracer_exe" != "$expected_server_exe" ] || [ "$tracer_start" != "$expected_server_start" ]; then
    echo "ERROR=gdbserver-identity-changed:$tracer"
    exit 79
  fi
  kill -TERM "$tracer" 2>/dev/null || true
  sleep 1
  tracer=$(awk '/^TracerPid:/{{print $2}}' "/proc/$pid/status") || exit 69
fi
if [ "$tracer" -ne 0 ]; then
  echo "ERROR=still-traced:$tracer"
  exit 70
fi
state=$(awk '/^State:/{{print $2}}' "/proc/$pid/status") || exit 71
if [ "$state" = T ] || [ "$state" = t ]; then
  kill -CONT "$pid" || exit 72
  sleep 1
  state=$(awk '/^State:/{{print $2}}' "/proc/$pid/status") || exit 73
fi
exe=$(readlink -f "/proc/$pid/exe") || exit 74
sum=$(sha256sum "/proc/$pid/exe") || exit 75
sum=${{sum%% *}}
start=$(awk '{{print $22}}' "/proc/$pid/stat") || exit 76
{instruction_shell}
printf 'PID=%s\nEXE=%s\nSHA256=%s\nTRACER=%s\nSTATE=%s\nSTART_TIME=%s\n' \
  "$pid" "$exe" "$sum" "$tracer" "$state" "$start"
""".strip()
    values = parse_key_values(run_ssh(device, command, timeout=15))
    try:
        pid = int(values["PID"])
        tracer = int(values["TRACER"])
        start_time = int(values["START_TIME"])
    except (KeyError, ValueError) as error:
        raise CaptureError(f"invalid recovery identity response: {values}") from error
    if (
        pid != expected_pid
        or tracer != 0
        or values.get("STATE") not in LIVE_PROCESS_STATES
        or values.get("EXE") != expected_identity["exe"]
        or values.get("SHA256") != expected_identity["remote_sha256"]
        or start_time != expected_identity["start_time_ticks"]
    ):
        raise CaptureError(f"Xochitl did not resume cleanly: {values}")
    restored_instructions: dict[str, str] = {}
    for _name, address, _file_offset, expected_hex in BREAKPOINT_SITES:
        output_key = f"CODE_{address:08X}"
        actual_hex = values.get(output_key, "")
        if actual_hex != expected_hex:
            raise CaptureError(
                "Xochitl software-breakpoint restoration proof is missing or wrong: "
                f"{output_key}={actual_hex}"
            )
        restored_instructions[breakpoint_address_key(address)] = actual_hex
    return {
        "pid": pid,
        "exe": values["EXE"],
        "remote_sha256": values["SHA256"],
        "start_time_ticks": start_time,
        "tracer_pid": tracer,
        "state": values["STATE"],
        "restored_instruction_bytes": restored_instructions,
    }


def main() -> int:
    repo = Path(__file__).resolve().parents[4]
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="root@10.11.99.1")
    parser.add_argument("--local-port", type=int, default=23456)
    parser.add_argument("--remote-port", type=int, default=2345)
    parser.add_argument(
        "--xochitl", type=Path, default=Path("/private/tmp/xochitl-3.27.1.0")
    )
    parser.add_argument(
        "--gdbserver",
        type=Path,
        default=repo / "build/device-tools/pluto-gdbserver-aarch64",
    )
    parser.add_argument(
        "--output", type=Path, default=Path("/private/tmp/xochitl-mapper-capture")
    )
    parser.add_argument("--timeout", type=int, default=220)
    args = parser.parse_args()
    if not (1 <= args.local_port <= 65535 and 1 <= args.remote_port <= 65535):
        raise CaptureError("GDB tunnel ports must be in 1..65535")
    if not 30 <= args.timeout <= 900:
        raise CaptureError("capture timeout must be in 30..900 seconds")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise CaptureError(f"capture directory is not empty: {output}")

    xochitl_sha, server_sha, breakpoint_bytes = verify_local_artifacts(
        args.xochitl.resolve(), args.gdbserver.resolve()
    )
    identity = remote_identity(args.device)
    if identity["tracer_pid"] != 0:
        raise CaptureError(f"Xochitl is already traced: {identity}")
    if identity["remote_sha256"] != xochitl_sha:
        raise CaptureError(f"running Xochitl hash mismatch: {identity}")
    if Path(identity["exe"]).name != "xochitl":
        raise CaptureError(f"unexpected target executable: {identity['exe']}")

    target_record = {
        "schema": 2,
        "captured_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "device": args.device,
        "gdb_endpoint": f"ssh-tunnel:127.0.0.1:{args.local_port}",
        "pid": identity["pid"],
        "exe": identity["exe"],
        "remote_sha256": identity["remote_sha256"],
        "start_time_ticks": identity["start_time_ticks"],
        "tracer_pid": identity["tracer_pid"],
        "state": identity["state"],
        "local_sha256": xochitl_sha,
        "build_id": EXPECTED_XOCHITL_BUILD_ID,
        "gdbserver_sha256": server_sha,
        "gdbserver_pid": None,
        "gdbserver_exe": None,
        "gdbserver_start_time_ticks": None,
        "breakpoint_kind": "software",
        "breakpoint_sites": breakpoint_site_records(),
    }
    (output / "cap.target.json").write_text(
        json.dumps(target_record, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    stage_gdbserver(args.device, args.gdbserver.resolve())
    server_process: subprocess.Popen[bytes] | None = None
    remote_server: dict[str, Any] | None = None
    capture_error: BaseException | None = None
    try:
        server_process = subprocess.Popen(
            [
                *ssh_prefix(
                    args.device,
                    local_forward=(
                        f"127.0.0.1:{args.local_port}:"
                        f"127.0.0.1:{args.remote_port}"
                    ),
                ),
                attach_command(
                    identity["pid"],
                    xochitl_sha,
                    args.remote_port,
                    args.timeout + 60,
                ),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        remote_server = wait_until_listening(server_process, args.remote_port)
        target_record["gdbserver_pid"] = remote_server["pid"]
        target_record["gdbserver_exe"] = remote_server["exe"]
        target_record["gdbserver_start_time_ticks"] = remote_server[
            "start_time_ticks"
        ]
        (output / "cap.target.json").write_text(
            json.dumps(target_record, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(
            "GDB is starting. Do not repaint until it prints: "
            "'Waiting for one isolated Content/UI operation'.",
            flush=True,
        )
        gdb_script = Path(__file__).with_name("capture_xochitl_mapper.gdb")
        result = subprocess.run(
            [
                "gdb",
                "-q",
                "-nx",
                "-batch",
                str(args.xochitl.resolve()),
                "-ex",
                f"target remote 127.0.0.1:{args.local_port}",
                "-x",
                str(gdb_script),
            ],
            cwd=output,
            timeout=args.timeout,
            check=False,
        )
        if result.returncode != 0:
            raise CaptureError(f"GDB capture failed with exit {result.returncode}")
    except Exception as error:
        capture_error = error
    finally:
        local_cleanup_error: BaseException | None = None
        try:
            if server_process is not None:
                if server_process.poll() is None:
                    server_process.terminate()
                try:
                    remainder, _ = server_process.communicate(timeout=10)
                    if remainder:
                        print(
                            remainder.decode("utf-8", errors="replace"),
                            end="",
                            flush=True,
                        )
                except subprocess.TimeoutExpired:
                    server_process.kill()
                    server_process.communicate(timeout=5)
        except BaseException as error:
            local_cleanup_error = error
        finally:
            try:
                recovery = recover_and_verify(
                    args.device, identity, remote_server, breakpoint_bytes
                )
                (output / "cap.recovery.json").write_text(
                    json.dumps(recovery, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            except BaseException as recovery_error:
                if local_cleanup_error is not None:
                    raise CaptureError(
                        "local debugger teardown failed "
                        f"({type(local_cleanup_error).__name__}: "
                        f"{local_cleanup_error}); device recovery also failed "
                        f"({type(recovery_error).__name__}: {recovery_error})"
                    ) from recovery_error
                raise
        if local_cleanup_error is not None:
            if capture_error is None:
                capture_error = local_cleanup_error
            else:
                capture_error = CaptureError(
                    f"capture failed ({type(capture_error).__name__}: "
                    f"{capture_error}); local debugger teardown also failed "
                    f"({type(local_cleanup_error).__name__}: "
                    f"{local_cleanup_error})"
                )

    if capture_error is not None:
        if isinstance(capture_error, CaptureError):
            raise capture_error
        raise CaptureError(
            f"capture aborted: {type(capture_error).__name__}: {capture_error}"
        ) from capture_error

    validator = Path(__file__).with_name("validate_xochitl_capture.py")
    validated = subprocess.run(
        [
            sys.executable,
            str(validator),
            str(output),
            "--xochitl",
            str(args.xochitl.resolve()),
            "--write-manifest",
        ],
        check=False,
    )
    if validated.returncode != 0:
        raise CaptureError("capture bundle validator rejected the result")
    print(f"Validated stock mapper capture: {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CaptureError as error:
        print(f"capture failed: {error}", file=sys.stderr)
        raise SystemExit(1)
