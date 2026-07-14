#!/usr/bin/env python3
"""Read and extract a firmware ext4 filesystem without mounting it.

This is deliberately a small, read-only parser for diagnostic firmware images.
The source is opened O_RDONLY, extents are range checked, device nodes are never
created, and extraction is confined to a new directory below /private/tmp.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import stat
import struct
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterator, Sequence


EXT4_SUPER_MAGIC = 0xEF53
EXT4_EXT_MAGIC = 0xF30A
EXT4_EXTENTS_FL = 0x00080000

EXT4_FEATURE_INCOMPAT_FILETYPE = 0x0002
EXT4_FEATURE_INCOMPAT_EXTENTS = 0x0040
EXT4_FEATURE_INCOMPAT_64BIT = 0x0080
EXT4_FEATURE_INCOMPAT_FLEX_BG = 0x0200
SUPPORTED_INCOMPAT = (
    EXT4_FEATURE_INCOMPAT_FILETYPE
    | EXT4_FEATURE_INCOMPAT_EXTENTS
    | EXT4_FEATURE_INCOMPAT_64BIT
    | EXT4_FEATURE_INCOMPAT_FLEX_BG
)

MAX_EXTENT_DEPTH = 5
MAX_SYMLINKS = 40
COPY_CHUNK = 1024 * 1024
ZERO_CHUNK = bytes(1024 * 1024)
DEFAULT_ALLOWED_OUTPUT_PARENT = Path("/private/tmp")


class Ext4Error(RuntimeError):
    """The image is unsupported or structurally inconsistent."""


class ExtractionSafetyError(RuntimeError):
    """An extraction destination violates the confinement contract."""


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


@dataclass(frozen=True)
class Inode:
    number: int
    mode: int
    size: int
    flags: int
    block_data: bytes
    links: int

    @property
    def kind(self) -> str:
        if stat.S_ISREG(self.mode):
            return "file"
        if stat.S_ISDIR(self.mode):
            return "directory"
        if stat.S_ISLNK(self.mode):
            return "symlink"
        if stat.S_ISCHR(self.mode):
            return "char-device"
        if stat.S_ISBLK(self.mode):
            return "block-device"
        if stat.S_ISFIFO(self.mode):
            return "fifo"
        if stat.S_ISSOCK(self.mode):
            return "socket"
        return "unknown"


@dataclass(frozen=True)
class Extent:
    logical: int
    physical: int
    blocks: int
    unwritten: bool


@dataclass(frozen=True)
class DirectoryEntry:
    name: str
    inode: int
    file_type: int


@dataclass
class ExtractionStats:
    directories: int = 0
    files: int = 0
    symlinks: int = 0
    skipped_special: int = 0
    logical_bytes: int = 0


class Ext4Image:
    """Minimal read-only ext4 reader for extent-based firmware images."""

    def __init__(self, path: Path | str):
        self.path = Path(path)
        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        self._fd = os.open(self.path, flags)
        try:
            self.image_size = os.fstat(self._fd).st_size
            superblock = self._pread(1024, 1024)
            if _u16(superblock, 0x38) != EXT4_SUPER_MAGIC:
                raise Ext4Error("source is not an ext filesystem")

            self.inodes_count = _u32(superblock, 0x00)
            self.blocks_count = _u32(superblock, 0x04) | (
                _u32(superblock, 0x150) << 32
            )
            self.first_data_block = _u32(superblock, 0x14)
            self.block_size = 1024 << _u32(superblock, 0x18)
            self.blocks_per_group = _u32(superblock, 0x20)
            self.inodes_per_group = _u32(superblock, 0x28)
            self.inode_size = _u16(superblock, 0x58)
            self.feature_compat = _u32(superblock, 0x5C)
            self.feature_incompat = _u32(superblock, 0x60)
            self.feature_ro_compat = _u32(superblock, 0x64)
            self.descriptor_size = max(32, _u16(superblock, 0xFE))
            self.group_count = math.ceil(
                self.blocks_count / self.blocks_per_group
            )
            self.filesystem_bytes = self.blocks_count * self.block_size
            self._gdt_offset = (
                (2 if self.block_size == 1024 else 1) * self.block_size
            )
            self._validate_superblock()
        except BaseException:
            os.close(self._fd)
            raise

    def __enter__(self) -> "Ext4Image":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close(self) -> None:
        if self._fd >= 0:
            os.close(self._fd)
            self._fd = -1

    def _pread(self, size: int, offset: int) -> bytes:
        if size < 0 or offset < 0 or offset + size > self.image_size:
            raise Ext4Error(
                f"read outside image: offset={offset} size={size}"
            )
        data = os.pread(self._fd, size, offset)
        if len(data) != size:
            raise Ext4Error(
                f"short read at {offset}: wanted {size}, got {len(data)}"
            )
        return data

    def _validate_superblock(self) -> None:
        if self.block_size < 1024 or self.block_size > 65536:
            raise Ext4Error(f"unsupported block size {self.block_size}")
        if self.block_size & (self.block_size - 1):
            raise Ext4Error("block size is not a power of two")
        if self.blocks_count == 0 or self.blocks_per_group == 0:
            raise Ext4Error("invalid zero block count/group size")
        if self.inodes_count == 0 or self.inodes_per_group == 0:
            raise Ext4Error("invalid zero inode count/group size")
        if self.inode_size < 128 or self.inode_size > self.block_size:
            raise Ext4Error(f"unsupported inode size {self.inode_size}")
        if self.descriptor_size < 32 or self.descriptor_size > self.block_size:
            raise Ext4Error(
                f"unsupported group descriptor size {self.descriptor_size}"
            )
        unsupported = self.feature_incompat & ~SUPPORTED_INCOMPAT
        if unsupported:
            raise Ext4Error(
                f"unsupported incompatible ext4 features: 0x{unsupported:x}"
            )
        if not (self.feature_incompat & EXT4_FEATURE_INCOMPAT_EXTENTS):
            raise Ext4Error("filesystem does not advertise extents")
        if self.filesystem_bytes > self.image_size:
            raise Ext4Error(
                "filesystem block count extends beyond the source image"
            )
        gdt_bytes = self.group_count * self.descriptor_size
        if self._gdt_offset + gdt_bytes > self.filesystem_bytes:
            raise Ext4Error("group descriptor table lies outside filesystem")

    def info(self) -> dict[str, int | str]:
        return {
            "image": str(self.path),
            "image_bytes": self.image_size,
            "filesystem_bytes": self.filesystem_bytes,
            "verity_or_trailing_bytes": self.image_size - self.filesystem_bytes,
            "block_size": self.block_size,
            "blocks_count": self.blocks_count,
            "blocks_per_group": self.blocks_per_group,
            "group_count": self.group_count,
            "inodes_count": self.inodes_count,
            "inodes_per_group": self.inodes_per_group,
            "inode_size": self.inode_size,
            "descriptor_size": self.descriptor_size,
            "feature_compat": f"0x{self.feature_compat:x}",
            "feature_incompat": f"0x{self.feature_incompat:x}",
            "feature_ro_compat": f"0x{self.feature_ro_compat:x}",
        }

    def _group_descriptor(self, group: int) -> bytes:
        if group < 0 or group >= self.group_count:
            raise Ext4Error(f"group outside filesystem: {group}")
        return self._pread(
            self.descriptor_size,
            self._gdt_offset + group * self.descriptor_size,
        )

    def inode(self, number: int) -> Inode:
        if number < 1 or number > self.inodes_count:
            raise Ext4Error(f"inode outside filesystem: {number}")
        group = (number - 1) // self.inodes_per_group
        index = (number - 1) % self.inodes_per_group
        descriptor = self._group_descriptor(group)
        table_block = _u32(descriptor, 0x08)
        if self.descriptor_size >= 64:
            table_block |= _u32(descriptor, 0x28) << 32
        inode_offset = (
            table_block * self.block_size + index * self.inode_size
        )
        if inode_offset + self.inode_size > self.filesystem_bytes:
            raise Ext4Error(f"inode {number} table entry lies outside filesystem")
        raw = self._pread(self.inode_size, inode_offset)
        mode = _u16(raw, 0x00)
        size = _u32(raw, 0x04)
        if stat.S_ISREG(mode):
            size |= _u32(raw, 0x6C) << 32
        return Inode(
            number=number,
            mode=mode,
            size=size,
            flags=_u32(raw, 0x20),
            block_data=raw[0x28:0x64],
            links=_u16(raw, 0x1A),
        )

    def _block(self, number: int) -> bytes:
        if number < self.first_data_block or number >= self.blocks_count:
            raise Ext4Error(f"block outside filesystem: {number}")
        return self._pread(self.block_size, number * self.block_size)

    def extents(self, inode: Inode) -> tuple[Extent, ...]:
        if inode.size == 0:
            return ()
        if not (inode.flags & EXT4_EXTENTS_FL):
            raise Ext4Error(
                f"inode {inode.number} is not extent based ({inode.kind})"
            )
        visited: set[int] = set()

        def walk(node: bytes, expected_depth: int | None = None) -> list[Extent]:
            if len(node) < 12 or _u16(node, 0x00) != EXT4_EXT_MAGIC:
                raise Ext4Error(f"inode {inode.number} has bad extent magic")
            entries = _u16(node, 0x02)
            maximum = _u16(node, 0x04)
            depth = _u16(node, 0x06)
            if expected_depth is not None and depth != expected_depth:
                raise Ext4Error(f"inode {inode.number} extent depth mismatch")
            if depth > MAX_EXTENT_DEPTH:
                raise Ext4Error(f"inode {inode.number} extent tree is too deep")
            if entries > maximum or 12 + entries * 12 > len(node):
                raise Ext4Error(f"inode {inode.number} has invalid extent header")
            result: list[Extent] = []
            previous_key = -1
            for entry_index in range(entries):
                offset = 12 + entry_index * 12
                logical = _u32(node, offset)
                if logical <= previous_key:
                    raise Ext4Error(
                        f"inode {inode.number} extent keys are not increasing"
                    )
                previous_key = logical
                if depth:
                    child = _u32(node, offset + 4) | (
                        _u16(node, offset + 8) << 32
                    )
                    if child in visited:
                        raise Ext4Error(
                            f"inode {inode.number} has an extent-tree cycle"
                        )
                    visited.add(child)
                    result.extend(walk(self._block(child), depth - 1))
                    continue
                raw_length = _u16(node, offset + 4)
                length = raw_length & 0x7FFF
                physical = _u32(node, offset + 8) | (
                    _u16(node, offset + 6) << 32
                )
                if length == 0:
                    raise Ext4Error(f"inode {inode.number} has a zero extent")
                if physical < self.first_data_block:
                    raise Ext4Error(f"inode {inode.number} extent starts at zero")
                if physical + length > self.blocks_count:
                    raise Ext4Error(
                        f"inode {inode.number} extent lies outside filesystem"
                    )
                result.append(
                    Extent(
                        logical=logical,
                        physical=physical,
                        blocks=length,
                        unwritten=bool(raw_length & 0x8000),
                    )
                )
            return result

        runs = sorted(walk(inode.block_data), key=lambda item: item.logical)
        previous_end = 0
        for run in runs:
            if run.logical < previous_end:
                raise Ext4Error(f"inode {inode.number} has overlapping extents")
            previous_end = run.logical + run.blocks
        return tuple(runs)

    def _iter_regular_chunks(self, inode: Inode) -> Iterator[bytes]:
        logical_offset = 0
        for extent in self.extents(inode):
            extent_offset = extent.logical * self.block_size
            if extent_offset >= inode.size:
                break
            hole = extent_offset - logical_offset
            while hole > 0:
                count = min(hole, len(ZERO_CHUNK))
                yield ZERO_CHUNK[:count]
                logical_offset += count
                hole -= count
            extent_bytes = min(
                extent.blocks * self.block_size, inode.size - logical_offset
            )
            if extent.unwritten:
                remaining = extent_bytes
                while remaining:
                    count = min(remaining, len(ZERO_CHUNK))
                    yield ZERO_CHUNK[:count]
                    remaining -= count
                    logical_offset += count
                continue
            source_offset = extent.physical * self.block_size
            remaining = extent_bytes
            while remaining:
                count = min(remaining, COPY_CHUNK)
                yield self._pread(count, source_offset)
                source_offset += count
                logical_offset += count
                remaining -= count
        trailing = inode.size - logical_offset
        while trailing > 0:
            count = min(trailing, len(ZERO_CHUNK))
            yield ZERO_CHUNK[:count]
            trailing -= count

    def iter_file_chunks(self, inode: Inode) -> Iterator[bytes]:
        if (
            stat.S_ISLNK(inode.mode)
            and inode.size <= len(inode.block_data)
            and not (inode.flags & EXT4_EXTENTS_FL)
        ):
            yield inode.block_data[: inode.size]
            return
        if not (stat.S_ISREG(inode.mode) or stat.S_ISDIR(inode.mode) or stat.S_ISLNK(inode.mode)):
            raise Ext4Error(f"inode {inode.number} is not file-like")
        yield from self._iter_regular_chunks(inode)

    def read_file(self, inode: Inode, limit: int = 128 * 1024 * 1024) -> bytes:
        if inode.size > limit:
            raise Ext4Error(
                f"inode {inode.number} is too large for an in-memory read"
            )
        return b"".join(self.iter_file_chunks(inode))

    def directory_entries(self, inode: Inode) -> tuple[DirectoryEntry, ...]:
        if not stat.S_ISDIR(inode.mode):
            raise Ext4Error(f"inode {inode.number} is not a directory")
        data = self.read_file(inode)
        result: list[DirectoryEntry] = []
        for block_start in range(0, len(data), self.block_size):
            offset = block_start
            block_end = min(block_start + self.block_size, len(data))
            while offset + 8 <= block_end:
                number = _u32(data, offset)
                record_length = _u16(data, offset + 4)
                name_length = data[offset + 6]
                file_type = data[offset + 7]
                if (
                    record_length < 8
                    or record_length % 4
                    or offset + record_length > block_end
                ):
                    # Indexed-directory metadata fills the remainder of its
                    # root block and is not a directory entry stream.
                    break
                if number and name_length <= record_length - 8:
                    raw_name = data[offset + 8 : offset + 8 + name_length]
                    name = raw_name.decode("utf-8", "surrogateescape")
                    result.append(DirectoryEntry(name, number, file_type))
                offset += record_length
        return tuple(result)

    @staticmethod
    def _path_components(path: str) -> list[str]:
        parsed = PurePosixPath(path)
        components = [part for part in parsed.parts if part not in ("/", "")]
        if any(part in (".", "..") for part in components):
            raise Ext4Error("image paths may not contain '.' or '..'")
        return components

    def lookup(self, path: str, *, follow_final_symlink: bool = True) -> Inode:
        pending = self._path_components(path)
        resolved: list[str] = []
        node = self.inode(2)
        symlinks = 0
        while pending:
            if not stat.S_ISDIR(node.mode):
                raise Ext4Error(
                    f"component /{'/'.join(resolved)} is not a directory"
                )
            component = pending.pop(0)
            entries = {
                item.name: item.inode
                for item in self.directory_entries(node)
                if item.name not in (".", "..")
            }
            if component not in entries:
                raise FileNotFoundError(path)
            node = self.inode(entries[component])
            is_final = not pending
            if stat.S_ISLNK(node.mode) and (follow_final_symlink or not is_final):
                symlinks += 1
                if symlinks > MAX_SYMLINKS:
                    raise Ext4Error("too many image symlinks")
                target = self.read_file(node).decode("utf-8", "surrogateescape")
                target_path = PurePosixPath(target)
                target_parts = [
                    part for part in target_path.parts if part not in ("/", "")
                ]
                if any(part == ".." for part in target_parts):
                    for part in target_parts:
                        if part == "..":
                            if not resolved:
                                raise Ext4Error("image symlink escapes root")
                            resolved.pop()
                        elif part != ".":
                            resolved.append(part)
                    pending = resolved + pending
                    resolved = []
                elif target_path.is_absolute():
                    pending = target_parts + pending
                    resolved = []
                else:
                    pending = target_parts + pending
                node = self.inode(2)
                if resolved:
                    pending = resolved + pending
                    resolved = []
                continue
            resolved.append(component)
        return node

    def hash_path(self, path: str, algorithm: str = "sha256") -> tuple[Inode, str]:
        inode = self.lookup(path, follow_final_symlink=False)
        digest = hashlib.new(algorithm)
        for chunk in self.iter_file_chunks(inode):
            digest.update(chunk)
        return inode, digest.hexdigest()

    def list_path(self, path: str) -> list[tuple[str, Inode]]:
        inode = self.lookup(path, follow_final_symlink=False)
        if not stat.S_ISDIR(inode.mode):
            return [(path, inode)]
        result: list[tuple[str, Inode]] = []
        prefix = path.rstrip("/")
        for entry in self.directory_entries(inode):
            if entry.name in (".", ".."):
                continue
            child_path = f"{prefix}/{entry.name}" if prefix else f"/{entry.name}"
            result.append((child_path, self.inode(entry.inode)))
        return result

    def self_test(
        self,
        required_paths: Sequence[str],
        expected_hashes: Sequence[tuple[str, str]],
    ) -> dict[str, object]:
        root = self.inode(2)
        if not stat.S_ISDIR(root.mode):
            raise Ext4Error("root inode is not a directory")
        root_entries = self.directory_entries(root)
        names = [entry.name for entry in root_entries]
        if "." not in names or ".." not in names:
            raise Ext4Error("root directory is missing dot entries")
        if len(names) != len(set(names)):
            raise Ext4Error("root directory contains duplicate names")

        checked: list[dict[str, object]] = []
        for path in required_paths:
            inode = self.lookup(path)
            if inode.size and (
                stat.S_ISREG(inode.mode)
                or stat.S_ISDIR(inode.mode)
                or stat.S_ISLNK(inode.mode)
            ):
                tuple(self.extents(inode)) if not (
                    stat.S_ISLNK(inode.mode)
                    and inode.size <= len(inode.block_data)
                    and not (inode.flags & EXT4_EXTENTS_FL)
                ) else ()
            checked.append(
                {
                    "path": path,
                    "inode": inode.number,
                    "kind": inode.kind,
                    "size": inode.size,
                }
            )
        hashes: list[dict[str, str]] = []
        for path, expected in expected_hashes:
            _, actual = self.hash_path(path)
            if actual.lower() != expected.lower():
                raise Ext4Error(
                    f"SHA-256 mismatch for {path}: expected {expected}, got {actual}"
                )
            hashes.append({"path": path, "sha256": actual})
        return {
            "valid": True,
            "root_entries": len(root_entries) - names.count(".") - names.count(".."),
            "required": checked,
            "hashes": hashes,
            "filesystem": self.info(),
        }

    def extract_tree(self, image_path: str, destination: Path) -> ExtractionStats:
        destination = validate_output_destination(destination)
        source = self.lookup(image_path, follow_final_symlink=False)
        if not stat.S_ISDIR(source.mode):
            raise Ext4Error(
                "extract is tree-only and requires a directory image path"
            )
        self._preflight_tree(
            source,
            image_path,
            reject_host_collisions=not output_supports_ext4_names(
                destination.parent
            ),
        )
        os.mkdir(destination, 0o700)
        stats = ExtractionStats()
        active_directories: set[int] = set()

        def safe_name(name: str) -> bool:
            return bool(name) and name not in (".", "..") and "/" not in name and "\x00" not in name

        def write_regular(inode: Inode, output: Path) -> None:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(output, flags, 0o600)
            try:
                with os.fdopen(fd, "wb", closefd=False) as stream:
                    for chunk in self.iter_file_chunks(inode):
                        stream.write(chunk)
                os.fchmod(fd, stat.S_IMODE(inode.mode) & 0o1777)
            finally:
                os.close(fd)

        def visit(inode: Inode, output: Path) -> None:
            if stat.S_ISDIR(inode.mode):
                if inode.number in active_directories:
                    raise Ext4Error(f"directory cycle at inode {inode.number}")
                active_directories.add(inode.number)
                if output != destination:
                    os.mkdir(output, 0o700)
                stats.directories += 1
                try:
                    for entry in self.directory_entries(inode):
                        if not safe_name(entry.name):
                            continue
                        visit(self.inode(entry.inode), output / entry.name)
                    os.chmod(output, stat.S_IMODE(inode.mode) & 0o1777)
                finally:
                    active_directories.remove(inode.number)
                return
            if stat.S_ISREG(inode.mode):
                write_regular(inode, output)
                stats.files += 1
                stats.logical_bytes += inode.size
                return
            if stat.S_ISLNK(inode.mode):
                target = self.read_file(inode).decode("utf-8", "surrogateescape")
                os.symlink(target, output)
                stats.symlinks += 1
                return
            # Never reproduce device nodes, sockets, or FIFOs on the host.
            stats.skipped_special += 1

        try:
            visit(source, destination)
        except BaseException:
            print(
                f"partial extraction retained for inspection: {destination}",
                file=sys.stderr,
            )
            raise
        return stats

    def _preflight_tree(
        self,
        source: Inode,
        image_path: str,
        *,
        reject_host_collisions: bool,
    ) -> None:
        """Reject cycles and host-name collisions before creating output."""
        active_directories: set[int] = set()

        def collision_key(name: str) -> str:
            # The default macOS/APFS volume is case-insensitive and uses a
            # decomposed Unicode comparison. Conservatively reject those
            # collisions on every host instead of discovering them halfway
            # through an extraction.
            return unicodedata.normalize("NFD", name).casefold()

        def visit(inode: Inode, path: PurePosixPath) -> None:
            if not stat.S_ISDIR(inode.mode):
                return
            if inode.number in active_directories:
                raise Ext4Error(f"directory cycle at image path {path}")
            active_directories.add(inode.number)
            try:
                names: dict[str, str] = {}
                children: list[tuple[DirectoryEntry, Inode]] = []
                for entry in self.directory_entries(inode):
                    if (
                        not entry.name
                        or entry.name in (".", "..")
                        or "/" in entry.name
                        or "\x00" in entry.name
                    ):
                        continue
                    key = collision_key(entry.name)
                    previous = names.get(key)
                    if (
                        reject_host_collisions
                        and previous is not None
                        and previous != entry.name
                    ):
                        raise ExtractionSafetyError(
                            f"case/Unicode collision at {path}: "
                            f"{previous!r} versus {entry.name!r}; use a "
                            "case-sensitive extraction filesystem"
                        )
                    if previous == entry.name:
                        raise Ext4Error(
                            f"duplicate directory entry at {path}: {entry.name!r}"
                        )
                    if previous is None:
                        names[key] = entry.name
                    children.append((entry, self.inode(entry.inode)))
                for entry, child in children:
                    visit(child, path / entry.name)
            finally:
                active_directories.remove(inode.number)

        start = PurePosixPath(image_path)
        visit(source, start)


def validate_output_destination(
    destination: Path | str,
    allowed_parent: Path = DEFAULT_ALLOWED_OUTPUT_PARENT,
) -> Path:
    output = Path(destination)
    if not output.is_absolute():
        raise ExtractionSafetyError("output must be an absolute path")
    allowed = allowed_parent.resolve(strict=True)
    resolved = output.resolve(strict=False)
    if resolved == allowed:
        raise ExtractionSafetyError("output may not be the allowed parent itself")
    try:
        resolved.relative_to(allowed)
    except ValueError as error:
        raise ExtractionSafetyError(
            f"output must be below {allowed}"
        ) from error
    if output.exists() or output.is_symlink():
        raise ExtractionSafetyError("output must not already exist")

    current = output.parent
    while current != allowed:
        if current.is_symlink():
            raise ExtractionSafetyError(f"output parent is a symlink: {current}")
        if not current.exists():
            raise ExtractionSafetyError(
                f"output parent does not exist: {current}"
            )
        if not current.is_dir():
            raise ExtractionSafetyError(
                f"output parent is not a directory: {current}"
            )
        current = current.parent
    return resolved


def output_supports_ext4_names(parent: Path) -> bool:
    """Probe whether the output filesystem preserves case and normalization."""
    probe = Path(tempfile.mkdtemp(prefix=".pluto-ext4-name-probe-", dir=parent))
    created: list[Path] = []

    def create(name: str) -> bool:
        path = probe / name
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(path, flags, 0o600)
        except FileExistsError:
            return False
        os.close(descriptor)
        created.append(path)
        return True

    try:
        if not create("case-name") or not create("CASE-NAME"):
            return False
        if not create("normalize-\u00e9") or not create("normalize-e\u0301"):
            return False
        return True
    finally:
        for path in reversed(created):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        probe.rmdir()


def _parse_expected_hash(value: str) -> tuple[str, str]:
    try:
        path, digest = value.rsplit("=", 1)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected IMAGE_PATH=SHA256") from error
    if not path.startswith("/") or len(digest) != 64:
        raise argparse.ArgumentTypeError("expected absolute IMAGE_PATH and SHA256")
    try:
        int(digest, 16)
    except ValueError as error:
        raise argparse.ArgumentTypeError("SHA256 is not hexadecimal") from error
    return path, digest.lower()


def _format_list(path: str, inode: Inode) -> str:
    return (
        f"{inode.kind:12} {inode.mode:07o} {inode.size:12d} "
        f"inode={inode.number:8d} {path}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="ext4 or ext4.verity image")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("info", help="print validated filesystem geometry")

    list_parser = subparsers.add_parser("list", help="list one image directory")
    list_parser.add_argument("path", nargs="?", default="/")

    hash_parser = subparsers.add_parser("hash", help="hash one file or symlink")
    hash_parser.add_argument("path")
    hash_parser.add_argument("--algorithm", default="sha256")

    test_parser = subparsers.add_parser(
        "self-test", help="validate geometry, root, required paths, and hashes"
    )
    test_parser.add_argument(
        "--require",
        action="append",
        default=[],
        help="required image path (repeatable)",
    )
    test_parser.add_argument(
        "--expect-sha256",
        action="append",
        default=[],
        type=_parse_expected_hash,
        metavar="IMAGE_PATH=SHA256",
    )

    extract_parser = subparsers.add_parser(
        "extract", help="extract a tree into a new /private/tmp directory"
    )
    extract_parser.add_argument("path", nargs="?", default="/")
    extract_parser.add_argument("--output", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        with Ext4Image(args.image) as image:
            if args.command == "info":
                print(json.dumps(image.info(), indent=2, sort_keys=True))
            elif args.command == "list":
                for path, inode in image.list_path(args.path):
                    print(_format_list(path, inode))
            elif args.command == "hash":
                inode, digest = image.hash_path(args.path, args.algorithm)
                print(f"{digest}  {args.path}  ({inode.kind}, {inode.size} bytes)")
            elif args.command == "self-test":
                required = args.require or [
                    "/usr/bin/xochitl",
                    "/usr/lib/ld-linux-aarch64.so.1",
                ]
                report = image.self_test(required, args.expect_sha256)
                print(json.dumps(report, indent=2, sort_keys=True))
            elif args.command == "extract":
                stats = image.extract_tree(args.path, args.output)
                print(json.dumps(vars(stats), indent=2, sort_keys=True))
            else:  # pragma: no cover - argparse enforces the choices.
                raise AssertionError(args.command)
    except (Ext4Error, ExtractionSafetyError, FileNotFoundError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
