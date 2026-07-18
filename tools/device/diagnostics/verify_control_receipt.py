#!/usr/bin/env python3
"""Validate exact acceptance-only native control receipts."""

from __future__ import annotations

import argparse
import json
import sys
from typing import NoReturn


MAX_UINT64 = (1 << 64) - 1
MAX_INT64 = (1 << 63) - 1


class ReceiptError(ValueError):
    pass


def fail(message: str) -> NoReturn:
    raise ReceiptError(message)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            fail(f"duplicate JSON field: {key}")
        value[key] = item
    return value


def exact_integer(value: object, *, label: str) -> int:
    if type(value) is not int:
        fail(f"{label} is not an integer")
    return value


def verify_prepare_ink(args: argparse.Namespace) -> None:
    try:
        value = json.loads(args.response, object_pairs_hook=unique_object)
    except (json.JSONDecodeError, UnicodeError) as error:
        fail(f"response is not valid JSON: {error}")
    if not isinstance(value, dict) or set(value) != {"requestId", "ok", "result"}:
        fail("response envelope does not have the exact prepare receipt fields")
    if value["requestId"] != args.request_id or value["ok"] is not True:
        fail("response envelope does not match the request")
    result = value["result"]
    required = {
        "appId",
        "pid",
        "processStartTicks",
        "canvasReady",
        "actionCount",
        "surfaceGeneration",
        "proofFrameId",
    }
    if not isinstance(result, dict) or set(result) != required:
        fail("prepare result does not have the exact receipt fields")
    pid = exact_integer(result["pid"], label="pid")
    action_count = exact_integer(result["actionCount"], label="actionCount")
    process_start_ticks = exact_integer(
        result["processStartTicks"], label="processStartTicks"
    )
    surface_generation = exact_integer(
        result["surfaceGeneration"], label="surfaceGeneration"
    )
    proof_frame_id = exact_integer(result["proofFrameId"], label="proofFrameId")
    if (
        result["appId"] != args.app_id
        or pid != args.pid
        or pid <= 0
        or pid > MAX_INT64
    ):
        fail("prepare result is not bound to the expected app and PID")
    if (
        process_start_ticks != args.start_ticks
        or process_start_ticks <= 0
        or process_start_ticks > MAX_UINT64
    ):
        fail("prepare result is not bound to the expected process start ticks")
    if result["canvasReady"] is not True or action_count not in {0, 1, 2}:
        fail("prepare result does not prove a bounded ready canvas")
    for label, item in (
        ("surfaceGeneration", surface_generation),
        ("proofFrameId", proof_frame_id),
    ):
        if item <= 0 or item > MAX_UINT64:
            fail(f"{label} is outside the nonzero native uint64 range")

    canonical = json.dumps(
        {
            "requestId": args.request_id,
            "ok": True,
            "result": {
                "appId": args.app_id,
                "pid": args.pid,
                "processStartTicks": args.start_ticks,
                "canvasReady": True,
                "actionCount": action_count,
                "surfaceGeneration": surface_generation,
                "proofFrameId": proof_frame_id,
            },
        },
        ensure_ascii=True,
        separators=(",", ":"),
    )
    if args.response != canonical:
        fail("prepare receipt is not in the exact canonical wire form")
    print(f"action_count\t{action_count}")
    print(f"surface_generation\t{surface_generation}")
    print(f"proof_frame_id\t{proof_frame_id}")
    print(f"process_start_ticks\t{process_start_ticks}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)
    prepare = subparsers.add_parser("prepare-ink")
    prepare.add_argument("--response", required=True)
    prepare.add_argument("--request-id", required=True)
    prepare.add_argument("--app-id", required=True)
    prepare.add_argument("--pid", required=True, type=int)
    prepare.add_argument("--start-ticks", required=True, type=int)
    prepare.set_defaults(handler=verify_prepare_ink)
    return parser


def main() -> int:
    parser = build_parser()
    try:
        args = parser.parse_args()
        args.handler(args)
    except ReceiptError as error:
        print(f"control receipt: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
