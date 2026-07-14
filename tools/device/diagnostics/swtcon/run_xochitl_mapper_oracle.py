#!/usr/bin/env python3
"""Run the exact Xochitl ct33 mapper in a disposable offline inferior.

This tool has deliberately no device, SSH, attach, or production-presenter path.
It verifies every pinned artifact before asking a local ARM64 Docker container to
start Xochitl with the extracted firmware loader.  Host GDB talks to gdbserver
over stdio, constructs the synthetic direct-call state, and kills the inferior
after the post-store dump.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, Iterable, Sequence


class OracleError(RuntimeError):
    """A fail-closed oracle precondition or execution failure."""


@dataclasses.dataclass(frozen=True)
class BinaryPin:
    size: int
    sha256: str
    build_id: str
    entry: int
    range_start: int
    range_end: int
    range_offset: int
    range_sha256: str


XOCHITL_PIN = BinaryPin(
    size=23_059_080,
    sha256="4646e0aef1cef2b3417889073ad5faba9259ae6b41f68326e75ef9a5c520c322",
    build_id="f04525824e27e75d7a579b18c4007a3a76384789",
    entry=0x00483B00,
    range_start=0x004814A0,
    range_end=0x00483B30,
    range_offset=0x000814A0,
    range_sha256="3526e104129db479e5218f5f54a9fed2d7b655a6a8632b9d0868f54dfa0859fc",
)

EXPECTED_GDBSERVER_SHA256 = (
    "f5154a1d16d577c90d794199a2bacf66954e6306e4b09281fb7ca1ecaa2fe8be"
)
EXPECTED_GDBSERVER_BUILD_ID = "aef4fdb5d079d1465b448e24e764f148c3e76f2e"
EXPECTED_LOADER_SHA256 = (
    "fc5d445d078240e4f04eed22db5426da1ecab3930a75f5641461a7590e6842b5"
)
EXPECTED_LIBC_SHA256 = (
    "976c467f2c03c31ca1c06589d96230c27efaac3f6f5a9073dd15502a0c700b0e"
)
EXPECTED_USR_LIB_TREE = {
    "sha256": "205b06e3125567ecde92210d3e0f8b1cf51c3767cf912ea914a97c65840491b2",
    "files": 1647,
    "directories": 219,
    "symlinks": 236,
    "file_bytes": 192_355_517,
}

# Addresses are valid only for XOCHITL_PIN.
MAIN_READY = 0x00483B34
MAPPER_ENTRY = 0x004814A0
FAST_DISPATCHER_ENTRY = 0x009AF7C0
POST_STORE = 0x00483280
AB_DESCRIPTOR = 0x01A18FD8

PALETTE_BYTES = 16
DELTA_BYTES = 0x800
CTX_BYTES = 0xB0
SOURCE_DESCRIPTOR_BYTES = 0x30
WAVE_DESCRIPTOR_BYTES = 0x38
OUTPUT_DESCRIPTOR_BYTES = 0x30
AB_DESCRIPTOR_BYTES = 0x30
FAST_GLOBAL_OWNER_BYTES = 0x7000
FAST_CONTINUATION_PENDING_OFFSET = 0x6568
REDZONE_BYTES = 64
REDZONE_PATTERN = bytes(
    ((0xA5 ^ (index * 37)) & 0xFF) for index in range(REDZONE_BYTES)
)
BUFFER_NAMES = ("palette", "delta", "ct33", "ab", "output")
BRIDGE_SEQUENCE_KINDS = {
    "legacy-fast-legacy": 2,
    "fast-legacy": 3,
    "fast-continuation-legacy": 4,
}
BRIDGE_SEQUENCE_CALLS = {
    "legacy-fast-legacy": ("legacy", "fast-source", "legacy"),
    "fast-legacy": ("fast-source", "legacy"),
    "fast-continuation-legacy": (
        "fast-source",
        "fast-continuation",
        "legacy",
    ),
}

PANEL_WIDTH = 960
PANEL_HEIGHT = 1696
PANEL_SOURCE_STRIDE = 960
PANEL_AB_STRIDE = 968
PANEL_AB_STORAGE_ROWS = 1698
# Safety-oracle capacity. Runtime pattern probes prove 0x4814a0 treats
# ctx+0x10 as an operation-local origin; only a stock capture can establish
# the converter's actual per-operation source descriptor/stride. Allocating
# the full maximum plane here keeps every legal prefix and vector overread
# inside an independently redzoned object without claiming that stock always
# allocates this many ct33 bytes for a small region.
PANEL_CT33_BYTES = PANEL_SOURCE_STRIDE * PANEL_HEIGHT
PANEL_AB_BYTES = PANEL_AB_STRIDE * PANEL_AB_STORAGE_ROWS * 4

IMAGE_REF_RE = re.compile(r"^\S+@sha256:[0-9a-f]{64}$")
CONTAINER_LIBRARY_RE = re.compile(r"(?<!\S)(/oracle/usr-lib/[^\s()]+)")
MARKERS = (
    "ORACLE_MAIN_READY",
    "ORACLE_CALL_BEGIN",
    "ORACLE_POST_STORE",
    "ORACLE_MAPPER_COMPLETE",
    "ORACLE_COMPLETE",
)


@dataclasses.dataclass(frozen=True)
class ProgramHeader:
    kind: int
    flags: int
    offset: int
    vaddr: int
    filesz: int
    memsz: int


@dataclasses.dataclass(frozen=True)
class ElfInfo:
    elf_type: int
    machine: int
    entry: int
    build_id: str
    interpreter: str | None
    needed: tuple[str, ...]
    headers: tuple[ProgramHeader, ...]


@dataclasses.dataclass(frozen=True)
class FixtureLayout:
    profile: str
    rows: int
    storage_rows: int
    source_left: int
    source_top: int
    source_right: int
    source_bottom: int
    source_stride: int
    ab_left: int
    ab_top: int
    ab_right: int
    ab_bottom: int
    ab_stride: int
    update_left: int
    update_top: int
    update_right: int
    update_bottom: int
    output_stride: int
    y_first: int
    y_last: int
    ct33_bytes: int
    ab_bytes: int
    output_bytes: int
    palette_offset: int
    delta_offset: int
    ct33_offset: int
    ab_offset: int
    output_offset: int
    arena_bytes: int

    @classmethod
    def for_rows(cls, rows: int) -> "FixtureLayout":
        if rows not in (1, 2):
            raise OracleError("rows must be exactly 1 or 2")
        # At 0x4815bc the mapper computes p = row_count & 1.  The width-one
        # scalar path at 0x4829a0 and final stores at 0x48326c..0x48327c touch
        # exactly storage rows p and p+1.  Storage therefore covers indices
        # 0..p+1: three rows for a one-row update, two for a two-row update.
        storage_rows = (rows & 1) + 2
        ct33_bytes = storage_rows * 8
        ab_bytes = storage_rows * 8 * 4
        output_bytes = storage_rows * 16 * 2

        # This mirrors the checked GDB arena layout.  Each externally supplied
        # or mutable buffer has an independent nonzero 64-byte pre/post
        # redzone; every buffer start remains 16-byte aligned.
        cursor = CTX_BYTES + SOURCE_DESCRIPTOR_BYTES + 0x40
        cursor += OUTPUT_DESCRIPTOR_BYTES

        def reserve(size: int) -> int:
            nonlocal cursor
            cursor = (cursor + 15) & ~15
            cursor += REDZONE_BYTES
            data_offset = cursor
            cursor += size
            cursor += REDZONE_BYTES
            return data_offset

        palette_offset = reserve(PALETTE_BYTES)
        delta_offset = reserve(DELTA_BYTES)
        ct33_offset = reserve(ct33_bytes)
        ab_offset = reserve(ab_bytes)
        output_offset = reserve(output_bytes)
        cursor = (cursor + 15) & ~15
        if cursor & 0xF:
            raise AssertionError("oracle arena is not 16-byte aligned")
        return cls(
            profile="minimal",
            rows=rows,
            storage_rows=storage_rows,
            source_left=0,
            source_top=0,
            source_right=7,
            source_bottom=storage_rows - 1,
            source_stride=8,
            ab_left=0,
            ab_top=0,
            ab_right=7,
            ab_bottom=storage_rows - 1,
            ab_stride=8,
            update_left=0,
            update_top=0,
            update_right=0,
            update_bottom=rows - 1,
            output_stride=16,
            y_first=0,
            y_last=rows - 1,
            ct33_bytes=ct33_bytes,
            ab_bytes=ab_bytes,
            output_bytes=output_bytes,
            palette_offset=palette_offset,
            delta_offset=delta_offset,
            ct33_offset=ct33_offset,
            ab_offset=ab_offset,
            output_offset=output_offset,
            arena_bytes=cursor,
        )

    @classmethod
    def for_panel(
        cls, left: int, top: int, width: int, height: int
    ) -> "FixtureLayout":
        if width <= 0 or height <= 0:
            raise OracleError("panel update width and height must be positive")
        if (
            left < 0
            or top < 0
            or left + width > PANEL_WIDTH
            or top + height > PANEL_HEIGHT
        ):
            raise OracleError("panel update rectangle is outside 960x1696")
        right = left + width - 1
        bottom = top + height - 1
        output_stride = (width + 8 + 7) & ~7
        output_bytes = 2 * (height + 2) * output_stride

        cursor = CTX_BYTES + SOURCE_DESCRIPTOR_BYTES + 0x40
        cursor += OUTPUT_DESCRIPTOR_BYTES

        def reserve(size: int) -> int:
            nonlocal cursor
            cursor = (cursor + 15) & ~15
            cursor += REDZONE_BYTES
            data_offset = cursor
            cursor += size
            cursor += REDZONE_BYTES
            return data_offset

        palette_offset = reserve(PALETTE_BYTES)
        delta_offset = reserve(DELTA_BYTES)
        ct33_offset = reserve(PANEL_CT33_BYTES)
        ab_offset = reserve(PANEL_AB_BYTES)
        output_offset = reserve(output_bytes)
        cursor = (cursor + 15) & ~15
        return cls(
            profile="panel",
            rows=height,
            storage_rows=PANEL_HEIGHT,
            source_left=0,
            source_top=0,
            source_right=PANEL_WIDTH - 1,
            source_bottom=PANEL_HEIGHT - 1,
            source_stride=PANEL_SOURCE_STRIDE,
            ab_left=0,
            ab_top=0,
            ab_right=PANEL_WIDTH - 1,
            ab_bottom=PANEL_HEIGHT - 1,
            ab_stride=PANEL_AB_STRIDE,
            update_left=left,
            update_top=top,
            update_right=right,
            update_bottom=bottom,
            output_stride=output_stride,
            y_first=top,
            y_last=bottom,
            ct33_bytes=PANEL_CT33_BYTES,
            ab_bytes=PANEL_AB_BYTES,
            output_bytes=output_bytes,
            palette_offset=palette_offset,
            delta_offset=delta_offset,
            ct33_offset=ct33_offset,
            ab_offset=ab_offset,
            output_offset=output_offset,
            arena_bytes=cursor,
        )

    def buffer_offsets(self) -> dict[str, tuple[int, int]]:
        return {
            "palette": (self.palette_offset, PALETTE_BYTES),
            "delta": (self.delta_offset, DELTA_BYTES),
            "ct33": (self.ct33_offset, self.ct33_bytes),
            "ab": (self.ab_offset, self.ab_bytes),
            "output": (self.output_offset, self.output_bytes),
        }

    def expected_dump_sizes(self) -> dict[str, int]:
        sizes = {
            "oracle.ctx.bin": CTX_BYTES,
            "oracle.srcdesc.bin": SOURCE_DESCRIPTOR_BYTES,
            "oracle.wavedesc.bin": WAVE_DESCRIPTOR_BYTES,
            "oracle.outdesc.bin": OUTPUT_DESCRIPTOR_BYTES,
            "oracle.abdesc.original.bin": AB_DESCRIPTOR_BYTES,
            "oracle.abdesc.synthetic.bin": AB_DESCRIPTOR_BYTES,
            "oracle.abdesc.restored.bin": AB_DESCRIPTOR_BYTES,
            "oracle.palette.loaded.bin": PALETTE_BYTES,
            "oracle.ct33.loaded.bin": self.ct33_bytes,
            "oracle.delta.loaded.bin": DELTA_BYTES,
            "oracle.ab.before.loaded.bin": self.ab_bytes,
            "oracle.output.after.bin": self.output_bytes,
            "oracle.ab.after.bin": self.ab_bytes,
        }
        for name in BUFFER_NAMES:
            sizes[f"oracle.redzone.{name}.pre.bin"] = REDZONE_BYTES
            sizes[f"oracle.redzone.{name}.post.bin"] = REDZONE_BYTES
        return sizes


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_c_string(blob: bytes, start: int, limit: int) -> str:
    if not 0 <= start < limit <= len(blob):
        raise OracleError("ELF string offset is outside the file")
    end = blob.find(b"\0", start, limit)
    if end < 0:
        raise OracleError("ELF string is not NUL terminated")
    try:
        return blob[start:end].decode("utf-8")
    except UnicodeDecodeError as error:
        raise OracleError("ELF string is not UTF-8") from error


def _file_offset_for_vaddr(
    headers: Iterable[ProgramHeader], address: int, size: int
) -> int:
    if size < 0 or address < 0:
        raise OracleError("invalid ELF virtual range")
    for header in headers:
        if header.kind != 1:
            continue
        if address >= header.vaddr and address + size <= header.vaddr + header.filesz:
            return header.offset + address - header.vaddr
    raise OracleError(f"ELF virtual range 0x{address:x}+0x{size:x} is not file-backed")


def _segment_for_vaddr(
    headers: Iterable[ProgramHeader], address: int, size: int
) -> ProgramHeader:
    for header in headers:
        if header.kind != 1:
            continue
        if address >= header.vaddr and address + size <= header.vaddr + header.memsz:
            return header
    raise OracleError(f"ELF virtual range 0x{address:x}+0x{size:x} is unmapped")


def inspect_elf(path: Path) -> ElfInfo:
    blob = path.read_bytes()
    if (
        len(blob) < 64
        or blob[:7] != b"\x7fELF\x02\x01\x01"
        or blob[7] not in (0, 3)
        or any(blob[8:16])
    ):
        raise OracleError(f"not a supported ELF64 little-endian Linux file: {path}")
    (
        elf_type,
        machine,
        version,
        entry,
        phoff,
        _shoff,
        _flags,
        ehsize,
        phentsize,
        phnum,
        _shentsize,
        _shnum,
        _shstrndx,
    ) = struct.unpack_from("<HHIQQQIHHHHHH", blob, 16)
    if version != 1 or ehsize != 64 or phentsize != 56:
        raise OracleError("unsupported ELF header layout")
    if phnum == 0 or phoff + phnum * phentsize > len(blob):
        raise OracleError("ELF program-header table is outside the file")

    headers: list[ProgramHeader] = []
    for index in range(phnum):
        offset = phoff + index * phentsize
        kind, flags, file_offset, vaddr, _paddr, filesz, memsz, _align = (
            struct.unpack_from("<IIQQQQQQ", blob, offset)
        )
        if file_offset + filesz > len(blob):
            raise OracleError("ELF segment is outside the file")
        headers.append(ProgramHeader(kind, flags, file_offset, vaddr, filesz, memsz))

    build_ids: list[str] = []
    interpreter: str | None = None
    dynamic: ProgramHeader | None = None
    for header in headers:
        if header.kind == 3:
            interpreter = _read_c_string(
                blob, header.offset, header.offset + header.filesz
            )
        elif header.kind == 2:
            dynamic = header
        elif header.kind == 4:
            cursor = header.offset
            limit = header.offset + header.filesz
            while cursor + 12 <= limit:
                namesz, descsz, note_type = struct.unpack_from("<III", blob, cursor)
                cursor += 12
                name_end = cursor + namesz
                desc_start = (name_end + 3) & ~3
                desc_end = desc_start + descsz
                next_note = (desc_end + 3) & ~3
                if name_end > limit or desc_end > limit or next_note > limit:
                    raise OracleError("ELF note is truncated")
                name = blob[cursor:name_end].rstrip(b"\0")
                if name == b"GNU" and note_type == 3:
                    build_ids.append(blob[desc_start:desc_end].hex())
                cursor = next_note
    if len(set(build_ids)) != 1:
        raise OracleError(f"ELF has {len(set(build_ids))} distinct GNU build IDs")

    needed: list[str] = []
    if dynamic is not None:
        string_vaddr: int | None = None
        string_size: int | None = None
        needed_offsets: list[int] = []
        cursor = dynamic.offset
        limit = dynamic.offset + dynamic.filesz
        while cursor + 16 <= limit:
            tag, value = struct.unpack_from("<QQ", blob, cursor)
            cursor += 16
            if tag == 0:
                break
            if tag == 1:
                needed_offsets.append(value)
            elif tag == 5:
                string_vaddr = value
            elif tag == 10:
                string_size = value
        if needed_offsets:
            if string_vaddr is None or string_size is None or string_size <= 0:
                raise OracleError("ELF DT_NEEDED entries have no valid string table")
            string_offset = _file_offset_for_vaddr(headers, string_vaddr, string_size)
            for offset in needed_offsets:
                if offset >= string_size:
                    raise OracleError("ELF DT_NEEDED offset is outside DT_STRTAB")
                needed.append(
                    _read_c_string(
                        blob,
                        string_offset + offset,
                        string_offset + string_size,
                    )
                )

    return ElfInfo(
        elf_type,
        machine,
        entry,
        build_ids[0],
        interpreter,
        tuple(needed),
        tuple(headers),
    )


def verify_xochitl(path: Path, pin: BinaryPin = XOCHITL_PIN) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise OracleError(f"Xochitl must be a regular non-symlink file: {path}")
    size = path.stat().st_size
    whole_hash = sha256_file(path)
    if size != pin.size or whole_hash != pin.sha256:
        raise OracleError(
            f"Xochitl identity mismatch: size={size} sha256={whole_hash}"
        )
    info = inspect_elf(path)
    if (info.elf_type, info.machine, info.entry) != (2, 183, pin.entry):
        raise OracleError(
            "Xochitl is not the pinned non-PIE AArch64 executable: "
            f"type={info.elf_type} machine={info.machine} entry=0x{info.entry:x}"
        )
    if info.interpreter != "/lib/ld-linux-aarch64.so.1":
        raise OracleError(f"unexpected Xochitl interpreter: {info.interpreter!r}")
    if info.build_id != pin.build_id:
        raise OracleError(f"Xochitl Build ID mismatch: {info.build_id}")
    range_size = pin.range_end - pin.range_start
    range_offset = _file_offset_for_vaddr(info.headers, pin.range_start, range_size)
    if range_offset != pin.range_offset:
        raise OracleError(
            f"mapper file offset mismatch: 0x{range_offset:x} != 0x{pin.range_offset:x}"
        )
    with path.open("rb") as handle:
        handle.seek(range_offset)
        range_hash = hashlib.sha256(handle.read(range_size)).hexdigest()
    if range_hash != pin.range_sha256:
        raise OracleError(f"mapper range SHA-256 mismatch: {range_hash}")

    for address in (MAIN_READY, MAPPER_ENTRY, POST_STORE):
        if not _segment_for_vaddr(info.headers, address, 4).flags & 1:
            raise OracleError(f"required executable address is not executable: 0x{address:x}")
    if not _segment_for_vaddr(info.headers, AB_DESCRIPTOR, AB_DESCRIPTOR_BYTES).flags & 2:
        raise OracleError("fixed A/B descriptor is not in a writable load segment")
    return {
        "path": str(path),
        "size": size,
        "sha256": whole_hash,
        "build_id": info.build_id,
        "elf_entry": f"0x{info.entry:08x}",
        "interpreter": info.interpreter,
        "needed": list(info.needed),
        "mapper_range": {
            "start": f"0x{pin.range_start:08x}",
            "end_exclusive": f"0x{pin.range_end:08x}",
            "file_offset": f"0x{range_offset:x}",
            "size": range_size,
            "sha256": range_hash,
        },
        "addresses": {
            "main_ready": f"0x{MAIN_READY:08x}",
            "mapper_entry": f"0x{MAPPER_ENTRY:08x}",
            "post_store": f"0x{POST_STORE:08x}",
            "ab_descriptor": f"0x{AB_DESCRIPTOR:08x}",
        },
    }


def _verify_sha(path: Path, expected: str, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise OracleError(f"{label} must be a regular non-symlink file: {path}")
    actual = sha256_file(path)
    if actual != expected:
        raise OracleError(f"{label} SHA-256 mismatch: {actual}")
    return {"path": str(path), "size": path.stat().st_size, "sha256": actual}


def verify_gdbserver(path: Path) -> dict[str, Any]:
    record = _verify_sha(path, EXPECTED_GDBSERVER_SHA256, "gdbserver")
    if not os.access(path, os.X_OK):
        raise OracleError("gdbserver is not executable")
    info = inspect_elf(path)
    if info.machine != 183 or info.elf_type != 2:
        raise OracleError("gdbserver is not an AArch64 executable")
    if info.build_id != EXPECTED_GDBSERVER_BUILD_ID:
        raise OracleError(f"gdbserver Build ID mismatch: {info.build_id}")
    record["build_id"] = info.build_id
    record["interpreter"] = info.interpreter
    return record


def locate_firmware_usr_lib(rootfs: Path) -> tuple[Path, str]:
    if rootfs.is_symlink() or not rootfs.is_dir():
        raise OracleError(f"rootfs must be a real directory: {rootfs}")
    candidates = (
        (rootfs / "usr/lib/ld-linux-aarch64.so.1", rootfs / "usr/lib", "full-rootfs"),
        (rootfs / "ld-linux-aarch64.so.1", rootfs, "extracted-usr-lib"),
    )
    matches = [(directory, layout) for loader, directory, layout in candidates if loader.is_file()]
    if len(matches) != 1:
        raise OracleError(
            "rootfs must contain exactly one firmware usr/lib layout "
            "(root/usr/lib or the extractor's /usr/lib subtree)"
        )
    return matches[0]


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def hash_tree(root: Path) -> dict[str, Any]:
    """Hash paths, file contents, and symlink text without following the tree."""
    root = root.resolve(strict=True)
    digest = hashlib.sha256()
    files = directories = symlinks = total_bytes = 0
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            directories += 1
            payload = f"D\0{relative}\0".encode()
        elif stat.S_ISLNK(mode):
            symlinks += 1
            target = os.readlink(path)
            payload = f"L\0{relative}\0{target}\0".encode()
        elif stat.S_ISREG(mode):
            files += 1
            size = path.stat().st_size
            total_bytes += size
            payload = (
                f"F\0{relative}\0{size}\0{sha256_file(path)}\0".encode()
            )
        else:
            raise OracleError(f"firmware usr/lib contains a special file: {path}")
        digest.update(payload)
    return {
        "algorithm": "sha256(type-NUL-relative-path-NUL-size-or-link-or-content-hash-NUL)",
        "sha256": digest.hexdigest(),
        "files": files,
        "directories": directories,
        "symlinks": symlinks,
        "file_bytes": total_bytes,
    }


def verify_rootfs(rootfs: Path) -> tuple[Path, dict[str, Any]]:
    usr_lib, layout = locate_firmware_usr_lib(rootfs)
    usr_lib = usr_lib.resolve(strict=True)
    loader = usr_lib / "ld-linux-aarch64.so.1"
    libc = usr_lib / "libc.so.6"
    loader_record = _verify_sha(loader, EXPECTED_LOADER_SHA256, "firmware loader")
    libc_record = _verify_sha(libc, EXPECTED_LIBC_SHA256, "firmware libc")
    for path in (loader, libc):
        resolved = path.resolve(strict=True)
        if not _is_within(resolved, usr_lib):
            raise OracleError(f"firmware runtime file escapes usr/lib: {path}")
    tree = hash_tree(usr_lib)
    actual_tree_identity = {
        key: tree[key] for key in EXPECTED_USR_LIB_TREE
    }
    if actual_tree_identity != EXPECTED_USR_LIB_TREE:
        raise OracleError(
            "firmware usr/lib tree identity mismatch: "
            + json.dumps(actual_tree_identity, sort_keys=True)
        )
    return usr_lib, {
        "input_root": str(rootfs),
        "layout": layout,
        "usr_lib": str(usr_lib),
        "loader": loader_record,
        "libc": libc_record,
        "tree": tree,
    }


def verify_input(path: Path, size: int, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise OracleError(f"{label} must be a regular non-symlink file: {path}")
    actual_size = path.stat().st_size
    if actual_size != size:
        raise OracleError(f"{label} must be exactly {size} bytes, got {actual_size}")
    return {"path": str(path), "size": actual_size, "sha256": sha256_file(path)}


def verify_image_reference(image: str) -> None:
    if not IMAGE_REF_RE.fullmatch(image):
        raise OracleError("container image must be an immutable name@sha256:<64 lowercase hex> reference")


def inspect_container_image(docker: Path, image: str) -> dict[str, Any]:
    verify_image_reference(image)
    result = subprocess.run(
        [str(docker), "image", "inspect", image],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise OracleError(f"pinned local image is unavailable: {result.stderr.strip()}")
    try:
        values = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise OracleError("docker image inspect returned invalid JSON") from error
    if not isinstance(values, list) or len(values) != 1 or not isinstance(values[0], dict):
        raise OracleError("docker image inspect did not return exactly one image")
    record = values[0]
    if record.get("Architecture") != "arm64" or record.get("Os") != "linux":
        raise OracleError(
            f"container image must be linux/arm64, got {record.get('Os')}/{record.get('Architecture')}"
        )
    image_id = record.get("Id")
    if not isinstance(image_id, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise OracleError(f"container image has invalid immutable ID: {image_id!r}")
    return {
        "reference": image,
        "image_id": image_id,
        "os": record["Os"],
        "architecture": record["Architecture"],
    }


def _mount_arg(source: Path, destination: str) -> str:
    value = str(source)
    if any(character in value for character in (",", "\n", "\r")):
        raise OracleError(f"Docker --mount source contains an unsupported character: {source}")
    return f"type=bind,src={value},dst={destination},readonly"


def docker_base_command(
    docker: Path,
    image: str,
    xochitl: Path,
    usr_lib: Path,
    gdbserver: Path,
    *,
    entrypoint: str,
    interactive: bool,
    ptrace: bool,
    container_name: str | None = None,
) -> list[str]:
    verify_image_reference(image)
    command = [
        str(docker),
        "run",
        "--rm",
        "--platform",
        "linux/arm64",
        "--pull=never",
        "--network",
        "none",
        "--read-only",
        "--pids-limit",
        "64",
        "--memory",
        "512m",
        "--cpus",
        "2",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges=true",
        "--tmpfs",
        "/tmp:rw,nosuid,nodev,noexec,size=16m",
        "--hostname",
        "xochitl-oracle",
        "--workdir",
        "/tmp",
        "--env",
        "HOME=/tmp",
        "--mount",
        _mount_arg(xochitl, "/oracle/xochitl"),
        "--mount",
        _mount_arg(usr_lib, "/oracle/usr-lib"),
        "--mount",
        _mount_arg(gdbserver, "/oracle/gdbserver"),
    ]
    if interactive:
        command.append("--interactive")
    if ptrace:
        command.extend(("--cap-add", "SYS_PTRACE"))
    if container_name is not None:
        if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,62}", container_name):
            raise OracleError("invalid disposable container name")
        command.extend(("--name", container_name))
    command.extend(("--entrypoint", entrypoint, image))
    return command


def loader_list_command(
    docker: Path,
    image: str,
    xochitl: Path,
    usr_lib: Path,
    gdbserver: Path,
    container_name: str,
) -> list[str]:
    return docker_base_command(
        docker,
        image,
        xochitl,
        usr_lib,
        gdbserver,
        entrypoint="/oracle/usr-lib/ld-linux-aarch64.so.1",
        interactive=False,
        ptrace=False,
        container_name=container_name,
    ) + [
        "--inhibit-cache",
        "--library-path",
        "/oracle/usr-lib",
        "--list",
        "/oracle/xochitl",
    ]


def debugger_container_command(
    docker: Path,
    image: str,
    xochitl: Path,
    usr_lib: Path,
    gdbserver: Path,
    container_name: str,
) -> list[str]:
    return docker_base_command(
        docker,
        image,
        xochitl,
        usr_lib,
        gdbserver,
        entrypoint="/oracle/gdbserver",
        interactive=True,
        ptrace=True,
        container_name=container_name,
    ) + [
        "--once",
        "stdio",
        "/oracle/usr-lib/ld-linux-aarch64.so.1",
        "--inhibit-cache",
        "--library-path",
        "/oracle/usr-lib",
        "/oracle/xochitl",
    ]


def verify_runtime_closure(
    output: str, xochitl_record: dict[str, Any], usr_lib: Path
) -> list[dict[str, Any]]:
    if "not found" in output.lower():
        raise OracleError("firmware loader reported an unresolved dependency")
    paths = sorted(set(CONTAINER_LIBRARY_RE.findall(output)))
    if not paths:
        raise OracleError("firmware loader did not enumerate any /oracle/usr-lib dependencies")
    names_in_output = set()
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        names_in_output.add(stripped.split()[0])
        arrow = re.search(r"=>\s+(/[^\s(]+)", stripped)
        if arrow is not None and not arrow.group(1).startswith("/oracle/usr-lib/"):
            raise OracleError(
                f"loader resolved a dependency outside firmware usr/lib: {arrow.group(1)}"
            )
        # The firmware's absolute DT_INTERP name is printed on the left as
        # `/lib/ld-linux-aarch64.so.1 => ...`.  It is a request name, not the
        # loaded object.  Accept that shape only when the loader also reports
        # an explicit arrow target inside the read-only firmware mount.  A
        # bare absolute path still names the loaded object and must itself be
        # confined to /oracle/usr-lib.
        if stripped.startswith("/") and arrow is None:
            bare_path = stripped.split()[0]
            if not bare_path.startswith("/oracle/usr-lib/"):
                raise OracleError(
                    f"loader listed an absolute dependency outside firmware usr/lib: {bare_path}"
                )
    names_in_output.update(Path(path).name for path in paths)
    missing_direct = sorted(set(xochitl_record["needed"]) - names_in_output)
    if missing_direct:
        raise OracleError(
            "firmware loader output omitted direct DT_NEEDED entries: "
            + ", ".join(missing_direct)
        )

    records: list[dict[str, Any]] = []
    for container_path in paths:
        relative = container_path.removeprefix("/oracle/usr-lib/")
        host_path = usr_lib / relative
        try:
            resolved = host_path.resolve(strict=True)
        except FileNotFoundError as error:
            raise OracleError(f"loader-resolved file is absent on host: {host_path}") from error
        if not _is_within(resolved, usr_lib):
            raise OracleError(f"loader-resolved file escapes firmware usr/lib: {host_path}")
        if not resolved.is_file():
            raise OracleError(f"loader-resolved path is not a file: {host_path}")
        records.append(
            {
                "container_path": container_path,
                "host_path": str(host_path),
                "resolved_host_path": str(resolved),
                "size": resolved.stat().st_size,
                "sha256": sha256_file(resolved),
            }
        )
    if not any(Path(record["container_path"]).name == "libc.so.6" for record in records):
        raise OracleError("firmware loader closure did not contain libc.so.6")
    return records


def verify_host_gdb(gdb: Path) -> dict[str, Any]:
    if gdb.is_symlink() or not gdb.is_file() or not os.access(gdb, os.X_OK):
        raise OracleError(f"GDB must be an executable regular non-symlink file: {gdb}")
    result = subprocess.run(
        [
            str(gdb),
            "-q",
            "-nx",
            "-batch",
            "-ex",
            "set architecture aarch64",
            "-ex",
            "show architecture",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or "aarch64" not in result.stdout.lower():
        raise OracleError("host GDB does not accept the AArch64 architecture")
    version = subprocess.run(
        [str(gdb), "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        check=False,
    )
    if version.returncode != 0:
        raise OracleError("host GDB version query failed")
    return {
        "path": str(gdb),
        "sha256": sha256_file(gdb),
        "version_line": version.stdout.splitlines()[0] if version.stdout else "",
        "aarch64_probe": result.stdout.strip(),
    }


def build_gdb_command(
    gdb: Path,
    xochitl: Path,
    usr_lib: Path,
    gdb_script: Path,
    container_command: Sequence[str],
    layout: FixtureLayout,
    split_row: int | None = None,
    split_reverse: bool = False,
    mode7_sequence: bool = False,
    temperature_c: float = 25.0,
    bridge_sequence: str | None = None,
) -> list[str]:
    if mode7_sequence and bridge_sequence is not None:
        raise OracleError("mode-7 and bridge sequences are mutually exclusive")
    if bridge_sequence is not None and bridge_sequence not in BRIDGE_SEQUENCE_KINDS:
        raise OracleError(f"unsupported bridge sequence: {bridge_sequence}")
    oracle_kind = (
        BRIDGE_SEQUENCE_KINDS[bridge_sequence]
        if bridge_sequence is not None
        else 1 if mode7_sequence else 0
    )
    pipe_command = "target remote | " + shlex.join(container_command)
    return [
        str(gdb),
        "-q",
        "-nx",
        "-batch",
        str(xochitl),
        "-ex",
        "set architecture aarch64",
        "-ex",
        f"set solib-search-path {usr_lib}",
        "-ex",
        f"set $oracle_profile = {0 if layout.profile == 'minimal' else 1}",
        "-ex",
        f"set $oracle_rows = {layout.rows}",
        "-ex",
        f"set $oracle_storage_rows = {layout.storage_rows}",
        "-ex",
        f"set $oracle_source_left = {layout.source_left}",
        "-ex",
        f"set $oracle_source_top = {layout.source_top}",
        "-ex",
        f"set $oracle_source_right = {layout.source_right}",
        "-ex",
        f"set $oracle_source_bottom = {layout.source_bottom}",
        "-ex",
        f"set $oracle_source_stride = {layout.source_stride}",
        "-ex",
        f"set $oracle_ab_left = {layout.ab_left}",
        "-ex",
        f"set $oracle_ab_top = {layout.ab_top}",
        "-ex",
        f"set $oracle_ab_right = {layout.ab_right}",
        "-ex",
        f"set $oracle_ab_bottom = {layout.ab_bottom}",
        "-ex",
        f"set $oracle_ab_stride = {layout.ab_stride}",
        "-ex",
        f"set $oracle_update_left = {layout.update_left}",
        "-ex",
        f"set $oracle_update_top = {layout.update_top}",
        "-ex",
        f"set $oracle_update_right = {layout.update_right}",
        "-ex",
        f"set $oracle_update_bottom = {layout.update_bottom}",
        "-ex",
        f"set $oracle_output_stride = {layout.output_stride}",
        "-ex",
        f"set $oracle_y_first = {layout.y_first}",
        "-ex",
        f"set $oracle_y_last = {layout.y_last}",
        "-ex",
        f"set $oracle_split_row = {-1 if split_row is None else split_row}",
        "-ex",
        f"set $oracle_split_reverse = {1 if split_reverse else 0}",
        "-ex",
        f"set $oracle_kind = {oracle_kind}",
        "-ex",
        f"set $oracle_temperature_c = {temperature_c:.9g}",
        "-ex",
        f"set $oracle_ct33_bytes = {layout.ct33_bytes}",
        "-ex",
        f"set $oracle_ab_bytes = {layout.ab_bytes}",
        "-ex",
        f"set $oracle_output_bytes = {layout.output_bytes}",
        "-ex",
        f"set $oracle_palette_offset = {layout.palette_offset}",
        "-ex",
        f"set $oracle_delta_offset = {layout.delta_offset}",
        "-ex",
        f"set $oracle_ct33_offset = {layout.ct33_offset}",
        "-ex",
        f"set $oracle_ab_offset = {layout.ab_offset}",
        "-ex",
        f"set $oracle_output_offset = {layout.output_offset}",
        "-ex",
        f"set $oracle_redzone_bytes = {REDZONE_BYTES}",
        "-ex",
        f"set $oracle_arena_bytes = {layout.arena_bytes}",
        "-ex",
        pipe_command,
        "-x",
        str(gdb_script),
    ]


def _run_checked(
    command: Sequence[str], *, timeout: int, cwd: Path | None = None
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        list(command),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        raise OracleError(
            f"command failed with exit {result.returncode}: {shlex.join(command)}\n{result.stdout}"
        )
    return result


def run_gdb(
    command: Sequence[str], *, output: Path, timeout: int
) -> tuple[int, str]:
    process = subprocess.Popen(
        list(command),
        cwd=output,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, _ = process.communicate(timeout=5)
        raise OracleError(f"GDB oracle timed out after {timeout}s\n{stdout}")
    return process.returncode, stdout


def prove_container_absent(docker: Path, name: str) -> None:
    query = subprocess.run(
        [
            str(docker),
            "container",
            "ls",
            "--all",
            "--filter",
            f"name=^/{name}$",
            "--format",
            "{{.ID}}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
    )
    if query.returncode != 0:
        raise OracleError(f"cannot prove disposable container state: {query.stderr.strip()}")
    identifiers = [line.strip() for line in query.stdout.splitlines() if line.strip()]
    if identifiers:
        removed = subprocess.run(
            [str(docker), "container", "rm", "--force", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            check=False,
        )
        if removed.returncode != 0:
            raise OracleError(
                f"failed to terminate disposable container {name}: {removed.stderr.strip()}"
            )
        confirm = subprocess.run(
            [
                str(docker),
                "container",
                "ls",
                "--all",
                "--filter",
                f"name=^/{name}$",
                "--format",
                "{{.ID}}",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            check=False,
        )
        if confirm.returncode != 0 or confirm.stdout.strip():
            raise OracleError(f"disposable container {name} still exists after cleanup")


def _descriptor_words(path: Path) -> tuple[int, int, int, int, int, int, int, int]:
    data = path.read_bytes()
    if len(data) != 0x30:
        raise OracleError(f"descriptor has wrong size: {path}")
    begin, end, capacity = struct.unpack_from("<QQQ", data, 0)
    left, top, right, bottom = struct.unpack_from("<iiii", data, 0x18)
    stride = struct.unpack_from("<Q", data, 0x28)[0]
    return begin, end, capacity, left, top, right, bottom, stride


def validate_outputs(
    output: Path,
    layout: FixtureLayout,
    split_row: int | None = None,
    split_reverse: bool = False,
) -> dict[str, Any]:
    log_path = output / "oracle.gdb.log"
    if not log_path.is_file():
        raise OracleError("GDB did not produce oracle.gdb.log")
    log = log_path.read_text(encoding="utf-8", errors="replace")
    positions = [log.find(marker) for marker in MARKERS]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise OracleError("GDB completion markers are missing or out of order")
    if "ORACLE_REJECT" in log or log.count("ORACLE_POST_STORE") != 1:
        raise OracleError("GDB log contains a rejection or a non-single post-store stop")
    expected_calls = 1 if split_row is None else 2
    if log.count("ORACLE_SPLIT_PART_COMPLETE") != expected_calls - 1:
        raise OracleError("GDB log has the wrong split-part completion count")

    records: dict[str, Any] = {}
    for name, expected_size in layout.expected_dump_sizes().items():
        path = output / name
        if not path.is_file():
            raise OracleError(f"missing required oracle dump: {name}")
        size = path.stat().st_size
        if size != expected_size:
            raise OracleError(f"{name} has size {size}, expected {expected_size}")
        records[name] = {"size": size, "sha256": sha256_file(path)}

    input_pairs = (
        ("oracle.palette.input.bin", "oracle.palette.loaded.bin"),
        ("oracle.ct33.input.bin", "oracle.ct33.loaded.bin"),
        ("oracle.delta.input.bin", "oracle.delta.loaded.bin"),
        ("oracle.ab.input.bin", "oracle.ab.before.loaded.bin"),
    )
    for source_name, loaded_name in input_pairs:
        if (output / source_name).read_bytes() != (output / loaded_name).read_bytes():
            raise OracleError(f"inferior memory differs from staged input: {source_name}")

    redzone_input = output / "oracle.redzone.input.bin"
    if not redzone_input.is_file() or redzone_input.read_bytes() != REDZONE_PATTERN:
        raise OracleError("staged redzone pattern is missing or invalid")
    for name in BUFFER_NAMES:
        for side in ("pre", "post"):
            redzone = output / f"oracle.redzone.{name}.{side}.bin"
            if redzone.read_bytes() != REDZONE_PATTERN:
                raise OracleError(f"{name} {side}-redzone was modified")

    ctx = (output / "oracle.ctx.bin").read_bytes()
    src_pointer = struct.unpack_from("<Q", ctx, 0x00)[0]
    ct_pointer = struct.unpack_from("<Q", ctx, 0x10)[0]
    ctx_stride_a = struct.unpack_from("<Q", ctx, 0x28)[0]
    ctx_stride_b = struct.unpack_from("<Q", ctx, 0x30)[0]
    source_rect = struct.unpack_from("<iiii", ctx, 0x18)
    update = struct.unpack_from("<iiii", ctx, 0x38)
    wave_pointer = struct.unpack_from("<Q", ctx, 0x58)[0]
    outdesc_pointer = struct.unpack_from("<Q", ctx, 0x70)[0]
    if (
        ctx_stride_a != layout.source_stride
        or ctx_stride_b != layout.source_stride
        or source_rect
        != (
            layout.source_left,
            layout.source_top,
            layout.source_right,
            layout.source_bottom,
        )
        or update
        != (
            layout.update_left,
            layout.update_top,
            layout.update_right,
            layout.update_bottom,
        )
    ):
        raise OracleError("dumped context has the wrong stride or update rectangle")

    src = _descriptor_words(output / "oracle.srcdesc.bin")
    outdesc = _descriptor_words(output / "oracle.outdesc.bin")
    abdesc = _descriptor_words(output / "oracle.abdesc.synthetic.bin")
    if src_pointer == 0:
        raise OracleError("context has a null source descriptor")
    ctx_pointer = src_pointer - CTX_BYTES
    expected_wave = src_pointer + SOURCE_DESCRIPTOR_BYTES
    expected_outdesc = expected_wave + 0x40
    expected_palette = ctx_pointer + layout.palette_offset
    expected_delta = ctx_pointer + layout.delta_offset
    expected_ct33 = ctx_pointer + layout.ct33_offset
    expected_ab = ctx_pointer + layout.ab_offset
    expected_output = ctx_pointer + layout.output_offset
    wave_delta = struct.unpack_from(
        "<Q", (output / "oracle.wavedesc.bin").read_bytes(), 0x30
    )[0]
    if (
        ct_pointer != src[0]
        or src[1] - src[0] != layout.ct33_bytes
        or src[2] != src[1]
        or src[3:7]
        != (
            layout.source_left,
            layout.source_top,
            layout.source_right,
            layout.source_bottom,
        )
        or src[7] != layout.source_stride
    ):
        raise OracleError("source descriptor does not describe the ct33 input")
    if ct_pointer != expected_ct33:
        raise OracleError("ct33 pointer does not match the aligned arena layout")
    if wave_pointer != expected_wave:
        raise OracleError("context waveform descriptor pointer is invalid")
    if wave_delta != expected_delta:
        raise OracleError("wave descriptor delta pointer is invalid")
    if outdesc_pointer != expected_outdesc:
        raise OracleError("context output descriptor pointer is invalid")
    if (
        outdesc[0] != expected_output
        or outdesc[1] - outdesc[0] != layout.output_bytes
        or outdesc[2] != outdesc[1]
        or outdesc[3:7]
        != (
            layout.update_left,
            layout.update_top,
            layout.update_right,
            layout.update_bottom,
        )
        or outdesc[7] != layout.output_stride
    ):
        raise OracleError("output descriptor does not describe the output buffer")
    if (
        abdesc[0] != expected_ab
        or abdesc[1] - abdesc[0] != layout.ab_bytes
        or abdesc[2] != abdesc[1]
        or abdesc[3:7]
        != (
            layout.ab_left,
            layout.ab_top,
            layout.ab_right,
            layout.ab_bottom,
        )
        or abdesc[7] != layout.ab_stride
    ):
        raise OracleError("A/B descriptor does not describe the synthetic A/B plane")
    call_marker = re.search(
        r"ORACLE_CALL_BEGIN entry=0x004814a0 ctx=0x([0-9a-f]+) "
        r"palette=0x([0-9a-f]+) rows=([0-9]+)\.\.([0-9]+) "
        r"split=(-?[0-9]+) reverse=([01]) x4=0",
        log,
    )
    if call_marker is None or (
        int(call_marker.group(1), 16),
        int(call_marker.group(2), 16),
        int(call_marker.group(3)),
        int(call_marker.group(4)),
        int(call_marker.group(5)),
        int(call_marker.group(6)),
    ) != (
        ctx_pointer,
        expected_palette,
        layout.y_first,
        layout.y_last,
        -1 if split_row is None else split_row,
        1 if split_reverse else 0,
    ):
        raise OracleError("inferior-call marker disagrees with dumped arena pointers")
    post_marker = re.search(
        r"ORACLE_POST_STORE pc=0x483280 hit=([0-9]+) output=0x([0-9a-f]+) "
        r"bytes=0x([0-9a-f]+) ab=0x([0-9a-f]+) bytes=0x([0-9a-f]+)",
        log,
    )
    if post_marker is None or int(post_marker.group(1)) != expected_calls or tuple(
        int(post_marker.group(index), 16) for index in range(2, 6)
    ) != (expected_output, layout.output_bytes, expected_ab, layout.ab_bytes):
        raise OracleError("post-store marker disagrees with dumped arena pointers")
    if (output / "oracle.abdesc.original.bin").read_bytes() != (
        output / "oracle.abdesc.restored.bin"
    ).read_bytes():
        raise OracleError("fixed A/B descriptor was not restored before inferior kill")
    if (output / "oracle.ab.before.loaded.bin").read_bytes() == (
        output / "oracle.ab.after.bin"
    ).read_bytes():
        raise OracleError("nontrivial fixture produced no A/B transition")
    if not any((output / "oracle.output.after.bin").read_bytes()):
        raise OracleError("nontrivial fixture produced an all-zero output")
    return {"markers": list(MARKERS), "dumps": records}


def _signed16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def _encode_fast_history(history: int, flags: int) -> int:
    return (((history & 0xFFFF) << 2) & 0xFFFC) | (flags & 3)


def _binary32(value: float) -> float:
    try:
        runtime = struct.unpack("<f", struct.pack("<f", value))[0]
    except OverflowError as error:
        raise OracleError("temperature is outside finite binary32 range") from error
    if not math.isfinite(runtime):
        raise OracleError("temperature is outside finite binary32 range")
    return runtime


def _execution_extent(layout: FixtureLayout) -> tuple[int, int]:
    width = (layout.update_right - layout.update_left + 8) & ~7
    height = (layout.update_bottom - layout.update_top + 2) & ~1
    if width <= 0 or height <= 0:
        raise OracleError("rounded mapper execution extent is empty")
    return width, height


def _simulate_legacy_operation(
    layout: FixtureLayout,
    raw: bytes,
    ab_before: bytes,
    palette: bytes,
    delta_bytes: bytes,
) -> tuple[bytes, bytes]:
    """Independent scalar reconstruction of one frozen 0x004814a0 call."""
    width, height = _execution_extent(layout)
    if len(raw) != layout.ct33_bytes or len(ab_before) != layout.ab_bytes:
        raise OracleError("legacy scalar input has the wrong plane size")
    if len(palette) != PALETTE_BYTES or len(delta_bytes) != DELTA_BYTES:
        raise OracleError("legacy scalar palette/delta has the wrong size")
    delta = struct.unpack("<1024h", delta_bytes)

    raw_snapshot: list[int] = []
    a_snapshot: list[int] = []
    b_snapshot: list[int] = []
    for y in range(height):
        for x in range(width):
            raw_snapshot.append(raw[y * layout.source_stride + x])
            ab_index = 4 * (
                (layout.update_top + y) * layout.ab_stride
                + layout.update_left
                + x
            )
            old_a, old_b = struct.unpack_from("<HH", ab_before, ab_index)
            a_snapshot.append(old_a)
            b_snapshot.append(old_b)

    def tight(x: int, y: int) -> int:
        return y * width + x

    def in_domain(x: int, y: int) -> bool:
        return 0 <= x < width and 0 <= y < height

    mapped_snapshot: list[int] = []
    for raw_lane in raw_snapshot:
        index = raw_lane & 31
        if index >= len(palette) or palette[index] > 31:
            raise OracleError("legacy scalar encountered an unsupported palette state")
        mapped_snapshot.append(palette[index])

    commits: list[tuple[int, int, int]] = []
    output = bytearray(layout.output_bytes)
    cross = ((0, 0), (0, -1), (0, 1), (-1, 0), (1, 0))
    for y in range(height):
        for x in range(width):
            center = tight(x, y)
            old_a = a_snapshot[center]
            old_b = b_snapshot[center]
            raw_lane = raw_snapshot[center]
            source = old_a & 31
            mapped = mapped_snapshot[center]

            equal_moore = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if not in_domain(nx, ny):
                        equal_moore += 1
                    else:
                        neighbour = tight(nx, ny)
                        equal_moore += (
                            1
                            if (a_snapshot[neighbour] & 31)
                            == mapped_snapshot[neighbour]
                            else 0
                        )

            old_high_cross = 0
            new_high_cross = 0
            for dx, dy in cross:
                nx, ny = x + dx, y + dy
                if not in_domain(nx, ny):
                    old_high_cross += 1
                    new_high_cross += 1
                else:
                    neighbour = tight(nx, ny)
                    old_high_cross += (
                        1 if (a_snapshot[neighbour] & 31) > 27 else 0
                    )
                    new_high_cross += (
                        1 if mapped_snapshot[neighbour] > 27 else 0
                    )

            white_continuity = (
                (old_a & 0x80) != 0
                and (raw_lane & 0x80) != 0
                and source > 27
            )
            pair31 = (
                white_continuity
                and new_high_cross == 5
                and old_high_cross <= 4
            )
            force27 = (equal_moore == 9 or white_continuity) and not pair31
            drive = 31 if pair31 else 27 if force27 else mapped
            transition = source * 32 + drive

            carry_bit6 = (
                (old_a & 0x40) != 0 and source > 27 and mapped > 27
            )
            set_bit6 = (
                new_high_cross == 5
                and not pair31
                and not force27
                and (raw_lane & 0x80) != 0
                and mapped > 27
            )
            next_a = (
                (mapped & 31)
                | (raw_lane & 0x80)
                | (0x40 if carry_bit6 or set_bit6 else 0)
            )
            history = _signed16(old_b) >> 2
            history_sum = ((history & 0xFFFF) + (delta[transition] & 0xFFFF)) & 0xFFFF
            next_b = ((history_sum << 2) & 0xFFFC) | (
                (old_b & 3) if force27 else 0
            )
            ab_index = 4 * (
                (layout.update_top + y) * layout.ab_stride
                + layout.update_left
                + x
            )
            commits.append((ab_index, next_a, next_b))
            struct.pack_into(
                "<H", output, 2 * (y * layout.output_stride + x), transition
            )

    ab_after = bytearray(ab_before)
    for ab_index, next_a, next_b in commits:
        struct.pack_into("<HH", ab_after, ab_index, next_a, next_b)
    return bytes(ab_after), bytes(output)


def _fast_thermal(temperature_c: float) -> tuple[int, int, int]:
    # The inferior stores ctx+0x6c as binary32 before FCVTZS.  Quantize first:
    # a Python binary64 just below 38 can legitimately round to hot 38.0f.
    runtime_temperature = _binary32(temperature_c)
    return (
        (704, 2016, 2)
        if math.trunc(runtime_temperature) > 37
        else (576, 3456, 3)
    )


def _mode7_source_lane(
    old_a: int, old_b: int, raw: int, temperature_c: float
) -> tuple[int, int, int]:
    amplitude, limit, reset = _fast_thermal(temperature_c)
    source = old_a & 31
    history = _signed16(old_b) >> 2
    flags = old_b & 3
    white = (raw & 31) == 7
    mismatch = (source > 27) != white
    mid = 2 < source <= 27
    trial = history + (amplitude if white else -amplitude)
    hit = flags != 0 and abs(trial) <= limit
    partner = not mismatch and hit
    destination = (30 if partner else 28) if white else (0 if partner else 2)
    history2 = (
        trial
        if mismatch or hit
        else history + (16 if history < 0 else -16 if history > 0 else 0)
    )
    flags2 = reset if mismatch or mid else flags - (1 if partner else 0)
    next_a = (raw & 0x80) | destination
    next_b = _encode_fast_history(history2, flags2)
    return next_a, next_b, (source << 5) | destination


def _mode7_continuation_lane(
    old_a: int, old_b: int, temperature_c: float
) -> tuple[int, int, int]:
    amplitude, limit, _ = _fast_thermal(temperature_c)
    source = old_a & 31
    history = _signed16(old_b) >> 2
    flags = old_b & 3
    high = source > 27
    trial = history + (amplitude if high else -amplitude)
    hit = flags != 0 and abs(trial) <= limit
    history2 = (
        trial
        if hit
        else history + (16 if history < 0 else -16 if history > 0 else 0)
    )
    flags2 = flags - (1 if hit else 0)
    destination = (
        source
        if flags == 0
        else (30 if hit else 28) if high else (0 if hit else 2)
    )
    drive = 27 if flags == 0 else destination
    next_a = (old_a & 0x80) | destination
    next_b = _encode_fast_history(history2, flags2)
    return next_a, next_b, (source << 5) | drive


def _simulate_mode7_sequence(
    layout: FixtureLayout,
    raw: bytes,
    ab_before: bytes,
    temperature_c: float,
) -> tuple[bytes, bytes, bytes, bytes]:
    execution_width, execution_height = _execution_extent(layout)
    ab_source = bytearray(ab_before)
    output_source = bytearray(layout.output_bytes)
    for y in range(execution_height):
        for x in range(execution_width):
            raw_index = y * layout.source_stride + x
            ab_index = 4 * (
                (layout.update_top + y) * layout.ab_stride
                + layout.update_left
                + x
            )
            output_index = 2 * (y * layout.output_stride + x)
            old_a, old_b = struct.unpack_from("<HH", ab_source, ab_index)
            next_a, next_b, transition = _mode7_source_lane(
                old_a, old_b, raw[raw_index], temperature_c
            )
            struct.pack_into("<HH", ab_source, ab_index, next_a, next_b)
            struct.pack_into("<H", output_source, output_index, transition)

    ab_continuation = bytearray(ab_source)
    output_continuation = bytearray(layout.output_bytes)
    for y in range(execution_height):
        for x in range(execution_width):
            ab_index = 4 * (
                (layout.update_top + y) * layout.ab_stride
                + layout.update_left
                + x
            )
            output_index = 2 * (y * layout.output_stride + x)
            old_a, old_b = struct.unpack_from("<HH", ab_continuation, ab_index)
            next_a, next_b, transition = _mode7_continuation_lane(
                old_a, old_b, temperature_c
            )
            struct.pack_into("<HH", ab_continuation, ab_index, next_a, next_b)
            struct.pack_into("<H", output_continuation, output_index, transition)
    return (
        bytes(ab_source),
        bytes(output_source),
        bytes(ab_continuation),
        bytes(output_continuation),
    )


def _mode7_pending_expected(layout: FixtureLayout, ab: bytes) -> int:
    execution_width, execution_height = _execution_extent(layout)
    for y in range(execution_height):
        for x in range(execution_width):
            ab_index = 4 * (
                (layout.update_top + y) * layout.ab_stride
                + layout.update_left
                + x
            )
            if struct.unpack_from("<H", ab, ab_index + 2)[0] & 3:
                return 1
    return 0


def validate_mode7_sequence_outputs(
    output: Path, layout: FixtureLayout, temperature_c: float
) -> dict[str, Any]:
    log_path = output / "oracle.gdb.log"
    if not log_path.is_file():
        raise OracleError("GDB did not produce oracle.gdb.log")
    log = log_path.read_text(encoding="utf-8", errors="replace")
    markers = (
        "ORACLE_MAIN_READY",
        "ORACLE_FAST_SOURCE_BEGIN",
        "ORACLE_FAST_SOURCE_COMPLETE",
        "ORACLE_FAST_CONTINUATION_BEGIN",
        "ORACLE_FAST_CONTINUATION_COMPLETE",
        "ORACLE_FAST_SEQUENCE_COMPLETE",
    )
    positions = [log.find(marker) for marker in markers]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise OracleError("mode-7 GDB completion markers are missing or out of order")
    if "ORACLE_REJECT" in log:
        raise OracleError("mode-7 GDB log contains a rejection")
    if log.count("ORACLE_FAST_SOURCE_COMPLETE") != 1 or log.count(
        "ORACLE_FAST_CONTINUATION_COMPLETE"
    ) != 1:
        raise OracleError("mode-7 sequence did not complete exactly once per step")

    sizes = {
        "oracle.ctx.after-source.bin": CTX_BYTES,
        "oracle.ctx.bin": CTX_BYTES,
        "oracle.srcdesc.bin": SOURCE_DESCRIPTOR_BYTES,
        "oracle.wavedesc.bin": WAVE_DESCRIPTOR_BYTES,
        "oracle.outdesc.bin": OUTPUT_DESCRIPTOR_BYTES,
        "oracle.abdesc.original.bin": AB_DESCRIPTOR_BYTES,
        "oracle.abdesc.synthetic.bin": AB_DESCRIPTOR_BYTES,
        "oracle.abdesc.restored.bin": AB_DESCRIPTOR_BYTES,
        "oracle.palette.loaded.bin": PALETTE_BYTES,
        "oracle.ct33.loaded.bin": layout.ct33_bytes,
        "oracle.delta.loaded.bin": DELTA_BYTES,
        "oracle.ab.before.loaded.bin": layout.ab_bytes,
        "oracle.ab.after-source.bin": layout.ab_bytes,
        "oracle.output.after-source.bin": layout.output_bytes,
        "oracle.ab.after-continuation.bin": layout.ab_bytes,
        "oracle.output.after-continuation.bin": layout.output_bytes,
        "oracle.fast-global-pointer.original.bin": 8,
        "oracle.fast-global-pointer.restored.bin": 8,
        "oracle.fast-global.before-source.bin": FAST_GLOBAL_OWNER_BYTES,
        "oracle.fast-global.after-source.bin": FAST_GLOBAL_OWNER_BYTES,
        "oracle.fast-global.before-continuation.bin": FAST_GLOBAL_OWNER_BYTES,
        "oracle.fast-global.after-continuation.bin": FAST_GLOBAL_OWNER_BYTES,
        "oracle.redzone.fast-global.pre.bin": REDZONE_BYTES,
        "oracle.redzone.fast-global.post.bin": REDZONE_BYTES,
    }
    for name in BUFFER_NAMES:
        sizes[f"oracle.redzone.{name}.pre.bin"] = REDZONE_BYTES
        sizes[f"oracle.redzone.{name}.post.bin"] = REDZONE_BYTES
    records: dict[str, Any] = {}
    for name, expected_size in sizes.items():
        path = output / name
        if not path.is_file() or path.stat().st_size != expected_size:
            actual = path.stat().st_size if path.is_file() else -1
            raise OracleError(
                f"{name} has size {actual}, expected {expected_size}"
            )
        records[name] = {"size": expected_size, "sha256": sha256_file(path)}

    for source_name, loaded_name in (
        ("oracle.palette.input.bin", "oracle.palette.loaded.bin"),
        ("oracle.ct33.input.bin", "oracle.ct33.loaded.bin"),
        ("oracle.delta.input.bin", "oracle.delta.loaded.bin"),
        ("oracle.ab.input.bin", "oracle.ab.before.loaded.bin"),
    ):
        if (output / source_name).read_bytes() != (output / loaded_name).read_bytes():
            raise OracleError(f"inferior memory differs from staged input: {source_name}")
    if (output / "oracle.redzone.input.bin").read_bytes() != REDZONE_PATTERN:
        raise OracleError("staged redzone pattern is missing or invalid")
    for name in BUFFER_NAMES:
        for side in ("pre", "post"):
            if (
                output / f"oracle.redzone.{name}.{side}.bin"
            ).read_bytes() != REDZONE_PATTERN:
                raise OracleError(f"{name} {side}-redzone was modified")
    if (output / "oracle.abdesc.original.bin").read_bytes() != (
        output / "oracle.abdesc.restored.bin"
    ).read_bytes():
        raise OracleError("fixed A/B descriptor was not restored")
    if (output / "oracle.fast-global-pointer.original.bin").read_bytes() != (
        output / "oracle.fast-global-pointer.restored.bin"
    ).read_bytes():
        raise OracleError("mode-7 continuation-owner pointer was not restored")
    for side in ("pre", "post"):
        if (
            output / f"oracle.redzone.fast-global.{side}.bin"
        ).read_bytes() != REDZONE_PATTERN:
            raise OracleError(f"mode-7 continuation owner {side}-redzone was modified")

    ctx_source = (output / "oracle.ctx.after-source.bin").read_bytes()
    ctx_final = (output / "oracle.ctx.bin").read_bytes()
    if struct.unpack_from("<Q", ctx_source, 0)[0] == 0:
        raise OracleError("mode-7 source context unexpectedly has a null source")
    if struct.unpack_from("<Q", ctx_final, 0)[0] != 0:
        raise OracleError("mode-7 continuation context did not null the source")
    if struct.unpack_from("<h", ctx_final, 0x68)[0] != 7:
        raise OracleError("mode-7 context has the wrong mode")
    observed_temperature = struct.unpack_from("<f", ctx_final, 0x6C)[0]
    if struct.pack("<f", observed_temperature) != struct.pack("<f", temperature_c):
        raise OracleError("mode-7 context has the wrong temperature")
    if (ctx_final[0xAA] & 1) == 0:
        raise OracleError("mode-7 context gate bit is clear")

    src_pointer = struct.unpack_from("<Q", ctx_source, 0x00)[0]
    ct_pointer = struct.unpack_from("<Q", ctx_source, 0x10)[0]
    source_rect = struct.unpack_from("<iiii", ctx_source, 0x18)
    ctx_stride_a = struct.unpack_from("<Q", ctx_source, 0x28)[0]
    ctx_stride_b = struct.unpack_from("<Q", ctx_source, 0x30)[0]
    update = struct.unpack_from("<iiii", ctx_source, 0x38)
    wave_pointer = struct.unpack_from("<Q", ctx_source, 0x58)[0]
    outdesc_pointer = struct.unpack_from("<Q", ctx_source, 0x70)[0]
    if (
        ctx_stride_a != layout.source_stride
        or ctx_stride_b != layout.source_stride
        or source_rect
        != (
            layout.source_left,
            layout.source_top,
            layout.source_right,
            layout.source_bottom,
        )
        or update
        != (
            layout.update_left,
            layout.update_top,
            layout.update_right,
            layout.update_bottom,
        )
    ):
        raise OracleError("mode-7 context has the wrong stride or update rectangle")

    src = _descriptor_words(output / "oracle.srcdesc.bin")
    outdesc = _descriptor_words(output / "oracle.outdesc.bin")
    abdesc = _descriptor_words(output / "oracle.abdesc.synthetic.bin")
    ctx_pointer = src_pointer - CTX_BYTES
    expected_wave = src_pointer + SOURCE_DESCRIPTOR_BYTES
    expected_outdesc = expected_wave + 0x40
    expected_ct33 = ctx_pointer + layout.ct33_offset
    expected_delta = ctx_pointer + layout.delta_offset
    expected_ab = ctx_pointer + layout.ab_offset
    expected_output = ctx_pointer + layout.output_offset
    wave_delta = struct.unpack_from(
        "<Q", (output / "oracle.wavedesc.bin").read_bytes(), 0x30
    )[0]
    if (
        ct_pointer != src[0]
        or src[1] - src[0] != layout.ct33_bytes
        or src[2] != src[1]
        or src[3:7]
        != (
            layout.source_left,
            layout.source_top,
            layout.source_right,
            layout.source_bottom,
        )
        or src[7] != layout.source_stride
        or ct_pointer != expected_ct33
    ):
        raise OracleError("mode-7 source descriptor does not describe the raw input")
    if wave_pointer != expected_wave or wave_delta != expected_delta:
        raise OracleError("mode-7 waveform descriptor pointer is invalid")
    if outdesc_pointer != expected_outdesc or (
        outdesc[0] != expected_output
        or outdesc[1] - outdesc[0] != layout.output_bytes
        or outdesc[2] != outdesc[1]
        or outdesc[3:7]
        != (
            layout.update_left,
            layout.update_top,
            layout.update_right,
            layout.update_bottom,
        )
        or outdesc[7] != layout.output_stride
    ):
        raise OracleError("mode-7 output descriptor does not describe the output buffer")
    if (
        abdesc[0] != expected_ab
        or abdesc[1] - abdesc[0] != layout.ab_bytes
        or abdesc[2] != abdesc[1]
        or abdesc[3:7]
        != (
            layout.ab_left,
            layout.ab_top,
            layout.ab_right,
            layout.ab_bottom,
        )
        or abdesc[7] != layout.ab_stride
    ):
        raise OracleError("mode-7 A/B descriptor does not describe the synthetic plane")

    temperature_bits = struct.unpack("<I", struct.pack("<f", temperature_c))[0]
    source_marker = re.search(
        r"ORACLE_FAST_SOURCE_BEGIN entry=0x009af7c0 ctx=0x([0-9a-f]+) "
        r"temperature_bits=0x([0-9a-f]+) worker=0/1",
        log,
    )
    continuation_marker = re.search(
        r"ORACLE_FAST_CONTINUATION_BEGIN entry=0x009af7c0 "
        r"ctx=0x([0-9a-f]+) source=0 worker=0/1",
        log,
    )
    sequence_marker = re.search(
        r"ORACLE_FAST_SEQUENCE_COMPLETE entry=0x009af7c0 "
        r"update=(-?[0-9]+),(-?[0-9]+),(-?[0-9]+),(-?[0-9]+) "
        r"disposition=kill",
        log,
    )
    if source_marker is None or (
        int(source_marker.group(1), 16),
        int(source_marker.group(2), 16),
    ) != (ctx_pointer, temperature_bits):
        raise OracleError("mode-7 source marker disagrees with the dumped arena")
    if continuation_marker is None or int(
        continuation_marker.group(1), 16
    ) != ctx_pointer:
        raise OracleError("mode-7 continuation marker disagrees with the dumped arena")
    if sequence_marker is None or tuple(
        int(sequence_marker.group(index)) for index in range(1, 5)
    ) != (
        layout.update_left,
        layout.update_top,
        layout.update_right,
        layout.update_bottom,
    ):
        raise OracleError("mode-7 completion marker has the wrong update rectangle")

    expected = _simulate_mode7_sequence(
        layout,
        (output / "oracle.ct33.input.bin").read_bytes(),
        (output / "oracle.ab.input.bin").read_bytes(),
        temperature_c,
    )
    actual = tuple(
        (output / name).read_bytes()
        for name in (
            "oracle.ab.after-source.bin",
            "oracle.output.after-source.bin",
            "oracle.ab.after-continuation.bin",
            "oracle.output.after-continuation.bin",
        )
    )
    labels = (
        "source A/B",
        "source transitions",
        "continuation A/B",
        "continuation transitions",
    )
    for label, observed, wanted in zip(labels, actual, expected):
        if observed != wanted:
            mismatch = next(
                (index for index, pair in enumerate(zip(observed, wanted)) if pair[0] != pair[1]),
                min(len(observed), len(wanted)),
            )
            raise OracleError(f"mode-7 {label} differs at byte {mismatch}")

    owner_zero = bytes(FAST_GLOBAL_OWNER_BYTES)
    owner_source = bytearray(owner_zero)
    owner_source[FAST_CONTINUATION_PENDING_OFFSET] = _mode7_pending_expected(
        layout, expected[0]
    )
    owner_continuation = bytearray(owner_zero)
    owner_continuation[FAST_CONTINUATION_PENDING_OFFSET] = _mode7_pending_expected(
        layout, expected[2]
    )
    owner_actual = tuple(
        (output / name).read_bytes()
        for name in (
            "oracle.fast-global.before-source.bin",
            "oracle.fast-global.after-source.bin",
            "oracle.fast-global.before-continuation.bin",
            "oracle.fast-global.after-continuation.bin",
        )
    )
    owner_expected = (
        owner_zero,
        bytes(owner_source),
        owner_zero,
        bytes(owner_continuation),
    )
    if owner_actual != owner_expected:
        raise OracleError("mode-7 continuation-pending owner differs from scalar state")
    if actual[0] == (output / "oracle.ab.input.bin").read_bytes():
        raise OracleError("mode-7 source produced no A/B transition")
    if not any(actual[1]) or not any(actual[3]):
        raise OracleError("mode-7 sequence produced an all-zero transition plane")
    return {"markers": list(markers), "dumps": records, "scalar_parity": True}


def validate_bridge_sequence_outputs(
    output: Path,
    layout: FixtureLayout,
    temperature_c: float,
    sequence: str,
) -> dict[str, Any]:
    if sequence not in BRIDGE_SEQUENCE_KINDS:
        raise OracleError(f"unsupported bridge sequence: {sequence}")
    kind = BRIDGE_SEQUENCE_KINDS[sequence]
    log_path = output / "oracle.gdb.log"
    if not log_path.is_file():
        raise OracleError("GDB did not produce oracle.gdb.log")
    log = log_path.read_text(encoding="utf-8", errors="replace")
    markers = ["ORACLE_MAIN_READY", "ORACLE_BRIDGE_BEGIN"]
    if sequence == "legacy-fast-legacy":
        markers.extend(
            (
                "ORACLE_BRIDGE_LEGACY_BEFORE_FAST_BEGIN",
                "ORACLE_BRIDGE_LEGACY_BEFORE_FAST_COMPLETE",
            )
        )
    markers.extend(
        (
            "ORACLE_BRIDGE_FAST_SOURCE_BEGIN",
            "ORACLE_BRIDGE_FAST_SOURCE_COMPLETE",
        )
    )
    if sequence == "fast-continuation-legacy":
        markers.extend(
            (
                "ORACLE_BRIDGE_FAST_CONTINUATION_BEGIN",
                "ORACLE_BRIDGE_FAST_CONTINUATION_COMPLETE",
            )
        )
    markers.extend(
        (
            "ORACLE_BRIDGE_LEGACY_AFTER_FAST_BEGIN",
            "ORACLE_BRIDGE_LEGACY_AFTER_FAST_COMPLETE",
            "ORACLE_BRIDGE_COMPLETE",
        )
    )
    positions = [log.find(marker) for marker in markers]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise OracleError("bridge GDB completion markers are missing or out of order")
    if "ORACLE_REJECT" in log:
        raise OracleError("bridge GDB log contains a rejection")
    if log.count("ORACLE_BRIDGE_FAST_SOURCE_COMPLETE") != 1 or log.count(
        "ORACLE_BRIDGE_LEGACY_AFTER_FAST_COMPLETE"
    ) != 1:
        raise OracleError("bridge sequence did not complete each required stage once")
    if log.count("ORACLE_BRIDGE_FAST_CONTINUATION_COMPLETE") != (
        1 if sequence == "fast-continuation-legacy" else 0
    ):
        raise OracleError("bridge sequence has the wrong continuation count")

    stage_names: list[tuple[str, str]] = []
    if sequence == "legacy-fast-legacy":
        stage_names.append(
            (
                "oracle.ab.after-legacy-before-fast.bin",
                "oracle.output.after-legacy-before-fast.bin",
            )
        )
    stage_names.append(
        (
            "oracle.ab.after-fast-source.bin",
            "oracle.output.after-fast-source.bin",
        )
    )
    if sequence == "fast-continuation-legacy":
        stage_names.append(
            (
                "oracle.ab.after-fast-continuation.bin",
                "oracle.output.after-fast-continuation.bin",
            )
        )
    stage_names.append(
        (
            "oracle.ab.after-legacy-after-fast.bin",
            "oracle.output.after-legacy-after-fast.bin",
        )
    )

    owner_names = [
        "oracle.fast-global.before-fast-source.bin",
        "oracle.fast-global.after-fast-source.bin",
        "oracle.fast-global.before-legacy-after-fast.bin",
        "oracle.fast-global.after-legacy-after-fast.bin",
    ]
    if sequence == "legacy-fast-legacy":
        owner_names[0:0] = [
            "oracle.fast-global.before-legacy-before-fast.bin",
            "oracle.fast-global.after-legacy-before-fast.bin",
        ]
    if sequence == "fast-continuation-legacy":
        owner_names[2:2] = [
            "oracle.fast-global.before-fast-continuation.bin",
            "oracle.fast-global.after-fast-continuation.bin",
        ]

    sizes = {
        "oracle.ctx.bin": CTX_BYTES,
        "oracle.srcdesc.bin": SOURCE_DESCRIPTOR_BYTES,
        "oracle.wavedesc.bin": WAVE_DESCRIPTOR_BYTES,
        "oracle.outdesc.bin": OUTPUT_DESCRIPTOR_BYTES,
        "oracle.abdesc.original.bin": AB_DESCRIPTOR_BYTES,
        "oracle.abdesc.synthetic.bin": AB_DESCRIPTOR_BYTES,
        "oracle.abdesc.restored.bin": AB_DESCRIPTOR_BYTES,
        "oracle.palette.loaded.bin": PALETTE_BYTES,
        "oracle.ct33.loaded.bin": layout.ct33_bytes,
        "oracle.delta.loaded.bin": DELTA_BYTES,
        "oracle.ab.before.loaded.bin": layout.ab_bytes,
        "oracle.fast-global-pointer.original.bin": 8,
        "oracle.fast-global-pointer.restored.bin": 8,
        "oracle.redzone.fast-global.pre.bin": REDZONE_BYTES,
        "oracle.redzone.fast-global.post.bin": REDZONE_BYTES,
    }
    for ab_name, output_name in stage_names:
        sizes[ab_name] = layout.ab_bytes
        sizes[output_name] = layout.output_bytes
    for name in owner_names:
        sizes[name] = FAST_GLOBAL_OWNER_BYTES
    for name in BUFFER_NAMES:
        sizes[f"oracle.redzone.{name}.pre.bin"] = REDZONE_BYTES
        sizes[f"oracle.redzone.{name}.post.bin"] = REDZONE_BYTES
    records: dict[str, Any] = {}
    for name, expected_size in sizes.items():
        path = output / name
        if not path.is_file() or path.stat().st_size != expected_size:
            actual_size = path.stat().st_size if path.is_file() else -1
            raise OracleError(
                f"{name} has size {actual_size}, expected {expected_size}"
            )
        records[name] = {"size": expected_size, "sha256": sha256_file(path)}

    for source_name, loaded_name in (
        ("oracle.palette.input.bin", "oracle.palette.loaded.bin"),
        ("oracle.ct33.input.bin", "oracle.ct33.loaded.bin"),
        ("oracle.delta.input.bin", "oracle.delta.loaded.bin"),
        ("oracle.ab.input.bin", "oracle.ab.before.loaded.bin"),
    ):
        if (output / source_name).read_bytes() != (output / loaded_name).read_bytes():
            raise OracleError(f"inferior memory differs from staged input: {source_name}")
    if (output / "oracle.redzone.input.bin").read_bytes() != REDZONE_PATTERN:
        raise OracleError("staged redzone pattern is missing or invalid")
    for name in BUFFER_NAMES:
        for side in ("pre", "post"):
            if (
                output / f"oracle.redzone.{name}.{side}.bin"
            ).read_bytes() != REDZONE_PATTERN:
                raise OracleError(f"{name} {side}-redzone was modified")
    for side in ("pre", "post"):
        if (
            output / f"oracle.redzone.fast-global.{side}.bin"
        ).read_bytes() != REDZONE_PATTERN:
            raise OracleError(f"bridge continuation owner {side}-redzone was modified")
    if (output / "oracle.abdesc.original.bin").read_bytes() != (
        output / "oracle.abdesc.restored.bin"
    ).read_bytes():
        raise OracleError("fixed A/B descriptor was not restored after bridge")
    if (output / "oracle.fast-global-pointer.original.bin").read_bytes() != (
        output / "oracle.fast-global-pointer.restored.bin"
    ).read_bytes():
        raise OracleError("continuation-owner pointer was not restored after bridge")

    ctx = (output / "oracle.ctx.bin").read_bytes()
    src_pointer = struct.unpack_from("<Q", ctx, 0x00)[0]
    ct_pointer = struct.unpack_from("<Q", ctx, 0x10)[0]
    source_rect = struct.unpack_from("<iiii", ctx, 0x18)
    ctx_stride_a = struct.unpack_from("<Q", ctx, 0x28)[0]
    ctx_stride_b = struct.unpack_from("<Q", ctx, 0x30)[0]
    update = struct.unpack_from("<iiii", ctx, 0x38)
    wave_pointer = struct.unpack_from("<Q", ctx, 0x58)[0]
    outdesc_pointer = struct.unpack_from("<Q", ctx, 0x70)[0]
    if (
        src_pointer == 0
        or struct.unpack_from("<h", ctx, 0x68)[0] != 2
        or (ctx[0xA0], ctx[0xA1], ctx[0xA2], ctx[0xAA]) != (0, 0, 0, 0)
        or ctx_stride_a != layout.source_stride
        or ctx_stride_b != layout.source_stride
        or source_rect
        != (
            layout.source_left,
            layout.source_top,
            layout.source_right,
            layout.source_bottom,
        )
        or update
        != (
            layout.update_left,
            layout.update_top,
            layout.update_right,
            layout.update_bottom,
        )
    ):
        raise OracleError("final bridge context was not rebuilt as legacy mode")
    observed_temperature = struct.unpack_from("<f", ctx, 0x6C)[0]
    if struct.pack("<f", observed_temperature) != struct.pack("<f", temperature_c):
        raise OracleError("final bridge context lost the requested temperature")

    src = _descriptor_words(output / "oracle.srcdesc.bin")
    outdesc = _descriptor_words(output / "oracle.outdesc.bin")
    abdesc = _descriptor_words(output / "oracle.abdesc.synthetic.bin")
    ctx_pointer = src_pointer - CTX_BYTES
    expected_wave = src_pointer + SOURCE_DESCRIPTOR_BYTES
    expected_outdesc = expected_wave + 0x40
    expected_ct33 = ctx_pointer + layout.ct33_offset
    expected_delta = ctx_pointer + layout.delta_offset
    expected_ab = ctx_pointer + layout.ab_offset
    expected_output = ctx_pointer + layout.output_offset
    wave_delta = struct.unpack_from(
        "<Q", (output / "oracle.wavedesc.bin").read_bytes(), 0x30
    )[0]
    if (
        ct_pointer != expected_ct33
        or ct_pointer != src[0]
        or src[1] - src[0] != layout.ct33_bytes
        or src[2] != src[1]
        or src[3:7]
        != (
            layout.source_left,
            layout.source_top,
            layout.source_right,
            layout.source_bottom,
        )
        or src[7] != layout.source_stride
    ):
        raise OracleError("bridge source descriptor does not describe the raw input")
    if wave_pointer != expected_wave or wave_delta != expected_delta:
        raise OracleError("bridge waveform descriptor pointer is invalid")
    if outdesc_pointer != expected_outdesc or (
        outdesc[0] != expected_output
        or outdesc[1] - outdesc[0] != layout.output_bytes
        or outdesc[2] != outdesc[1]
        or outdesc[3:7]
        != (
            layout.update_left,
            layout.update_top,
            layout.update_right,
            layout.update_bottom,
        )
        or outdesc[7] != layout.output_stride
    ):
        raise OracleError("bridge output descriptor does not describe the output buffer")
    if (
        abdesc[0] != expected_ab
        or abdesc[1] - abdesc[0] != layout.ab_bytes
        or abdesc[2] != abdesc[1]
        or abdesc[3:7]
        != (
            layout.ab_left,
            layout.ab_top,
            layout.ab_right,
            layout.ab_bottom,
        )
        or abdesc[7] != layout.ab_stride
    ):
        raise OracleError("bridge A/B descriptor does not describe the synthetic plane")

    temperature_bits = struct.unpack("<I", struct.pack("<f", temperature_c))[0]
    begin_marker = re.search(
        r"ORACLE_BRIDGE_BEGIN kind=([234]) ctx=0x([0-9a-f]+) "
        r"temperature_bits=0x([0-9a-f]+) "
        r"update=(-?[0-9]+),(-?[0-9]+),(-?[0-9]+),(-?[0-9]+)",
        log,
    )
    if begin_marker is None or (
        int(begin_marker.group(1)),
        int(begin_marker.group(2), 16),
        int(begin_marker.group(3), 16),
        *(int(begin_marker.group(index)) for index in range(4, 8)),
    ) != (
        kind,
        ctx_pointer,
        temperature_bits,
        layout.update_left,
        layout.update_top,
        layout.update_right,
        layout.update_bottom,
    ):
        raise OracleError("bridge begin marker disagrees with the dumped arena")
    completion_marker = re.search(
        r"ORACLE_BRIDGE_COMPLETE kind=([234]) "
        r"update=(-?[0-9]+),(-?[0-9]+),(-?[0-9]+),(-?[0-9]+) "
        r"disposition=kill",
        log,
    )
    if completion_marker is None or tuple(
        int(completion_marker.group(index)) for index in range(1, 6)
    ) != (
        kind,
        layout.update_left,
        layout.update_top,
        layout.update_right,
        layout.update_bottom,
    ):
        raise OracleError("bridge completion marker has the wrong sequence or update")

    raw = (output / "oracle.ct33.input.bin").read_bytes()
    palette = (output / "oracle.palette.input.bin").read_bytes()
    delta = (output / "oracle.delta.input.bin").read_bytes()
    initial_ab = (output / "oracle.ab.input.bin").read_bytes()
    expected_stages: list[tuple[bytes, bytes]] = []
    if sequence == "legacy-fast-legacy":
        legacy_before = _simulate_legacy_operation(
            layout, raw, initial_ab, palette, delta
        )
        expected_stages.append(legacy_before)
        fast = _simulate_mode7_sequence(layout, raw, legacy_before[0], temperature_c)
        expected_stages.append((fast[0], fast[1]))
        expected_stages.append(
            _simulate_legacy_operation(layout, raw, fast[0], palette, delta)
        )
    else:
        fast = _simulate_mode7_sequence(layout, raw, initial_ab, temperature_c)
        expected_stages.append((fast[0], fast[1]))
        legacy_input = fast[0]
        if sequence == "fast-continuation-legacy":
            if _mode7_pending_expected(layout, fast[0]) == 0:
                raise OracleError("bridge fixture has no pending Fast continuation")
            expected_stages.append((fast[2], fast[3]))
            legacy_input = fast[2]
        expected_stages.append(
            _simulate_legacy_operation(layout, raw, legacy_input, palette, delta)
        )

    for (ab_name, output_name), (expected_ab_stage, expected_output_stage) in zip(
        stage_names, expected_stages
    ):
        for label, observed, wanted in (
            (ab_name, (output / ab_name).read_bytes(), expected_ab_stage),
            (output_name, (output / output_name).read_bytes(), expected_output_stage),
        ):
            if observed != wanted:
                mismatch = next(
                    (
                        index
                        for index, pair in enumerate(zip(observed, wanted))
                        if pair[0] != pair[1]
                    ),
                    min(len(observed), len(wanted)),
                )
                raise OracleError(f"bridge {label} differs at byte {mismatch}")

    owner_zero = bytes(FAST_GLOBAL_OWNER_BYTES)
    owner_source = bytearray(owner_zero)
    source_ab = expected_stages[1][0] if sequence == "legacy-fast-legacy" else expected_stages[0][0]
    owner_source[FAST_CONTINUATION_PENDING_OFFSET] = _mode7_pending_expected(
        layout, source_ab
    )
    owner_after_active_fast = bytes(owner_source)
    expected_owners: dict[str, bytes] = {
        "oracle.fast-global.before-fast-source.bin": owner_zero,
        "oracle.fast-global.after-fast-source.bin": bytes(owner_source),
    }
    if sequence == "legacy-fast-legacy":
        expected_owners.update(
            {
                "oracle.fast-global.before-legacy-before-fast.bin": owner_zero,
                "oracle.fast-global.after-legacy-before-fast.bin": owner_zero,
            }
        )
    if sequence == "fast-continuation-legacy":
        continuation_ab = expected_stages[1][0]
        owner_continuation = bytearray(owner_zero)
        owner_continuation[
            FAST_CONTINUATION_PENDING_OFFSET
        ] = _mode7_pending_expected(layout, continuation_ab)
        expected_owners.update(
            {
                "oracle.fast-global.before-fast-continuation.bin": owner_zero,
                "oracle.fast-global.after-fast-continuation.bin": bytes(
                    owner_continuation
                ),
            }
        )
        owner_after_active_fast = bytes(owner_continuation)
    expected_owners.update(
        {
            "oracle.fast-global.before-legacy-after-fast.bin": owner_after_active_fast,
            "oracle.fast-global.after-legacy-after-fast.bin": owner_after_active_fast,
        }
    )
    for name, wanted in expected_owners.items():
        if (output / name).read_bytes() != wanted:
            raise OracleError(f"bridge continuation owner differs at {name}")

    source_pending = _mode7_pending_expected(layout, source_ab)
    source_marker = re.search(
        r"ORACLE_BRIDGE_FAST_SOURCE_COMPLETE return=0x([0-9a-f]+) "
        r"pending=([01])",
        log,
    )
    if source_marker is None or (
        int(source_marker.group(1), 16),
        int(source_marker.group(2)),
    ) != (MAIN_READY, source_pending):
        raise OracleError("bridge Fast-source marker disagrees with scalar state")
    if sequence == "fast-continuation-legacy":
        continuation_pending = _mode7_pending_expected(layout, expected_stages[1][0])
        continuation_marker = re.search(
            r"ORACLE_BRIDGE_FAST_CONTINUATION_COMPLETE "
            r"return=0x([0-9a-f]+) pending=([01])",
            log,
        )
        if continuation_marker is None or (
            int(continuation_marker.group(1), 16),
            int(continuation_marker.group(2)),
        ) != (MAIN_READY, continuation_pending):
            raise OracleError("bridge continuation marker disagrees with scalar state")

    return {
        "markers": markers,
        "dumps": records,
        "scalar_parity": True,
        "sequence": sequence,
        "known_non_ab_state": {
            "continuation_pending_owner_offset": FAST_CONTINUATION_PENDING_OFFSET,
            "other_owner_bytes_changed": False,
            "legacy_mapper_changed_owner": False,
        },
    }


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    repo = Path(__file__).resolve().parents[4]
    parser = argparse.ArgumentParser(
        description="Disposable offline exact-Xochitl active-mapper oracle"
    )
    parser.add_argument("--execute", action="store_true", help="required safety acknowledgement")
    parser.add_argument("--xochitl", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument(
        "--gdbserver",
        type=Path,
        default=repo / "build/device-tools/pluto-gdbserver-aarch64",
    )
    parser.add_argument("--image", required=True, help="local linux/arm64 image by digest")
    geometry = parser.add_mutually_exclusive_group(required=True)
    geometry.add_argument(
        "--rows",
        type=int,
        choices=(1, 2),
        help="minimal width-one scalar fixture with one/two update rows",
    )
    parser.add_argument(
        "--split-row",
        type=int,
        help=(
            "diagnostic two-call differential: second mapper call starts at "
            "this absolute row; both row partitions must be nonempty/even"
        ),
    )
    parser.add_argument(
        "--split-reverse",
        action="store_true",
        help="run the bottom split partition before the top partition",
    )
    parser.add_argument(
        "--mode7-sequence",
        action="store_true",
        help=(
            "run the production-disconnected mode-7 non-null-source mapper "
            "followed immediately by one null-source continuation"
        ),
    )
    parser.add_argument(
        "--bridge-sequence",
        choices=tuple(BRIDGE_SEQUENCE_KINDS),
        help=(
            "run a production-disconnected composed legacy/Fast state bridge; "
            "each call returns through the installed binary's signed epilogue"
        ),
    )
    parser.add_argument(
        "--temperature-c",
        type=float,
        default=25.0,
        help="mode-7/bridge sequence temperature (finite; default 25 C)",
    )
    geometry.add_argument(
        "--panel-rect",
        type=int,
        nargs=4,
        metavar=("LEFT", "TOP", "WIDTH", "HEIGHT"),
        help=(
            "exact panel/A-B geometry with a maximum-size operation-local "
            "ct33 safety buffer and this update rectangle"
        ),
    )
    parser.add_argument("--palette", required=True, type=Path)
    parser.add_argument("--ct33", required=True, type=Path)
    parser.add_argument("--delta", required=True, type=Path)
    parser.add_argument("--ab", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--gdb", type=Path, default=Path(shutil.which("gdb") or "gdb"))
    parser.add_argument("--docker", type=Path, default=Path(shutil.which("docker") or "docker"))
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args(argv)
    if not args.execute:
        parser.error("--execute is required; this tool never launches implicitly")
    if not 30 <= args.timeout <= 600:
        parser.error("--timeout must be in 30..600 seconds")
    if not math.isfinite(args.temperature_c):
        parser.error("--temperature-c must be finite")
    try:
        _binary32(args.temperature_c)
    except OracleError as error:
        parser.error(str(error))
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    layout = (
        FixtureLayout.for_rows(args.rows)
        if args.rows is not None
        else FixtureLayout.for_panel(*args.panel_rect)
    )
    split_row = args.split_row
    if args.mode7_sequence and args.bridge_sequence is not None:
        raise OracleError("--mode7-sequence and --bridge-sequence are mutually exclusive")
    if (args.mode7_sequence or args.bridge_sequence is not None) and split_row is not None:
        raise OracleError("mode-7/bridge sequences cannot be combined with --split-row")
    if args.split_reverse and split_row is None:
        raise OracleError("--split-reverse requires --split-row")
    if split_row is not None:
        first_rows = split_row - layout.y_first
        second_rows = layout.y_last - split_row + 1
        if first_rows <= 0 or second_rows <= 0 or first_rows % 2 or second_rows % 2:
            raise OracleError(
                "--split-row must divide the update into two nonempty even-row partitions"
            )
    xochitl = args.xochitl.resolve(strict=True)
    rootfs = args.rootfs.resolve(strict=True)
    gdbserver = args.gdbserver.resolve(strict=True)
    gdb = args.gdb.resolve(strict=True)
    docker = args.docker.resolve(strict=True)
    inputs = {
        "palette": args.palette.resolve(strict=True),
        "ct33": args.ct33.resolve(strict=True),
        "delta": args.delta.resolve(strict=True),
        "ab": args.ab.resolve(strict=True),
    }
    output = args.output.expanduser().resolve(strict=False)
    if output.exists() or output.is_symlink():
        raise OracleError(f"output must not already exist: {output}")
    if not output.parent.is_dir():
        raise OracleError(f"output parent does not exist: {output.parent}")

    xochitl_record = verify_xochitl(xochitl)
    gdbserver_record = verify_gdbserver(gdbserver)
    usr_lib, rootfs_record = verify_rootfs(rootfs)
    input_records = {
        "palette": verify_input(inputs["palette"], PALETTE_BYTES, "palette"),
        "ct33": verify_input(inputs["ct33"], layout.ct33_bytes, "ct33"),
        "delta": verify_input(inputs["delta"], DELTA_BYTES, "delta"),
        "ab": verify_input(inputs["ab"], layout.ab_bytes, "A/B"),
    }
    gdb_record = verify_host_gdb(gdb)
    image_record = inspect_container_image(docker, args.image)
    docker_record = {
        "path": str(docker),
        "size": docker.stat().st_size,
        "sha256": sha256_file(docker),
    }
    runner_path = Path(__file__).resolve(strict=True)
    gdb_script = runner_path.with_name("xochitl_mapper_oracle.gdb").resolve(
        strict=True
    )
    oracle_sources = {
        "runner": {
            "path": str(runner_path),
            "size": runner_path.stat().st_size,
            "sha256": sha256_file(runner_path),
        },
        "gdb_script": {
            "path": str(gdb_script),
            "size": gdb_script.stat().st_size,
            "sha256": sha256_file(gdb_script),
        },
    }

    output.mkdir(mode=0o700)
    staged_names = {
        "palette": "oracle.palette.input.bin",
        "ct33": "oracle.ct33.input.bin",
        "delta": "oracle.delta.input.bin",
        "ab": "oracle.ab.input.bin",
    }
    for label, name in staged_names.items():
        shutil.copyfile(inputs[label], output / name)
    (output / "oracle.redzone.input.bin").write_bytes(REDZONE_PATTERN)
    if args.mode7_sequence or args.bridge_sequence is not None:
        (output / "oracle.output.zero.bin").write_bytes(bytes(layout.output_bytes))

    closure_container_name = (
        f"pluto-xochitl-closure-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    )
    loader_command = loader_list_command(
        docker,
        args.image,
        xochitl,
        usr_lib,
        gdbserver,
        closure_container_name,
    )
    closure_result: subprocess.CompletedProcess[str] | None = None
    closure_error: BaseException | None = None
    closure_cleanup_error: BaseException | None = None
    try:
        closure_result = _run_checked(loader_command, timeout=60)
    except BaseException as error:
        closure_error = error
    finally:
        try:
            prove_container_absent(docker, closure_container_name)
        except BaseException as error:
            closure_cleanup_error = error
    if closure_error is not None:
        if closure_cleanup_error is not None:
            raise OracleError(
                f"loader closure failed ({closure_error}); cleanup proof also failed "
                f"({closure_cleanup_error})"
            ) from closure_error
        raise closure_error
    if closure_cleanup_error is not None:
        raise closure_cleanup_error
    if closure_result is None:
        raise AssertionError("loader closure completed without a result")
    (output / "oracle.loader-list.log").write_text(
        closure_result.stdout, encoding="utf-8"
    )
    closure = verify_runtime_closure(closure_result.stdout, xochitl_record, usr_lib)

    container_name = f"pluto-xochitl-oracle-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    container_command = debugger_container_command(
        docker, args.image, xochitl, usr_lib, gdbserver, container_name
    )
    gdb_command = build_gdb_command(
        gdb,
        xochitl,
        usr_lib,
        gdb_script,
        container_command,
        layout,
        split_row,
        args.split_reverse,
        args.mode7_sequence,
        args.temperature_c,
        args.bridge_sequence,
    )
    oracle_kind = (
        f"bridge-{args.bridge_sequence}"
        if args.bridge_sequence is not None
        else "mode7-source-continuation" if args.mode7_sequence else "legacy"
    )
    preflight = {
        "schema": 1,
        "status": "preflight-complete-execution-not-yet-proven",
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "xochitl": xochitl_record,
        "gdbserver": gdbserver_record,
        "rootfs": rootfs_record,
        "inputs": input_records,
        "layout": dataclasses.asdict(layout),
        "mapper_split_row": split_row,
        "mapper_split_reverse": args.split_reverse,
        "oracle_kind": oracle_kind,
        "temperature_c": (
            args.temperature_c
            if args.mode7_sequence or args.bridge_sequence is not None
            else None
        ),
        "container_image": image_record,
        "host_gdb": gdb_record,
        "docker_cli": docker_record,
        "oracle_sources": oracle_sources,
        "redzone": {
            "bytes_each": REDZONE_BYTES,
            "buffer_count": len(BUFFER_NAMES),
            "sha256": hashlib.sha256(REDZONE_PATTERN).hexdigest(),
        },
        "runtime_closure": closure,
        "loader_list_command": loader_command,
        "debugger_container_command": container_command,
        "gdb_command": gdb_command,
        "safety": {
            "network": "none",
            "device_access": False,
            "ssh": False,
            "production_attach": False,
            "container_read_only": True,
            "remote_transport": "gdbserver-stdio",
        },
    }
    _write_json(output / "oracle.preflight.json", preflight)

    gdb_returncode = -1
    gdb_stdout = ""
    execution_error: BaseException | None = None
    cleanup_error: BaseException | None = None
    try:
        gdb_returncode, gdb_stdout = run_gdb(
            gdb_command, output=output, timeout=args.timeout
        )
        (output / "oracle.host-gdb.stdout.log").write_text(
            gdb_stdout, encoding="utf-8"
        )
        if gdb_returncode != 0:
            raise OracleError(
                f"GDB oracle failed with exit {gdb_returncode}\n{gdb_stdout}"
            )
    except BaseException as error:
        execution_error = error
    finally:
        try:
            prove_container_absent(docker, container_name)
        except BaseException as error:
            cleanup_error = error
    if execution_error is not None:
        if cleanup_error is not None:
            raise OracleError(
                f"oracle execution failed ({execution_error}); cleanup proof also failed ({cleanup_error})"
            ) from execution_error
        raise execution_error
    if cleanup_error is not None:
        raise cleanup_error

    if args.bridge_sequence is not None:
        validation = validate_bridge_sequence_outputs(
            output, layout, args.temperature_c, args.bridge_sequence
        )
    elif args.mode7_sequence:
        validation = validate_mode7_sequence_outputs(
            output, layout, args.temperature_c
        )
    else:
        validation = validate_outputs(
            output, layout, split_row, args.split_reverse
        )

    # Close races against changed bind-mounted input or runtime files.
    if verify_xochitl(xochitl) != xochitl_record:
        raise OracleError("Xochitl identity changed during the oracle run")
    if verify_gdbserver(gdbserver) != gdbserver_record:
        raise OracleError("gdbserver identity changed during the oracle run")
    if sha256_file(gdb) != gdb_record["sha256"]:
        raise OracleError("host GDB changed during the oracle run")
    if sha256_file(docker) != docker_record["sha256"]:
        raise OracleError("Docker CLI changed during the oracle run")
    for label, record in oracle_sources.items():
        source = Path(record["path"])
        if source.stat().st_size != record["size"] or sha256_file(source) != record[
            "sha256"
        ]:
            raise OracleError(f"oracle {label} changed during the oracle run")
    if inspect_container_image(docker, args.image) != image_record:
        raise OracleError("pinned container image identity changed during the oracle run")
    _, rootfs_after = verify_rootfs(rootfs)
    if rootfs_after != rootfs_record:
        raise OracleError("firmware usr/lib tree changed during the oracle run")
    for label, record in input_records.items():
        after = verify_input(inputs[label], record["size"], label)
        if after != record:
            raise OracleError(f"{label} input changed during the oracle run")

    manifest = {
        **preflight,
        "status": "complete",
        "completed_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "execution": {
            "gdb_returncode": gdb_returncode,
            "container_absent_after_run": True,
            "mapper_entry": (
                [f"0x{MAPPER_ENTRY:08x}", f"0x{FAST_DISPATCHER_ENTRY:08x}"]
                if args.bridge_sequence is not None
                else f"0x{FAST_DISPATCHER_ENTRY if args.mode7_sequence else MAPPER_ENTRY:08x}"
            ),
            "launch": "scheduler-locked-register-entry",
            "mapper_calls": (
                len(BRIDGE_SEQUENCE_CALLS[args.bridge_sequence])
                if args.bridge_sequence is not None
                else 2 if args.mode7_sequence else 1 if split_row is None else 2
            ),
            "split_row": split_row,
            "split_reverse": args.split_reverse,
            **(
                {
                    "worker_index": 0,
                    "worker_count": 1,
                    "dispatcher_token_x3": 0,
                    "signed_return_stop": f"0x{MAIN_READY:08x}",
                    "sequence": ["non-null-source", "null-source-continuation"],
                    "terminated_after_sequence": True,
                }
                if args.mode7_sequence
                else {
                    **(
                        {
                            "barrier_x4": 0,
                            "signed_return_stop": f"0x{MAIN_READY:08x}",
                            "sequence": list(
                                BRIDGE_SEQUENCE_CALLS[args.bridge_sequence]
                            ),
                            "terminated_after_sequence": True,
                        }
                        if args.bridge_sequence is not None
                        else {
                            "barrier_x4": 0,
                            "post_store_stop": f"0x{POST_STORE:08x}",
                            "terminated_at_post_store": True,
                        }
                    )
                }
            ),
        },
        "validation": validation,
    }
    _write_json(output / "oracle-manifest.json", manifest)
    print(
        f"ORACLE_BUNDLE_COMPLETE profile={layout.profile} "
        f"update={layout.update_left},{layout.update_top},"
        f"{layout.update_right},{layout.update_bottom} output={output} "
        f"manifest={output / 'oracle-manifest.json'}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OracleError, FileNotFoundError, subprocess.TimeoutExpired) as error:
        print(f"ORACLE_ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
