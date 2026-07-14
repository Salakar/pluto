#!/usr/bin/env python3
"""Host-only tests for the read-only firmware ext4 extractor."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import stat
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "extract_firmware_rootfs.py"
)
SPEC = importlib.util.spec_from_file_location("extract_firmware_rootfs", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
extractor = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = extractor
SPEC.loader.exec_module(extractor)


BLOCK_SIZE = 1024
IMAGE_BLOCKS = 64
INODE_SIZE = 256
INODES_PER_GROUP = 32
INODE_TABLE_BLOCK = 5


def _pack_into(fmt: str, buffer: bytearray, offset: int, *values: int) -> None:
    struct.pack_into(fmt, buffer, offset, *values)


def _extent_inode(mode: int, size: int, physical_block: int) -> bytes:
    inode = bytearray(INODE_SIZE)
    _pack_into("<H", inode, 0x00, mode)
    _pack_into("<I", inode, 0x04, size & 0xFFFFFFFF)
    _pack_into("<H", inode, 0x1A, 1)
    _pack_into("<I", inode, 0x20, extractor.EXT4_EXTENTS_FL)
    _pack_into("<I", inode, 0x6C, size >> 32)
    _pack_into("<HHHHI", inode, 0x28, extractor.EXT4_EXT_MAGIC, 1, 4, 0, 0)
    _pack_into("<IHHI", inode, 0x34, 0, 1, 0, physical_block)
    return bytes(inode)


def _fast_symlink_inode(target: bytes) -> bytes:
    inode = bytearray(INODE_SIZE)
    _pack_into("<H", inode, 0x00, stat.S_IFLNK | 0o777)
    _pack_into("<I", inode, 0x04, len(target))
    _pack_into("<H", inode, 0x1A, 1)
    inode[0x28 : 0x28 + len(target)] = target
    return bytes(inode)


def _special_inode(mode: int) -> bytes:
    inode = bytearray(INODE_SIZE)
    _pack_into("<H", inode, 0x00, mode)
    _pack_into("<H", inode, 0x1A, 1)
    return bytes(inode)


def _directory_block(entries: list[tuple[int, str, int]]) -> bytes:
    block = bytearray(BLOCK_SIZE)
    offset = 0
    for index, (inode, name, file_type) in enumerate(entries):
        encoded = name.encode("utf-8")
        minimum = (8 + len(encoded) + 3) & ~3
        record_length = BLOCK_SIZE - offset if index == len(entries) - 1 else minimum
        _pack_into("<IHBB", block, offset, inode, record_length, len(encoded), file_type)
        block[offset + 8 : offset + 8 + len(encoded)] = encoded
        offset += record_length
    assert offset == BLOCK_SIZE
    return bytes(block)


def make_fixture(
    path: Path,
    *,
    unsupported_feature: bool = False,
    case_collision: bool = False,
) -> None:
    image = bytearray(IMAGE_BLOCKS * BLOCK_SIZE)
    superblock = 1024
    _pack_into("<I", image, superblock + 0x00, INODES_PER_GROUP)
    _pack_into("<I", image, superblock + 0x04, IMAGE_BLOCKS)
    _pack_into("<I", image, superblock + 0x14, 1)
    _pack_into("<I", image, superblock + 0x18, 0)
    _pack_into("<I", image, superblock + 0x20, IMAGE_BLOCKS)
    _pack_into("<I", image, superblock + 0x28, INODES_PER_GROUP)
    _pack_into("<H", image, superblock + 0x38, extractor.EXT4_SUPER_MAGIC)
    _pack_into("<H", image, superblock + 0x58, INODE_SIZE)
    incompatible = (
        extractor.EXT4_FEATURE_INCOMPAT_FILETYPE
        | extractor.EXT4_FEATURE_INCOMPAT_EXTENTS
        | extractor.EXT4_FEATURE_INCOMPAT_64BIT
    )
    if unsupported_feature:
        incompatible |= 0x0001
    _pack_into("<I", image, superblock + 0x60, incompatible)
    _pack_into("<H", image, superblock + 0xFE, 64)

    descriptor = 2 * BLOCK_SIZE
    _pack_into("<I", image, descriptor + 0x08, INODE_TABLE_BLOCK)

    def install_inode(number: int, raw: bytes) -> None:
        offset = INODE_TABLE_BLOCK * BLOCK_SIZE + (number - 1) * INODE_SIZE
        image[offset : offset + INODE_SIZE] = raw

    root = bytearray(_extent_inode(stat.S_IFDIR | 0o755, BLOCK_SIZE, 20))
    _pack_into("<H", root, 0x1A, 2)
    install_inode(2, bytes(root))
    install_inode(12, _extent_inode(stat.S_IFREG | 0o755, 12, 21))
    install_inode(13, _fast_symlink_inode(b"hello"))
    install_inode(14, _special_inode(stat.S_IFCHR | 0o600))
    install_inode(15, _extent_inode(stat.S_IFLNK | 0o777, 5, 22))

    entries = [
            (2, ".", 2),
            (2, "..", 2),
            (12, "hello", 1),
            (13, "hello-link", 7),
            (14, "devnode", 3),
            (15, "extent-link", 7),
        ]
    if case_collision:
        entries.append((12, "HELLO", 1))
    image[20 * BLOCK_SIZE : 21 * BLOCK_SIZE] = _directory_block(entries)
    image[21 * BLOCK_SIZE : 21 * BLOCK_SIZE + 12] = b"hello world\n"
    image[22 * BLOCK_SIZE : 22 * BLOCK_SIZE + 5] = b"hello"
    path.write_bytes(image)


class FirmwareExtractorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.scratch.name)
        self.image_path = self.root / "fixture.ext4"
        make_fixture(self.image_path)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def test_info_list_hash_and_self_test(self) -> None:
        expected = hashlib.sha256(b"hello world\n").hexdigest()
        with extractor.Ext4Image(self.image_path) as image:
            info = image.info()
            self.assertEqual(info["block_size"], BLOCK_SIZE)
            self.assertEqual(info["group_count"], 1)
            self.assertEqual(info["verity_or_trailing_bytes"], 0)

            listing = {path: inode for path, inode in image.list_path("/")}
            self.assertEqual(listing["/hello"].kind, "file")
            self.assertEqual(listing["/hello-link"].kind, "symlink")
            self.assertEqual(listing["/extent-link"].kind, "symlink")
            self.assertEqual(listing["/devnode"].kind, "char-device")

            inode, actual = image.hash_path("/hello")
            self.assertEqual(inode.size, 12)
            self.assertEqual(actual, expected)
            report = image.self_test(["/hello", "/hello-link"], [("/hello", expected)])
            self.assertTrue(report["valid"])
            self.assertEqual(report["hashes"][0]["sha256"], expected)

    def test_lookup_follows_only_requested_final_symlink(self) -> None:
        with extractor.Ext4Image(self.image_path) as image:
            followed = image.lookup("/hello-link")
            link = image.lookup("/hello-link", follow_final_symlink=False)
            self.assertEqual(followed.kind, "file")
            self.assertEqual(link.kind, "symlink")
            self.assertEqual(image.read_file(link), b"hello")

    def test_extract_is_confined_and_skips_device_nodes(self) -> None:
        output = self.root / "rootfs"
        with extractor.Ext4Image(self.image_path) as image:
            stats = image.extract_tree("/", output)
        self.assertEqual((output / "hello").read_bytes(), b"hello world\n")
        self.assertEqual(os.readlink(output / "hello-link"), "hello")
        self.assertEqual(os.readlink(output / "extent-link"), "hello")
        self.assertFalse((output / "devnode").exists())
        self.assertEqual(stats.files, 1)
        self.assertEqual(stats.symlinks, 2)
        self.assertEqual(stats.skipped_special, 1)

        with self.assertRaises(extractor.ExtractionSafetyError):
            extractor.validate_output_destination(Path("relative"))
        with self.assertRaises(extractor.ExtractionSafetyError):
            extractor.validate_output_destination(Path("/Users/not-private-tmp"))
        with self.assertRaises(extractor.ExtractionSafetyError):
            extractor.validate_output_destination(output)

    def test_unsupported_incompatible_feature_fails_closed(self) -> None:
        bad = self.root / "bad.ext4"
        make_fixture(bad, unsupported_feature=True)
        with self.assertRaises(extractor.Ext4Error):
            extractor.Ext4Image(bad)

    def test_extract_rejects_file_source_and_case_collision_before_output(self) -> None:
        file_output = self.root / "file-output"
        with extractor.Ext4Image(self.image_path) as image:
            with self.assertRaises(extractor.Ext4Error):
                image.extract_tree("/hello", file_output)
        self.assertFalse(file_output.exists())

        colliding = self.root / "colliding.ext4"
        make_fixture(colliding, case_collision=True)
        collision_output = self.root / "collision-output"
        with extractor.Ext4Image(colliding) as image:
            with mock.patch.object(
                extractor, "output_supports_ext4_names", return_value=False
            ):
                with self.assertRaises(extractor.ExtractionSafetyError):
                    image.extract_tree("/", collision_output)
        self.assertFalse(collision_output.exists())

    def test_cli_modes_return_success(self) -> None:
        expected = hashlib.sha256(b"hello world\n").hexdigest()
        commands = [
            [str(self.image_path), "info"],
            [str(self.image_path), "list", "/"],
            [str(self.image_path), "hash", "/hello"],
            [
                str(self.image_path),
                "self-test",
                "--require",
                "/hello",
                "--expect-sha256",
                f"/hello={expected}",
            ],
        ]
        for command in commands:
            with self.subTest(command=command), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(extractor.main(command), 0)


if __name__ == "__main__":
    unittest.main()
