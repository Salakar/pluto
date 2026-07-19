#!/usr/bin/env python3
"""Focused synthetic tests for verify_visual_pixels.py."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[4]
VERIFIER = ROOT / "tools/device/diagnostics/verify_visual_pixels.py"
VERIFIER_SPEC = importlib.util.spec_from_file_location(
    "pluto_verify_visual_pixels", VERIFIER
)
if VERIFIER_SPEC is None or VERIFIER_SPEC.loader is None:
    raise RuntimeError("cannot load visual pixel verifier")
VERIFIER_MODULE = importlib.util.module_from_spec(VERIFIER_SPEC)
sys.modules[VERIFIER_SPEC.name] = VERIFIER_MODULE
VERIFIER_SPEC.loader.exec_module(VERIFIER_MODULE)
LABELS = (
    "app-dev.pluto.examples.counter",
    "app-dev.pluto.examples.motion_lab",
    "app-dev.pluto.examples.ink_lab",
    "app-dev.pluto.validation_lab",
    "app-dev.pluto.ink-before-switcher",
    "switcher-dev.pluto.ink",
    "switcher-selected-dev.pluto.validation_lab",
    "ink-canvas-before-stroke",
    "ink-stroke",
    "app-dev.pluto.launcher",
)
NATIVE_SIZE = (954, 1696)
CAMERA_SIZE = (720, 1280)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decoded_gray(path: Path) -> bytes:
    result = subprocess.run(
        (
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-i",
            os.fspath(path),
            "-frames:v",
            "1",
            "-vf",
            "format=gray",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-",
        ),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


class Canvas:
    def __init__(
        self,
        width: int,
        height: int,
        *,
        camera: bool,
        roi: tuple[float, float, float, float] = (0.08, 0.04, 0.92, 0.96),
        exposure: int = 0,
    ) -> None:
        self.width = width
        self.height = height
        self.camera = camera
        self.roi = roi if camera else (0.0, 0.0, 1.0, 1.0)
        background = (220 if camera else 250) + exposure
        self.background = max(0, min(255, background))
        self.data = bytearray([self.background]) * (width * height)
        self.ink = max(0, min(255, (35 if camera else 10) + exposure))

    def point(self, x: float, y: float) -> tuple[int, int]:
        left, top, right, bottom = self.roi
        mapped_x = left + (right - left) * x
        mapped_y = top + (bottom - top) * y
        return (
            min(self.width - 1, max(0, round(mapped_x * (self.width - 1)))),
            min(self.height - 1, max(0, round(mapped_y * (self.height - 1)))),
        )

    def dot(self, x: int, y: int, radius: int, value: int | None = None) -> None:
        color = self.ink if value is None else value
        for candidate_y in range(max(0, y - radius), min(self.height, y + radius + 1)):
            row = candidate_y * self.width
            for candidate_x in range(max(0, x - radius), min(self.width, x + radius + 1)):
                if (candidate_x - x) ** 2 + (candidate_y - y) ** 2 <= radius**2 + 1:
                    self.data[row + candidate_x] = color

    def line(
        self,
        start_x: float,
        start_y: float,
        end_x: float,
        end_y: float,
        thickness: float = 0.0035,
    ) -> None:
        x0, y0 = self.point(start_x, start_y)
        x1, y1 = self.point(end_x, end_y)
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        radius = max(1, round(thickness * min(self.width, self.height)))
        for step in range(steps + 1):
            fraction = step / steps
            self.dot(
                round(x0 + (x1 - x0) * fraction),
                round(y0 + (y1 - y0) * fraction),
                radius,
            )

    def rectangle(
        self, left: float, top: float, right: float, bottom: float, thickness: float = 0.003
    ) -> None:
        self.line(left, top, right, top, thickness)
        self.line(right, top, right, bottom, thickness)
        self.line(right, bottom, left, bottom, thickness)
        self.line(left, bottom, left, top, thickness)

    def fill_rectangle(self, left: float, top: float, right: float, bottom: float) -> None:
        x0, y0 = self.point(left, top)
        x1, y1 = self.point(right, bottom)
        for y in range(min(y0, y1), max(y0, y1) + 1):
            row = y * self.width
            for x in range(min(x0, x1), max(x0, x1) + 1):
                self.data[row + x] = self.ink


def curve_y(t: float) -> float:
    bend = (t - 0.5) ** 2 * (-1.0 if t < 0.5 else 1.0)
    return 0.56 - 0.10 * t + 0.12 * bend


def draw_curve(canvas: Canvas, *, offset_y: float = 0.0) -> None:
    previous = (0.30, 0.56 + offset_y)
    for index in range(1, 81):
        t = index / 80.0
        current = (0.30 + 0.40 * t, curve_y(t) + offset_y)
        canvas.line(*previous, *current, thickness=0.0045)
        previous = current


def draw_scene(
    width: int,
    height: int,
    stage: int,
    *,
    camera: bool,
    roi: tuple[float, float, float, float] = (0.08, 0.04, 0.92, 0.96),
    stroke: bool | None = None,
    curve_offset: float = 0.0,
    exposure: int = 0,
    blob: bool = False,
    blank: bool = False,
) -> bytes:
    canvas = Canvas(width, height, camera=camera, roi=roi, exposure=exposure)
    if blank:
        return bytes(canvas.data)
    canvas.line(0.02, 0.075, 0.98, 0.075, 0.0025)
    canvas.rectangle(0.025, 0.018, 0.18, 0.058, 0.0025)
    if stage in (7, 8):
        signature = 80
    elif stage in (3, 6):
        signature = 44
    else:
        signature = stage + 1
    generator = random.Random(signature * 7919)
    for _ in range(16):
        start_x = generator.uniform(0.05, 0.80)
        start_y = generator.uniform(0.11, 0.82)
        end_x = min(0.96, max(0.04, start_x + generator.uniform(-0.13, 0.20)))
        end_y = min(0.90, max(0.10, start_y + generator.uniform(-0.08, 0.12)))
        canvas.line(start_x, start_y, end_x, end_y, 0.0028)
    for _ in range(7):
        left = generator.uniform(0.05, 0.76)
        top = generator.uniform(0.12, 0.76)
        canvas.rectangle(left, top, min(0.96, left + 0.10), min(0.90, top + 0.07))
    if stage in (3, 6):
        marker_x = 0.84 if stage == 3 else 0.90
        canvas.rectangle(marker_x, 0.82, marker_x + 0.035, 0.86, 0.002)
    if stage in (7, 8):
        canvas.rectangle(0.08, 0.15, 0.92, 0.86, 0.0035)
        canvas.line(0.08, 0.25, 0.92, 0.25, 0.0025)
    should_stroke = stage == 8 if stroke is None else stroke
    if should_stroke:
        draw_curve(canvas, offset_y=curve_offset)
    if blob:
        canvas.fill_rectangle(0.24, 0.38, 0.76, 0.66)
    return bytes(canvas.data)


def write_pgm(path: Path, width: int, height: int, pixels: bytes) -> None:
    path.write_bytes(f"P5\n{width} {height}\n255\n".encode("ascii") + pixels)


def encode_image(pgm: Path, output: Path, *, camera: bool, variant: bool = False) -> None:
    command = [
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-i",
        os.fspath(pgm),
    ]
    if camera:
        command.extend(("-vf", "gblur=sigma=0.55", "-q:v", "7" if variant else "3"))
    else:
        command.extend(("-compression_level", "9" if variant else "6"))
    command.extend(("-frames:v", "1", os.fspath(output)))
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def replace_stage(
    root: Path,
    modality: str,
    stage: int,
    *,
    source_stage: int | None = None,
    stroke: bool | None = None,
    curve_offset: float = 0.0,
    exposure: int = 0,
    blob: bool = False,
    blank: bool = False,
    roi: tuple[float, float, float, float] = (0.08, 0.04, 0.92, 0.96),
    reencode_variant: bool = False,
) -> None:
    camera = modality == "camera"
    directory = root / modality
    label = LABELS[stage]
    filename = f"{stage + 1:02d}-{label}.jpg" if camera else f"{label}.png"
    output = directory / filename
    width, height = CAMERA_SIZE if camera else NATIVE_SIZE
    pixels = draw_scene(
        width,
        height,
        stage if source_stage is None else source_stage,
        camera=camera,
        roi=roi,
        stroke=stroke,
        curve_offset=curve_offset,
        exposure=exposure,
        blob=blob,
        blank=blank,
    )
    pgm = root / f"replacement-{modality}-{stage}.pgm"
    replacement = root / f"replacement-{modality}-{filename}"
    write_pgm(pgm, width, height, pixels)
    encode_image(pgm, replacement, camera=camera, variant=reencode_variant)
    os.replace(replacement, output)
    pgm.unlink()
    update_digest(directory, modality, stage)


def update_digest(directory: Path, modality: str, stage: int) -> None:
    manifest = directory / "stages.tsv"
    rows = manifest.read_text(encoding="utf-8").splitlines()
    fields = rows[stage].split("\t")
    image = directory / fields[3 if modality == "camera" else 2]
    fields[2 if modality == "camera" else 1] = sha256(image)
    rows[stage] = "\t".join(fields)
    manifest.write_text("\n".join(rows) + "\n", encoding="utf-8")


def swap_camera_stages(root: Path, first: int, second: int) -> None:
    directory = root / "camera"
    first_path = directory / f"{first + 1:02d}-{LABELS[first]}.jpg"
    second_path = directory / f"{second + 1:02d}-{LABELS[second]}.jpg"
    first_bytes = first_path.read_bytes()
    second_bytes = second_path.read_bytes()
    first_replacement = root / "swap-first.jpg"
    second_replacement = root / "swap-second.jpg"
    first_replacement.write_bytes(second_bytes)
    second_replacement.write_bytes(first_bytes)
    os.replace(first_replacement, first_path)
    os.replace(second_replacement, second_path)
    update_digest(directory, "camera", first)
    update_digest(directory, "camera", second)


def build_fixture(root: Path) -> None:
    camera_dir = root / "camera"
    native_dir = root / "native"
    camera_dir.mkdir(parents=True)
    native_dir.mkdir(parents=True)
    camera_rows: list[str] = []
    native_rows: list[str] = []
    for index, label in enumerate(LABELS):
        for camera, directory, dimensions in (
            (True, camera_dir, CAMERA_SIZE),
            (False, native_dir, NATIVE_SIZE),
        ):
            width, height = dimensions
            pgm = root / f"source-{camera}-{index}.pgm"
            filename = f"{index + 1:02d}-{label}.jpg" if camera else f"{label}.png"
            output = directory / filename
            write_pgm(pgm, width, height, draw_scene(width, height, index, camera=camera))
            encode_image(pgm, output, camera=camera)
            pgm.unlink()
            digest = sha256(output)
            if camera:
                camera_rows.append(f"{index + 1:02d}\t{label}\t{digest}\t{filename}")
            else:
                native_rows.append(f"{label}\t{digest}\t{filename}\tdev.synthetic.{index}")
    (camera_dir / "stages.tsv").write_text("\n".join(camera_rows) + "\n", encoding="utf-8")
    (native_dir / "stages.tsv").write_text("\n".join(native_rows) + "\n", encoding="utf-8")


class VisualPixelsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        ffmpeg = shutil.which("ffmpeg")
        ffprobe = shutil.which("ffprobe")
        if ffmpeg is None or ffprobe is None:
            raise unittest.SkipTest("ffmpeg and ffprobe are required")
        cls.ffmpeg = Path(ffmpeg).resolve()
        cls.ffprobe = Path(ffprobe).resolve()
        cls.fixture_owner = tempfile.TemporaryDirectory(prefix="pluto-visual-pixels-base-")
        cls.fixture = Path(cls.fixture_owner.name)
        build_fixture(cls.fixture)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fixture_owner.cleanup()

    def setUp(self) -> None:
        self.owner = tempfile.TemporaryDirectory(prefix="pluto-visual-pixels-test-")
        self.root = Path(self.owner.name) / "evidence"
        shutil.copytree(self.fixture, self.root, copy_function=os.link)
        # Tests replace stage images atomically.  Break the two manifest hard
        # links as well so digest rewrites cannot mutate the shared fixture.
        for manifest in (self.root / "camera/stages.tsv", self.root / "native/stages.tsv"):
            contents = manifest.read_bytes()
            manifest.unlink()
            manifest.write_bytes(contents)

    def tearDown(self) -> None:
        self.owner.cleanup()

    def run_verifier(self, *, json_output: bool = False) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            os.fspath(VERIFIER),
            "--camera-dir",
            os.fspath(self.root / "camera"),
            "--screenshot-dir",
            os.fspath(self.root / "native"),
            "--profile",
            "move",
            "--ffmpeg",
            os.fspath(self.ffmpeg),
            "--ffprobe",
            os.fspath(self.ffprobe),
        ]
        if json_output:
            command.append("--json")
        return subprocess.run(command, check=False, text=True, capture_output=True, timeout=90)

    def assert_fails(self, expected: str) -> None:
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(expected, result.stderr)

    def test_accepts_aligned_cross_modal_set_and_emits_json(self) -> None:
        result = self.run_verifier(json_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "PASS")
        self.assertEqual(payload["stages"], 10)
        self.assertGreater(payload["matching"]["minimum_discrimination"], 0.008)
        self.assertGreater(payload["ink"]["native_overlap"], 0.30)
        self.assertGreater(payload["ink"]["camera_overlap"], 0.30)

    def test_assignment_uses_the_complete_bijection_not_reverse_nearest_pairs(
        self,
    ) -> None:
        matrix = (
            (0.9, 0.1, 0.1),
            (0.1, 0.6, 0.3),
            (0.1, 0.7, 0.9),
        )
        allowed = tuple(frozenset((index,)) for index in range(3))
        self.assertGreater(matrix[2][1], matrix[1][1])
        self.assertGreater(
            VERIFIER_MODULE._assignment_discrimination(matrix, allowed),
            0.008,
        )

    def test_stroke_overlap_allows_only_the_calibrated_registration_guard(
        self,
    ) -> None:
        width = 20
        height = 12
        centroids = (0.5,) * 8

        def metrics(row: int):
            return VERIFIER_MODULE.StrokeMetrics(
                modality="fixture",
                background_delta=0.0,
                peak=32.0,
                localization=1.0,
                signed_fraction=1.0,
                active_fraction=0.01,
                covered_bins=8,
                centroid_error=0.0,
                thickness=0.0,
                active=frozenset(row * width + column for column in range(5, 15)),
                bin_centroids=centroids,
            )

        native = metrics(4)
        allowed_camera = metrics(7)
        native_overlap, camera_overlap, _ = VERIFIER_MODULE._verify_stroke_overlap(
            native, allowed_camera, width, height
        )
        self.assertEqual(native_overlap, 1.0)
        self.assertEqual(camera_overlap, 1.0)

        with self.assertRaisesRegex(
            VERIFIER_MODULE.VerificationError,
            "do not spatially overlap",
        ):
            VERIFIER_MODULE._verify_stroke_overlap(
                native, metrics(8), width, height
            )

    def test_only_motion_lab_is_declared_as_the_dynamic_stage(self) -> None:
        self.assertEqual(VERIFIER_MODULE.MOTION_LAB_INDEX, 1)
        self.assertEqual(LABELS[VERIFIER_MODULE.MOTION_LAB_INDEX], LABELS[1])

    def test_allows_validation_equivalent_frames(self) -> None:
        swap_camera_stages(self.root, 3, 6)
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS stages=10", result.stdout)

    def test_rejects_reordered_labels(self) -> None:
        manifest = self.root / "camera/stages.tsv"
        rows = manifest.read_text(encoding="utf-8").splitlines()
        rows[1], rows[2] = rows[2], rows[1]
        manifest.write_text("\n".join(rows) + "\n", encoding="utf-8")
        self.assert_fails("labels are missing, duplicated, or out of order")

    def test_rejects_profile_geometry_mismatch(self) -> None:
        command = [
            sys.executable,
            os.fspath(VERIFIER),
            "--camera-dir",
            os.fspath(self.root / "camera"),
            "--screenshot-dir",
            os.fspath(self.root / "native"),
            "--profile",
            "rm1",
            "--ffmpeg",
            os.fspath(self.ffmpeg),
            "--ffprobe",
            os.fspath(self.ffprobe),
        ]
        result = subprocess.run(command, check=False, text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native screenshot geometry does not match rm1", result.stderr)

    def test_rejects_permuted_pairs(self) -> None:
        swap_camera_stages(self.root, 0, 3)
        self.assert_fails("pairing is not discriminative")

    def test_rejects_unrelated_pairs(self) -> None:
        for stage in range(len(LABELS)):
            replace_stage(self.root, "camera", stage, source_stage=(stage + 3) % len(LABELS))
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(
            result.stderr,
            r"alignment is too weak|stage match is too weak|pairing is not discriminative",
        )

    def test_rejects_low_edge_content(self) -> None:
        replace_stage(self.root, "camera", 2, blank=True)
        self.assert_fails("insufficient edge")

    def test_rejects_reencoded_decoded_noop(self) -> None:
        before_native = self.root / "native" / f"{LABELS[7]}.png"
        replace_stage(
            self.root,
            "native",
            8,
            source_stage=7,
            stroke=False,
            reencode_variant=True,
        )
        replace_stage(
            self.root,
            "camera",
            8,
            source_stage=7,
            stroke=False,
            reencode_variant=True,
        )
        after_native = self.root / "native" / f"{LABELS[8]}.png"
        self.assertNotEqual(sha256(before_native), sha256(after_native))
        self.assertEqual(decoded_gray(before_native), decoded_gray(after_native))
        self.assert_fails("contains no signed dark stroke")

    def test_rejects_one_modality_only(self) -> None:
        replace_stage(
            self.root,
            "camera",
            8,
            source_stage=7,
            stroke=False,
            reencode_variant=True,
        )
        self.assert_fails("camera Ink proof contains no signed dark stroke")

    def test_rejects_global_exposure_change(self) -> None:
        replace_stage(self.root, "native", 8, exposure=-24)
        replace_stage(self.root, "camera", 8, exposure=-24)
        self.assert_fails("global exposure change")

    def test_rejects_global_blob(self) -> None:
        replace_stage(self.root, "native", 8, blob=True)
        replace_stage(self.root, "camera", 8, blob=True)
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(
            result.stderr,
            r"no signed dark stroke|not localized|implausible area|blob rather than",
        )

    def test_rejects_wrong_corridor(self) -> None:
        replace_stage(self.root, "native", 8, curve_offset=0.13)
        replace_stage(self.root, "camera", 8, curve_offset=0.13)
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"not localized|wrong corridor|does not span")

    def test_rejects_alignment_outside_calibrated_guard(self) -> None:
        for stage in range(len(LABELS)):
            replace_stage(
                self.root,
                "camera",
                stage,
                roi=(0.21, 0.20, 0.79, 0.80),
            )
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"alignment is too weak|stage match is too weak")


if __name__ == "__main__":
    unittest.main()
