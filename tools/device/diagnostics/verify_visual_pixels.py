#!/usr/bin/env python3
"""Fail-closed cross-modal verification for Pluto visual acceptance frames.

The camera helper produces an upright, perspective-corrected view of the panel,
but intentionally retains a narrow physical guard around it.  This verifier
therefore estimates one bounded axis-aligned crop for the whole 10-frame run,
then compares exposure-invariant edge maps against the native post-dither
screenshots.  A separate signed-difference check proves that the deterministic
Ink S-curve appeared in both modalities at the same panel-relative location.

Only the Python standard library and the repository's existing ffmpeg/ffprobe
runtime dependencies are used.  Input evidence is never modified.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, Sequence


EXPECTED_LABELS = (
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

PROFILE_DIMENSIONS = {
    "rm1": (1404, 1872),
    "rm2": (1404, 1872),
    "move": (954, 1696),
}

VALIDATION_EQUIVALENT = frozenset((3, 6))
INK_BEFORE_INDEX = 7
INK_AFTER_INDEX = 8
INK_EQUIVALENT = frozenset((INK_BEFORE_INDEX, INK_AFTER_INDEX))
WORK_HEIGHT = 192

# Threshold calibration, 2026-07-15: the only truthful cross-modal development
# pairs available before final acceptance were RM1 Home and Ink gallery.  With
# this bounded transform they score 0.349 and 0.271 respectively despite the
# 1152x1374 optical crop, illumination falloff, and JPEG blur.  The 0.20
# alignment, 0.18 per-pair, 0.28 run-mean, and 0.008 one-to-one assignment
# discrimination floors retain margin below that evidence.  The old RM1
# "stroke" pair was a decoded no-op, so it is used only as negative evidence;
# positive stroke thresholds come from the exact panel-relative protocol
# geometry plus the adversarial synthetic suite.


class VerificationError(RuntimeError):
    """An evidence-set invariant or visual proof failed."""


@dataclass(frozen=True)
class GrayFrame:
    width: int
    height: int
    pixels: tuple[int, ...]


@dataclass(frozen=True)
class EdgeFrame:
    width: int
    height: int
    values: tuple[float, ...]
    energy: float
    strong_density: float


@dataclass(frozen=True)
class Alignment:
    scale_x: float
    scale_y: float
    shift_x: float
    shift_y: float
    score: float


@dataclass(frozen=True)
class StrokeMetrics:
    modality: str
    background_delta: float
    peak: float
    localization: float
    signed_fraction: float
    active_fraction: float
    covered_bins: int
    centroid_error: float
    thickness: float
    active: frozenset[int]
    bin_centroids: tuple[float | None, ...]


def _fail(message: str) -> None:
    raise VerificationError(message)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_regular(path: Path, description: str) -> None:
    if path.is_symlink() or not path.is_file():
        _fail(f"{description} is missing or is a symlink: {path.name}")


def _parse_camera_manifest(directory: Path) -> list[Path]:
    manifest = directory / "stages.tsv"
    _require_regular(manifest, "camera stage manifest")
    rows = manifest.read_text(encoding="utf-8").splitlines()
    if len(rows) != len(EXPECTED_LABELS):
        _fail("camera manifest must contain exactly 10 rows")
    images: list[Path] = []
    for index, (row, label) in enumerate(zip(rows, EXPECTED_LABELS), start=1):
        fields = row.split("\t")
        expected_name = f"{index:02d}-{label}.jpg"
        if len(fields) != 4 or fields[0] != f"{index:02d}" or fields[1] != label:
            _fail(f"camera labels are missing, duplicated, or out of order at row {index}")
        if fields[3] != expected_name or len(fields[2]) != 64:
            _fail(f"invalid camera stage row {index}")
        image = directory / expected_name
        _require_regular(image, "camera frame")
        if _sha256(image) != fields[2]:
            _fail(f"camera digest mismatch: {expected_name}")
        images.append(image)
    extras = tuple(directory.glob("*.jpg"))
    if len(extras) != len(EXPECTED_LABELS):
        _fail("camera directory must contain exactly 10 stage JPEGs")
    return images


def _parse_screenshot_manifest(directory: Path) -> list[Path]:
    manifest = directory / "stages.tsv"
    _require_regular(manifest, "screenshot stage manifest")
    rows = manifest.read_text(encoding="utf-8").splitlines()
    if len(rows) != len(EXPECTED_LABELS):
        _fail("screenshot manifest must contain exactly 10 rows")
    images: list[Path] = []
    for index, (row, label) in enumerate(zip(rows, EXPECTED_LABELS), start=1):
        fields = row.split("\t")
        expected_name = f"{label}.png"
        if len(fields) != 4 or fields[0] != label:
            _fail(
                f"screenshot labels are missing, duplicated, or out of order at row {index}"
            )
        if fields[2] != expected_name or len(fields[1]) != 64 or not fields[3]:
            _fail(f"invalid screenshot stage row {index}")
        image = directory / expected_name
        _require_regular(image, "native screenshot")
        if _sha256(image) != fields[1]:
            _fail(f"screenshot digest mismatch: {expected_name}")
        images.append(image)
    extras = tuple(directory.glob("*.png"))
    if len(extras) != len(EXPECTED_LABELS):
        _fail("screenshot directory must contain exactly 10 stage PNGs")
    return images


def _run(command: Sequence[str], *, description: str) -> bytes:
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        _fail(f"{description} failed: {error}")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip().splitlines()
        suffix = f": {detail[-1]}" if detail else ""
        _fail(f"{description} failed{suffix}")
    return result.stdout


def _probe_dimensions(ffprobe: str, path: Path) -> tuple[int, int]:
    raw = _run(
        (
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=s=x:p=0",
            os.fspath(path),
        ),
        description=f"ffprobe {path.name}",
    ).decode("ascii", errors="strict").strip()
    try:
        width_text, height_text = raw.split("x", maxsplit=1)
        width, height = int(width_text), int(height_text)
    except (ValueError, TypeError):
        _fail(f"ffprobe returned invalid dimensions for {path.name}")
    if width <= 0 or height <= 0:
        _fail(f"image dimensions are invalid: {path.name}")
    return width, height


def _decode_gray(ffmpeg: str, path: Path, width: int, height: int) -> GrayFrame:
    raw = _run(
        (
            ffmpeg,
            "-v",
            "error",
            "-nostdin",
            "-i",
            os.fspath(path),
            "-map",
            "0:v:0",
            "-frames:v",
            "1",
            "-vf",
            f"scale={width}:{height}:flags=area,format=gray",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-",
        ),
        description=f"decode {path.name}",
    )
    expected = width * height
    if len(raw) != expected:
        _fail(f"decoded byte count is invalid for {path.name}")
    return GrayFrame(width, height, tuple(raw))


def _percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * fraction)))
    return float(ordered[index])


def _edge_frame(frame: GrayFrame) -> EdgeFrame:
    width, height = frame.width, frame.height
    pixels = frame.pixels
    gradients = [0.0] * (width * height)
    samples: list[float] = []
    for y in range(1, height - 1):
        row = y * width
        for x in range(1, width - 1):
            index = row + x
            horizontal = abs(pixels[index + 1] - pixels[index - 1])
            vertical = abs(pixels[index + width] - pixels[index - width])
            diagonal_a = abs(pixels[index + width + 1] - pixels[index - width - 1])
            diagonal_b = abs(pixels[index + width - 1] - pixels[index - width + 1])
            value = float(horizontal + vertical) + 0.5 * (diagonal_a + diagonal_b)
            gradients[index] = value
            samples.append(value)
    noise = _percentile(samples, 0.70)
    high = _percentile(samples, 0.985)
    if high - noise < 4.0:
        _fail("frame has insufficient edge contrast")
    scale = high - noise
    normalized = tuple(min(1.0, max(0.0, (value - noise) / scale)) for value in gradients)
    interior = max(1, (width - 2) * (height - 2))
    energy = sum(normalized) / interior
    strong_density = sum(value >= 0.35 for value in normalized) / interior
    if energy < 0.006 or strong_density < 0.004:
        _fail("frame has insufficient edge content")
    if energy > 0.38 or strong_density > 0.45:
        _fail("frame edge content is implausibly dense")
    return EdgeFrame(width, height, normalized, energy, strong_density)


def _valid_alignment(scale_x: float, scale_y: float, shift_x: float, shift_y: float) -> bool:
    # The calibrated camera path retains at most a narrow bezel guard.  A crop
    # beyond 20% or a centre displacement beyond 7% is not the configured rig.
    return (
        0.80 <= scale_x <= 1.0
        and 0.80 <= scale_y <= 1.0
        and abs(shift_x) <= 0.07
        and abs(shift_y) <= 0.07
        and (0.5 - scale_x * 0.5 + shift_x) >= -1e-9
        and (0.5 + scale_x * 0.5 + shift_x) <= 1.0 + 1e-9
        and (0.5 - scale_y * 0.5 + shift_y) >= -1e-9
        and (0.5 + scale_y * 0.5 + shift_y) <= 1.0 + 1e-9
    )


def _warp_values(
    values: Sequence[float] | Sequence[int],
    width: int,
    height: int,
    alignment: Alignment,
) -> tuple[float, ...]:
    result = [0.0] * (width * height)
    x_map: list[tuple[int, int, float]] = []
    for x in range(width):
        source = (
            0.5
            + (((x + 0.5) / width) - 0.5) * alignment.scale_x
            + alignment.shift_x
        ) * width - 0.5
        low = min(width - 1, max(0, math.floor(source)))
        high = min(width - 1, low + 1)
        x_map.append((low, high, source - math.floor(source)))
    y_map: list[tuple[int, int, float]] = []
    for y in range(height):
        source = (
            0.5
            + (((y + 0.5) / height) - 0.5) * alignment.scale_y
            + alignment.shift_y
        ) * height - 0.5
        low = min(height - 1, max(0, math.floor(source)))
        high = min(height - 1, low + 1)
        y_map.append((low, high, source - math.floor(source)))
    for y, (y0, y1, fy) in enumerate(y_map):
        row = y * width
        row0 = y0 * width
        row1 = y1 * width
        for x, (x0, x1, fx) in enumerate(x_map):
            top = float(values[row0 + x0]) * (1.0 - fx) + float(values[row0 + x1]) * fx
            bottom = float(values[row1 + x0]) * (1.0 - fx) + float(values[row1 + x1]) * fx
            result[row + x] = top * (1.0 - fy) + bottom * fy
    return tuple(result)


def _soft_dice(first: Sequence[float], second: Sequence[float]) -> float:
    dot = 0.0
    norm_first = 0.0
    norm_second = 0.0
    for left, right in zip(first, second):
        dot += left * right
        norm_first += left * left
        norm_second += right * right
    denominator = norm_first + norm_second
    return 0.0 if denominator <= 1e-12 else (2.0 * dot) / denominator


def _candidate_values(center: float, radius: float, step: float, low: float, high: float) -> list[float]:
    start = max(low, center - radius)
    end = min(high, center + radius)
    count = int(math.floor((end - start) / step + 1e-9))
    values = [round(start + index * step, 6) for index in range(count + 1)]
    if not values or values[-1] < end - 1e-6:
        values.append(round(end, 6))
    return values


def _find_alignment(native: Sequence[EdgeFrame], camera: Sequence[EdgeFrame]) -> Alignment:
    ranked = sorted(
        (
            index
            for index in range(len(EXPECTED_LABELS))
            if index not in (INK_BEFORE_INDEX, INK_AFTER_INDEX)
        ),
        key=lambda index: native[index].energy,
        reverse=True,
    )[:4]

    weights = (1.0, 0.73, 0.47, 0.29)
    pixel_count = native[0].width * native[0].height
    native_aggregate = [0.0] * pixel_count
    camera_aggregate = [0.0] * pixel_count
    for weight, index in zip(weights, ranked):
        for pixel_index in range(pixel_count):
            native_aggregate[pixel_index] += weight * native[index].values[pixel_index]
            camera_aggregate[pixel_index] += weight * camera[index].values[pixel_index]

    # Alignment is geometric, so estimate it on a 2x area reduction.  The
    # accepted transform is scored again against all selected full-resolution
    # stage pairs below; this avoids multiplying the bounded search by four
    # complete frame warps.
    alignment_width = native[0].width // 2
    alignment_height = native[0].height // 2

    def reduce(values: Sequence[float]) -> tuple[float, ...]:
        reduced: list[float] = []
        full_width = native[0].width
        for y in range(alignment_height):
            row0 = (y * 2) * full_width
            row1 = min(native[0].height - 1, y * 2 + 1) * full_width
            for x in range(alignment_width):
                source_x = x * 2
                reduced.append(
                    (
                        values[row0 + source_x]
                        + values[row0 + min(full_width - 1, source_x + 1)]
                        + values[row1 + source_x]
                        + values[row1 + min(full_width - 1, source_x + 1)]
                    )
                    * 0.25
                )
        return tuple(reduced)

    native_reduced = reduce(native_aggregate)
    camera_reduced = reduce(camera_aggregate)

    def search(
        scale_x_values: Iterable[float],
        scale_y_values: Iterable[float],
        shift_x_values: Iterable[float],
        shift_y_values: Iterable[float],
        current: Alignment | None,
    ) -> Alignment:
        best = current
        for scale_x in scale_x_values:
            for scale_y in scale_y_values:
                for shift_x in shift_x_values:
                    for shift_y in shift_y_values:
                        if not _valid_alignment(scale_x, scale_y, shift_x, shift_y):
                            continue
                        candidate = Alignment(scale_x, scale_y, shift_x, shift_y, 0.0)
                        warped = _warp_values(
                            camera_reduced,
                            alignment_width,
                            alignment_height,
                            candidate,
                        )
                        score = _soft_dice(native_reduced, warped)
                        if best is None or score > best.score:
                            best = Alignment(scale_x, scale_y, shift_x, shift_y, score)
        if best is None:
            _fail("no camera alignment is inside the configured bounds")
        return best

    coarse = search(
        (0.80, 0.85, 0.90, 0.95, 1.0),
        (0.80, 0.85, 0.90, 0.95, 1.0),
        (-0.06, -0.03, 0.0, 0.03, 0.06),
        (-0.06, -0.03, 0.0, 0.03, 0.06),
        None,
    )
    refined = coarse
    for _ in range(2):
        refined = search(
            _candidate_values(refined.scale_x, 0.03, 0.01, 0.80, 1.0),
            (refined.scale_y,),
            (refined.shift_x,),
            (refined.shift_y,),
            refined,
        )
        refined = search(
            (refined.scale_x,),
            _candidate_values(refined.scale_y, 0.03, 0.01, 0.80, 1.0),
            (refined.shift_x,),
            (refined.shift_y,),
            refined,
        )
        refined = search(
            (refined.scale_x,),
            (refined.scale_y,),
            _candidate_values(refined.shift_x, 0.02, 0.01, -0.07, 0.07),
            (refined.shift_y,),
            refined,
        )
        refined = search(
            (refined.scale_x,),
            (refined.scale_y,),
            (refined.shift_x,),
            _candidate_values(refined.shift_y, 0.02, 0.01, -0.07, 0.07),
            refined,
        )
    full_score = statistics.fmean(
        _soft_dice(
            native[index].values,
            _warp_values(
                camera[index].values,
                camera[index].width,
                camera[index].height,
                refined,
            ),
        )
        for index in ranked
    )
    final = Alignment(
        refined.scale_x,
        refined.scale_y,
        refined.shift_x,
        refined.shift_y,
        full_score,
    )
    if final.score < 0.20:
        _fail(f"camera/native alignment is too weak ({final.score:.3f})")
    return final


def _allowed_indices(index: int) -> frozenset[int]:
    if index in VALIDATION_EQUIVALENT:
        return VALIDATION_EQUIVALENT
    if index in INK_EQUIVALENT:
        return INK_EQUIVALENT
    return frozenset((index,))


def _assignment_discrimination(
    matrix: Sequence[Sequence[float]],
    allowed_by_row: Sequence[frozenset[int]],
) -> float:
    """Return the per-stage margin over the best label-violating assignment.

    Camera and native frames form a one-to-one evidence set.  Scoring complete
    assignments avoids a false rejection when a visually dense frame happens
    to be one native column's nearest individual neighbour, while moving that
    frame would leave its own distinctive native partner unmatched.  The two
    Validation frames and the two Ink frames are interchangeable only for this
    geometric correspondence check; the signed Ink-difference proof below
    independently establishes before/after order and stroke content.
    """

    count = len(matrix)
    if count < 2 or len(allowed_by_row) != count:
        _fail("camera/native assignment matrix has invalid geometry")
    if any(len(row) != count for row in matrix):
        _fail("camera/native assignment matrix is not square")
    if any(
        not allowed or any(index < 0 or index >= count for index in allowed)
        for allowed in allowed_by_row
    ):
        _fail("camera/native assignment equivalence is invalid")

    states: dict[tuple[int, bool], float] = {(0, False): 0.0}
    for camera_index, row in enumerate(matrix):
        next_states: dict[tuple[int, bool], float] = {}
        for (used, violated), score in states.items():
            for native_index, pair_score in enumerate(row):
                bit = 1 << native_index
                if used & bit:
                    continue
                key = (
                    used | bit,
                    violated or native_index not in allowed_by_row[camera_index],
                )
                candidate = score + pair_score
                previous = next_states.get(key)
                if previous is None or candidate > previous:
                    next_states[key] = candidate
        states = next_states

    full = (1 << count) - 1
    accepted = states.get((full, False))
    rejected = states.get((full, True))
    if accepted is None or rejected is None:
        _fail("camera/native assignment has no complete comparison")
    return (accepted - rejected) / count


def _verify_stage_matching(
    native: Sequence[EdgeFrame], camera_warped: Sequence[tuple[float, ...]]
) -> tuple[list[list[float]], float, float, float]:
    matrix = [
        [_soft_dice(camera_values, native_frame.values) for native_frame in native]
        for camera_values in camera_warped
    ]
    accepted_scores: list[float] = []
    row_discrimination: list[float] = []
    allowed_by_row = tuple(
        _allowed_indices(index) for index in range(len(matrix))
    )
    for camera_index, row in enumerate(matrix):
        allowed = allowed_by_row[camera_index]
        accepted = max(row[index] for index in allowed)
        disallowed = max(row[index] for index in range(len(row)) if index not in allowed)
        accepted_scores.append(accepted)
        row_discrimination.append(accepted - disallowed)
    minimum_score = min(accepted_scores)
    mean_score = statistics.fmean(accepted_scores)
    assignment_gap = _assignment_discrimination(matrix, allowed_by_row)
    minimum_gap = min(min(row_discrimination), assignment_gap)
    if minimum_score < 0.18:
        _fail(f"camera/native stage match is too weak ({minimum_score:.3f})")
    if mean_score < 0.28:
        _fail(f"mean camera/native stage match is too weak ({mean_score:.3f})")
    if minimum_gap < 0.008:
        _fail(f"correct camera/native pairing is not discriminative ({minimum_gap:.3f})")
    return matrix, minimum_score, mean_score, minimum_gap


def _curve_y(t: float) -> float:
    bend = (t - 0.5) * (t - 0.5) * (-1.0 if t < 0.5 else 1.0)
    return 0.56 + (0.46 - 0.56) * t + 0.12 * bend


def _median(values: Sequence[float]) -> float:
    return float(statistics.median(values)) if values else 0.0


def _stroke_metrics(
    before: Sequence[float] | Sequence[int],
    after: Sequence[float] | Sequence[int],
    width: int,
    height: int,
    modality: str,
) -> StrokeMetrics:
    deltas = [float(left) - float(right) for left, right in zip(before, after)]
    corridor_radius = 0.034
    expanded_radius = 0.065
    corridor: list[bool] = [False] * len(deltas)
    expanded: list[bool] = [False] * len(deltas)
    for y in range(height):
        normalized_y = (y + 0.5) / height
        for x in range(width):
            normalized_x = (x + 0.5) / width
            if 0.27 <= normalized_x <= 0.73:
                t = min(1.0, max(0.0, (normalized_x - 0.30) / 0.40))
                distance = abs(normalized_y - _curve_y(t))
                index = y * width + x
                corridor[index] = 0.30 <= normalized_x <= 0.70 and distance <= corridor_radius
                expanded[index] = distance <= expanded_radius
    background = [delta for delta, is_expanded in zip(deltas, expanded) if not is_expanded]
    background_delta = _median(background)
    deviations = [abs(value - background_delta) for value in background]
    mad = _median(deviations)
    noise_tail = _percentile(deviations, 0.995)
    minimum_threshold = 3.5 if modality == "camera" else 2.0
    threshold = max(minimum_threshold, 6.0 * mad, 1.20 * noise_tail)
    adjusted = [delta - background_delta for delta in deltas]
    positive = [max(0.0, value - threshold) for value in adjusted]
    negative = [max(0.0, -value - threshold) for value in adjusted]
    peak = max(adjusted, default=0.0)
    positive_total = sum(positive)
    if positive_total <= 0.0:
        _fail(f"{modality} Ink proof contains no signed dark stroke")
    inside_positive = sum(value for value, inside in zip(positive, corridor) if inside)
    inside_negative = sum(value for value, inside in zip(negative, corridor) if inside)
    localization = inside_positive / positive_total
    signed_denominator = inside_positive + inside_negative
    signed_fraction = inside_positive / signed_denominator if signed_denominator else 0.0
    active = frozenset(
        index for index, (value, inside) in enumerate(zip(positive, corridor)) if inside and value > 0.0
    )
    all_active = sum(value > 0.0 for value in positive)
    active_fraction = all_active / len(positive)
    if abs(background_delta) > (10.0 if modality == "camera" else 2.0):
        _fail(f"{modality} Ink proof is dominated by a global exposure change")
    if peak < (8.0 if modality == "camera" else 18.0):
        _fail(f"{modality} Ink stroke contrast is too weak ({peak:.1f})")
    if localization < (0.50 if modality == "camera" else 0.65):
        _fail(f"{modality} Ink change is not localized to the deterministic corridor")
    if signed_fraction < (0.72 if modality == "camera" else 0.85):
        _fail(f"{modality} Ink change has the wrong signed polarity")
    if not (0.00020 <= active_fraction <= 0.060):
        _fail(f"{modality} Ink change has implausible area ({active_fraction:.4f})")

    bin_centroids: list[float | None] = []
    centroid_errors: list[float] = []
    thicknesses: list[float] = []
    for bin_index in range(8):
        start_x = 0.30 + 0.40 * bin_index / 8.0
        end_x = 0.30 + 0.40 * (bin_index + 1) / 8.0
        weighted_y = 0.0
        weight = 0.0
        samples: list[tuple[float, float]] = []
        for y in range(height):
            normalized_y = (y + 0.5) / height
            row = y * width
            for x in range(width):
                normalized_x = (x + 0.5) / width
                if start_x <= normalized_x < end_x:
                    value = positive[row + x]
                    if value > 0.0 and corridor[row + x]:
                        weighted_y += normalized_y * value
                        weight += value
                        samples.append((normalized_y, value))
        if weight <= 0.0:
            bin_centroids.append(None)
            continue
        centroid = weighted_y / weight
        expected = _curve_y((bin_index + 0.5) / 8.0)
        bin_centroids.append(centroid)
        centroid_errors.append(abs(centroid - expected))
        variance = sum((value - centroid) ** 2 * sample_weight for value, sample_weight in samples) / weight
        thicknesses.append(math.sqrt(max(0.0, variance)))
    covered_bins = sum(value is not None for value in bin_centroids)
    centroid_error = statistics.fmean(centroid_errors) if centroid_errors else 1.0
    thickness = statistics.fmean(thicknesses) if thicknesses else 1.0
    if covered_bins < (6 if modality == "camera" else 7):
        _fail(f"{modality} Ink change does not span the deterministic S-curve")
    if centroid_error > (0.026 if modality == "camera" else 0.020):
        _fail(f"{modality} Ink change follows the wrong corridor ({centroid_error:.3f})")
    if thickness > (0.025 if modality == "camera" else 0.018):
        _fail(f"{modality} Ink change is a blob rather than a thin stroke")
    return StrokeMetrics(
        modality,
        background_delta,
        peak,
        localization,
        signed_fraction,
        active_fraction,
        covered_bins,
        centroid_error,
        thickness,
        active,
        tuple(bin_centroids),
    )


def _dilate(points: frozenset[int], width: int, height: int, radius: int) -> frozenset[int]:
    expanded: set[int] = set()
    for index in points:
        y, x = divmod(index, width)
        for candidate_y in range(max(0, y - radius), min(height, y + radius + 1)):
            for candidate_x in range(max(0, x - radius), min(width, x + radius + 1)):
                expanded.add(candidate_y * width + candidate_x)
    return frozenset(expanded)


def _verify_stroke_overlap(
    native: StrokeMetrics, camera: StrokeMetrics, width: int, height: int
) -> tuple[float, float, float]:
    # The optical image and native screenshot are reduced to a 144x192-ish
    # comparison plane.  Three cells retain a sub-2.1% registration tolerance
    # at that scale; the independent centroid/trajectory gate below still
    # rejects a displaced or differently shaped stroke.
    native_dilated = _dilate(native.active, width, height, 3)
    camera_dilated = _dilate(camera.active, width, height, 3)
    native_overlap = (
        len(native.active.intersection(camera_dilated)) / len(native.active)
        if native.active
        else 0.0
    )
    camera_overlap = (
        len(camera.active.intersection(native_dilated)) / len(camera.active)
        if camera.active
        else 0.0
    )
    shared_centroid_errors = [
        abs(left - right)
        for left, right in zip(native.bin_centroids, camera.bin_centroids)
        if left is not None and right is not None
    ]
    centroid_overlap = (
        statistics.fmean(shared_centroid_errors) if shared_centroid_errors else 1.0
    )
    if min(native_overlap, camera_overlap) < 0.30:
        _fail(
            "native and camera Ink strokes do not spatially overlap "
            f"({native_overlap:.3f}/{camera_overlap:.3f})"
        )
    if len(shared_centroid_errors) < 6 or centroid_overlap > 0.020:
        _fail(f"native and camera Ink trajectories disagree ({centroid_overlap:.3f})")
    return native_overlap, camera_overlap, centroid_overlap


def _validated_executable(path: Path, label: str) -> str:
    if (
        not path.is_absolute()
        or path.is_symlink()
        or not path.is_file()
        or not os.access(path, os.X_OK)
    ):
        _fail(f"{label} must be an absolute executable non-symlink file")
    return os.fspath(path)


def verify(
    camera_dir: Path,
    screenshot_dir: Path,
    profile: str,
    *,
    ffmpeg_path: Path,
    ffprobe_path: Path,
) -> dict[str, object]:
    if profile not in PROFILE_DIMENSIONS:
        _fail(f"unsupported profile: {profile}")
    if camera_dir.is_symlink() or not camera_dir.is_dir():
        _fail("camera directory is missing or is a symlink")
    if screenshot_dir.is_symlink() or not screenshot_dir.is_dir():
        _fail("screenshot directory is missing or is a symlink")
    ffmpeg = _validated_executable(ffmpeg_path, "ffmpeg")
    ffprobe = _validated_executable(ffprobe_path, "ffprobe")
    camera_paths = _parse_camera_manifest(camera_dir)
    screenshot_paths = _parse_screenshot_manifest(screenshot_dir)
    native_dimensions = PROFILE_DIMENSIONS[profile]
    camera_dimensions: tuple[int, int] | None = None
    for path in screenshot_paths:
        if _probe_dimensions(ffprobe, path) != native_dimensions:
            _fail(f"native screenshot geometry does not match {profile}: {path.name}")
    for path in camera_paths:
        dimensions = _probe_dimensions(ffprobe, path)
        if dimensions[0] < 480 or dimensions[1] < 480:
            _fail(f"camera frame is implausibly small: {path.name}")
        if camera_dimensions is None:
            camera_dimensions = dimensions
        elif camera_dimensions != dimensions:
            _fail("camera geometry changed within one acceptance set")

    work_width = round(WORK_HEIGHT * native_dimensions[0] / native_dimensions[1])
    native_gray = [
        _decode_gray(ffmpeg, path, work_width, WORK_HEIGHT) for path in screenshot_paths
    ]
    camera_gray = [
        _decode_gray(ffmpeg, path, work_width, WORK_HEIGHT) for path in camera_paths
    ]
    native_edges: list[EdgeFrame] = []
    camera_edges: list[EdgeFrame] = []
    for index, frame in enumerate(native_gray):
        try:
            native_edges.append(_edge_frame(frame))
        except VerificationError as error:
            _fail(f"native {EXPECTED_LABELS[index]}: {error}")
    for index, frame in enumerate(camera_gray):
        try:
            camera_edges.append(_edge_frame(frame))
        except VerificationError as error:
            _fail(f"camera {EXPECTED_LABELS[index]}: {error}")

    alignment = _find_alignment(native_edges, camera_edges)
    warped_camera_edges = [
        _warp_values(frame.values, frame.width, frame.height, alignment)
        for frame in camera_edges
    ]
    for index, values in enumerate(warped_camera_edges):
        energy = sum(values) / len(values)
        density = sum(value >= 0.35 for value in values) / len(values)
        if energy < 0.005 or density < 0.003:
            _fail(f"aligned camera frame lacks edge content at {EXPECTED_LABELS[index]}")
    _, minimum_score, mean_score, minimum_gap = _verify_stage_matching(
        native_edges, warped_camera_edges
    )

    warped_camera_gray = [
        _warp_values(frame.pixels, frame.width, frame.height, alignment)
        for frame in camera_gray
    ]
    native_stroke = _stroke_metrics(
        native_gray[INK_BEFORE_INDEX].pixels,
        native_gray[INK_AFTER_INDEX].pixels,
        work_width,
        WORK_HEIGHT,
        "native",
    )
    camera_stroke = _stroke_metrics(
        warped_camera_gray[INK_BEFORE_INDEX],
        warped_camera_gray[INK_AFTER_INDEX],
        work_width,
        WORK_HEIGHT,
        "camera",
    )
    native_overlap, camera_overlap, trajectory_delta = _verify_stroke_overlap(
        native_stroke, camera_stroke, work_width, WORK_HEIGHT
    )
    return {
        "status": "PASS",
        "profile": profile,
        "stages": len(EXPECTED_LABELS),
        "alignment": {
            "scale_x": round(alignment.scale_x, 4),
            "scale_y": round(alignment.scale_y, 4),
            "shift_x": round(alignment.shift_x, 4),
            "shift_y": round(alignment.shift_y, 4),
            "score": round(alignment.score, 4),
        },
        "matching": {
            "minimum_score": round(minimum_score, 4),
            "mean_score": round(mean_score, 4),
            "minimum_discrimination": round(minimum_gap, 4),
        },
        "ink": {
            "native_localization": round(native_stroke.localization, 4),
            "camera_localization": round(camera_stroke.localization, 4),
            "native_peak": round(native_stroke.peak, 2),
            "camera_peak": round(camera_stroke.peak, 2),
            "native_overlap": round(native_overlap, 4),
            "camera_overlap": round(camera_overlap, 4),
            "trajectory_delta": round(trajectory_delta, 4),
        },
    }


def _arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--camera-dir", type=Path, required=True)
    parser.add_argument("--screenshot-dir", type=Path, required=True)
    parser.add_argument("--profile", choices=tuple(PROFILE_DIMENSIONS), required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    parser.add_argument("--json", action="store_true", help="emit the complete result as JSON")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(sys.argv[1:] if argv is None else argv)
    try:
        result = verify(
            arguments.camera_dir,
            arguments.screenshot_dir,
            arguments.profile,
            ffmpeg_path=arguments.ffmpeg,
            ffprobe_path=arguments.ffprobe,
        )
    except VerificationError as error:
        print(f"visual pixel verifier: FAIL: {error}", file=sys.stderr)
        return 1
    if arguments.json:
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        alignment = result["alignment"]
        matching = result["matching"]
        ink = result["ink"]
        assert isinstance(alignment, dict)
        assert isinstance(matching, dict)
        assert isinstance(ink, dict)
        print(
            "visual pixel verifier: PASS "
            f"stages={len(EXPECTED_LABELS)} profile={result['profile']} "
            f"alignment={alignment['score']:.4f} "
            f"pair_min={matching['minimum_score']:.4f} "
            f"pair_gap={matching['minimum_discrimination']:.4f} "
            f"ink_overlap={min(ink['native_overlap'], ink['camera_overlap']):.4f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
