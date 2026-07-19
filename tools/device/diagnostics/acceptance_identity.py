#!/usr/bin/env python3
"""Fail-closed host identity checks shared by hardware acceptance scripts."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import sys


PROFILES = frozenset({"rm1", "rm2", "move"})
USER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9._-]*\Z")
HOST_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\Z")
IPV6_SCOPE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}\Z")


class IdentityError(ValueError):
    pass


def _port(value: str, *, label: str) -> int:
    if not re.fullmatch(r"[0-9]+", value):
        raise IdentityError(f"{label} port is not a positive integer")
    port = int(value, 10)
    if not 1 <= port <= 65535:
        raise IdentityError(f"{label} port is outside [1,65535]")
    return port


def _user_and_remainder(value: str, *, label: str) -> tuple[str, str]:
    if any(character.isspace() for character in value) or value.count("@") != 1:
        raise IdentityError(f"{label} must be an explicit user@host endpoint")
    user, remainder = value.split("@", 1)
    if USER_RE.fullmatch(user) is None or not remainder:
        raise IdentityError(f"{label} must be an explicit user@host endpoint")
    return user, remainder


def _host(value: str, *, label: str) -> tuple[str, bool]:
    if not value or value.startswith("-") or any(
        character in value for character in "[]/@\t\r\n"
    ):
        raise IdentityError(f"{label} host is invalid")
    address_text = value
    scope = ""
    if "%" in value:
        if value.count("%") != 1:
            raise IdentityError(f"{label} IPv6 scope is invalid")
        address_text, scope = value.split("%", 1)
        if IPV6_SCOPE_RE.fullmatch(scope) is None:
            raise IdentityError(f"{label} IPv6 scope is invalid")
    try:
        address = ipaddress.ip_address(address_text)
    except ValueError:
        if ":" in value or "%" in value or HOST_RE.fullmatch(value) is None:
            raise IdentityError(f"{label} host is invalid") from None
        return value.lower(), False
    ipv6 = isinstance(address, ipaddress.IPv6Address)
    if scope and not ipv6:
        raise IdentityError(f"{label} IPv6 scope is only valid on an IPv6 address")
    host = address.compressed
    if scope:
        host = f"{host}%{scope}"
    return host, ipv6


def _cli_endpoint(value: str) -> tuple[str, str, int, bool]:
    user, remainder = _user_and_remainder(value, label="DEVICE")
    port = 22
    if remainder.startswith("["):
        match = re.fullmatch(r"\[([^\[\]]+)\](?::([0-9]+))?", remainder)
        if match is None:
            raise IdentityError("DEVICE has invalid bracketed host syntax")
        host_text = match.group(1)
        if match.group(2) is not None:
            port = _port(match.group(2), label="DEVICE")
        host, ipv6 = _host(host_text, label="DEVICE")
        if not ipv6:
            raise IdentityError("DEVICE brackets are only valid around IPv6 hosts")
    else:
        if remainder.count(":") > 1:
            raise IdentityError("DEVICE IPv6 hosts must be bracketed")
        host_text = remainder
        if remainder.count(":") == 1:
            host_text, port_text = remainder.rsplit(":", 1)
            port = _port(port_text, label="DEVICE")
        host, ipv6 = _host(host_text, label="DEVICE")
    return user, host, port, ipv6


def _ssh_endpoint(value: str, port_text: str) -> tuple[str, str, int, bool]:
    user, remainder = _user_and_remainder(value, label="SSH target")
    embedded_port: str | None = None
    if remainder.startswith("["):
        match = re.fullmatch(r"\[([^\[\]]+)\](?::([0-9]+))?", remainder)
        if match is None:
            raise IdentityError("SSH target has invalid bracketed host syntax")
        host_text = match.group(1)
        embedded_port = match.group(2)
        host, ipv6 = _host(host_text, label="SSH target")
        if not ipv6:
            raise IdentityError("SSH target brackets are only valid around IPv6 hosts")
    else:
        host_text = remainder
        if remainder.count(":") == 1:
            candidate_host, candidate_port = remainder.rsplit(":", 1)
            if candidate_port.isdigit():
                host_text = candidate_host
                embedded_port = candidate_port
        host, ipv6 = _host(host_text, label="SSH target")
    if port_text and embedded_port:
        port = _port(port_text, label="SSH")
        if port != _port(embedded_port, label="SSH target"):
            raise IdentityError("SSH target and PLUTO_ACCEPTANCE_SSH_PORT disagree")
    else:
        port = _port(port_text or embedded_port or "22", label="SSH")
    return user, host, port, ipv6


def _canonical(endpoint: tuple[str, str, int, bool]) -> str:
    user, host, port, ipv6 = endpoint
    rendered_host = f"[{host}]" if ipv6 else host
    return f"{user}@{rendered_host}:{port}"


def endpoint_command(args: argparse.Namespace) -> None:
    cli = _cli_endpoint(args.device)
    ssh = _ssh_endpoint(args.ssh_target, args.ssh_port)
    divergent = cli[:3] != ssh[:3]
    if divergent and not args.allow_divergence:
        raise IdentityError(
            "DEVICE and SSH target select different user/host/port identities "
            f"({_canonical(cli)} != {_canonical(ssh)})"
        )
    print(f"canonical_endpoint\t{_canonical(cli)}")
    print(f"ssh_invocation_target\t{ssh[0]}@{ssh[1]}")
    print(f"ssh_port\t{ssh[2]}")
    print(f"divergent\t{int(divergent)}")


def validate_endpoint_command(args: argparse.Namespace) -> None:
    parsed = _cli_endpoint(args.endpoint)
    canonical = _canonical(parsed)
    if args.endpoint != canonical:
        raise IdentityError(f"recorded endpoint is not canonical: {args.endpoint}")
    print(canonical)


def validate_ssh_target_command(args: argparse.Namespace) -> None:
    parsed = _ssh_endpoint(args.target, args.port)
    print(f"ssh_invocation_target\t{parsed[0]}@{parsed[1]}")
    print(f"ssh_port\t{parsed[2]}")


def _camera_devices(path: Path) -> list[dict[str, object]]:
    if path.is_symlink() or not path.is_file():
        raise IdentityError(f"camera config must be a regular non-symlink file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IdentityError(f"camera config is not valid JSON: {path}: {error}") from error
    if not isinstance(value, dict) or not isinstance(value.get("devices"), list):
        raise IdentityError("camera config must contain a devices array")
    devices = value["devices"]
    if not devices:
        raise IdentityError("camera config contains no devices")
    seen: set[int] = set()
    validated: list[dict[str, object]] = []
    for entry in devices:
        if not isinstance(entry, dict):
            raise IdentityError("camera config contains an invalid device entry")
        number = entry.get("number")
        profile = entry.get("profile_id")
        if (
            isinstance(number, bool)
            or not isinstance(number, int)
            or number <= 0
            or number in seen
            or not isinstance(profile, str)
            or profile not in PROFILES
        ):
            raise IdentityError(
                "every camera device must have a unique positive number and exact "
                "profile_id rm1, rm2, or move"
            )
        seen.add(number)
        validated.append(entry)
    return validated


def camera_profile_command(args: argparse.Namespace) -> None:
    config = Path(args.config)
    devices = _camera_devices(config)
    selected = next((entry for entry in devices if entry["number"] == args.device), None)
    if selected is None:
        available = ", ".join(str(entry["number"]) for entry in devices)
        raise IdentityError(
            f"camera rig {args.device} is not configured; available devices: {available}"
        )
    profile = str(selected["profile_id"])
    if profile != args.expected_profile:
        raise IdentityError(
            f"camera rig {args.device} is bound to profile {profile}, "
            f"not {args.expected_profile}"
        )
    print(profile)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    endpoint = subparsers.add_parser("endpoint")
    endpoint.add_argument("--device", required=True)
    endpoint.add_argument("--ssh-target", required=True)
    endpoint.add_argument("--ssh-port", default="")
    endpoint.add_argument("--allow-divergence", action="store_true")
    endpoint.set_defaults(handler=endpoint_command)

    validate_endpoint = subparsers.add_parser("validate-endpoint")
    validate_endpoint.add_argument("--endpoint", required=True)
    validate_endpoint.set_defaults(handler=validate_endpoint_command)

    validate_ssh_target = subparsers.add_parser("validate-ssh-target")
    validate_ssh_target.add_argument("--target", required=True)
    validate_ssh_target.add_argument("--port", default="")
    validate_ssh_target.set_defaults(handler=validate_ssh_target_command)

    camera_profile = subparsers.add_parser("camera-profile")
    camera_profile.add_argument("--config", required=True)
    camera_profile.add_argument("--device", type=int, required=True)
    camera_profile.add_argument("--expected-profile", choices=sorted(PROFILES), required=True)
    camera_profile.set_defaults(handler=camera_profile_command)
    return parser


def main() -> int:
    try:
        arguments = build_parser().parse_args()
        arguments.handler(arguments)
        return 0
    except IdentityError as error:
        print(f"acceptance identity: {error}", file=sys.stderr)
        return os.EX_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
