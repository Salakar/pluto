#!/usr/bin/env python3

import argparse
from copy import deepcopy
import contextlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "camera.py"
SPEC = importlib.util.spec_from_file_location("pluto_camera", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
camera = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(camera)


class CameraToolTest(unittest.TestCase):
    def vision_device(self, number=2):
        if number == 2:
            return {
                "number": 2,
                "screen": {
                    "left": 100,
                    "top": 100,
                    "right": 400,
                    "bottom": 900,
                },
                "screen_corners": {
                    "top_left": {"x": 120, "y": 105},
                    "top_right": {"x": 395, "y": 125},
                    "bottom_left": {"x": 100, "y": 875},
                    "bottom_right": {"x": 375, "y": 895},
                },
                "label": {
                    "left": 50,
                    "top": 100,
                    "right": 90,
                    "bottom": 180,
                },
                "confidence": 0.98,
            }
        if number == 7:
            return {
                "number": 7,
                "screen": {
                    "left": 550,
                    "top": 120,
                    "right": 900,
                    "bottom": 880,
                },
                "screen_corners": {
                    "top_left": {"x": 570, "y": 130},
                    "top_right": {"x": 880, "y": 115},
                    "bottom_left": {"x": 585, "y": 865},
                    "bottom_right": {"x": 895, "y": 850},
                },
                "label": {
                    "left": 910,
                    "top": 120,
                    "right": 960,
                    "bottom": 200,
                },
                "confidence": 0.96,
            }
        raise AssertionError(f"no test fixture for device {number}")

    def shifted_vision_device(self, device, *, dx=0, dy=0):
        shifted = deepcopy(device)
        shifted["screen"]["left"] += dx
        shifted["screen"]["right"] += dx
        shifted["screen"]["top"] += dy
        shifted["screen"]["bottom"] += dy
        for point in shifted["screen_corners"].values():
            point["x"] += dx
            point["y"] += dy
        return shifted

    def screen_refinement(self, number=2):
        if number == 2:
            return {
                "number": 2,
                "active_display_corners": {
                    "top_left": {"x": 34, "y": 26},
                    "top_right": {"x": 966, "y": 41},
                    "bottom_left": {"x": 27, "y": 960},
                    "bottom_right": {"x": 959, "y": 975},
                },
                "confidence": 0.97,
            }
        if number == 7:
            return {
                "number": 7,
                "active_display_corners": {
                    "top_left": {"x": 43, "y": 31},
                    "top_right": {"x": 955, "y": 18},
                    "bottom_left": {"x": 55, "y": 970},
                    "bottom_right": {"x": 967, "y": 957},
                },
                "confidence": 0.95,
            }
        raise AssertionError(f"no refinement fixture for device {number}")

    def shifted_refinement(self, refinement, *, dx=0, dy=0):
        shifted = deepcopy(refinement)
        for point in shifted["active_display_corners"].values():
            point["x"] += dx
            point["y"] += dy
        return shifted

    def with_boundary_fit(
        self, device, *, accepted_edge_count=4, geometry_accepted=True
    ):
        source_corners = deepcopy(
            device["screen"]["refinement"]["source_corners"]["pixels"]
        )
        return camera.replace_refinement_geometry(
            device,
            source_corners,
            boundary_fit={
                "method": "local_rgb_physical_edges",
                "geometry_accepted": geometry_accepted,
                "accepted_edge_count": accepted_edge_count,
                "area_ratio": 1.0,
                "edges": {
                    name: {
                        "accepted": True,
                        "score": 24.0,
                        "score_ratio": 1.5,
                        "coherence": 1.0,
                        "consistent_bins": 8,
                        "first_displacement_pixels": 0.0,
                        "second_displacement_pixels": 0.0,
                    }
                    for name in camera.BOUNDARY_EDGE_DEFINITIONS
                },
                "analysis_pixels": deepcopy(
                    device["screen"]["intermediate_output"]
                ),
                "source_corners_pixels": deepcopy(source_corners),
            },
        )

    def synthetic_boundary_frame(self, *, width, height, active, outer):
        def inside_quad(x, y, corners):
            ordered = [
                corners["top_left"],
                corners["top_right"],
                corners["bottom_right"],
                corners["bottom_left"],
            ]
            return all(
                (second["x"] - first["x"]) * (y - first["y"])
                - (second["y"] - first["y"]) * (x - first["x"])
                >= 0
                for first, second in zip(ordered, ordered[1:] + ordered[:1])
            )

        pixels = bytearray(width * height * 3)
        for y in range(height):
            for x in range(width):
                # The outer chassis/background transition is stronger than the
                # display/bezel transition, but lies outside the local search.
                color = (255, 255, 255)
                if inside_quad(x, y, outer):
                    color = (24, 29, 34)
                if inside_quad(x, y, active):
                    color = (207, 225, 231)
                # A high-contrast but discontinuous UI line is deliberately
                # stronger than the physical edge over part of the display.
                if (
                    inside_quad(x, y, active)
                    and 0.30 * width < x < 0.70 * width
                    and abs(y - (0.34 * height + 0.03 * x)) < 1.5
                ):
                    color = (3, 3, 3)
                offset = (y * width + x) * 3
                pixels[offset : offset + 3] = bytes(color)
        return bytes(pixels)

    def configured_devices(self, *numbers):
        detected = camera.validate_vision_devices(
            [self.vision_device(number) for number in numbers]
        )
        calibration = camera.attach_pixel_boxes(
            detected,
            width=1280,
            height=720,
            margin_ratio=camera.CALIBRATION_SCREEN_MARGIN_RATIO,
        )
        completed = camera.attach_screen_refinements(
            calibration,
            [self.screen_refinement(number) for number in numbers],
        )
        completed = [self.with_boundary_fit(device) for device in completed]
        return detected, calibration, completed

    def valid_config(self):
        _, _, devices = self.configured_devices(2, 7)
        return {
            "schema_version": 6,
            "configured_at": "2026-07-13T20:00:00Z",
            "device_count": 2,
            "camera": {
                "backend": "avfoundation",
                "id": "3",
                "name": "USB camera",
                "input": "3:none",
                "width": 1280,
                "height": 720,
                "framerate": 30,
                "pixel_format": "uyvy422",
                "settle_seconds": 0.35,
            },
            "detector": {
                "tool": "codex",
                "model": "gpt-5.6-luna",
                "reasoning_effort": "low",
                "crop_verified": True,
            },
            "devices": devices,
        }

    def write_config(self, directory: Path):
        path = directory / ".pluto-devices.json"
        path.write_text(json.dumps(self.valid_config()), encoding="utf-8")
        return path

    def run_synthetic_configure(
        self,
        root,
        detection_device,
        initial_refinement,
        verification_results,
        *,
        boundary_edge_counts=None,
    ):
        config_path = root / ".pluto-devices.json"
        stages = []
        rendered = []
        detection_devices = (
            detection_device
            if isinstance(detection_device, list)
            else [detection_device]
        )
        initial_refinements = (
            initial_refinement
            if isinstance(initial_refinement, list)
            else [initial_refinement]
        )
        verification_results = [deepcopy(result) for result in verification_results]
        boundary_edge_counts = list(boundary_edge_counts or [])

        class FakeVision:
            def __init__(self, **kwargs):
                self.model = "test-vision"

            def analyze(self, *, stage, **kwargs):
                stages.append(stage)
                if stage == "camera-selection":
                    return {
                        "camera_image_index": 0,
                        "labeled_device_count": len(detection_devices),
                        "confidence": 1.0,
                        "reason": "synthetic fixture",
                    }
                if stage == "screen-detection":
                    return {
                        "devices": deepcopy(detection_devices),
                        "confidence": 1.0,
                        "notes": "synthetic fixture",
                    }
                if stage == "screen-refinement":
                    return {
                        "devices": deepcopy(initial_refinements),
                        "notes": "synthetic active-display refinement",
                    }
                return verification_results.pop(0)

        source = {
            "backend": "avfoundation",
            "id": "3",
            "name": "USB camera",
            "input": "3:none",
        }

        def fake_sample(camera_source, *, output, **kwargs):
            output.write_bytes(b"synthetic-camera-frame")
            return (
                {
                    **camera_source,
                    "width": 1280,
                    "height": 720,
                    "framerate": 30,
                    "pixel_format": "uyvy422",
                },
                None,
            )

        def fake_render(source_path, output, device, *, timeout):
            rendered.append(deepcopy(device))
            output.write_bytes(b"synthetic-transformed-crop")

        def fake_identify_preview(source_path, output, config, *, timeout):
            output.write_bytes(b"synthetic-capture-footprint")

        def fake_boundary_fit(calibration_path, configured_device, *, timeout):
            accepted_edge_count = (
                boundary_edge_counts.pop(0) if boundary_edge_counts else 4
            )
            return self.with_boundary_fit(
                configured_device,
                accepted_edge_count=accepted_edge_count,
            )

        args = argparse.Namespace(
            config=str(config_path),
            size=(1280, 720),
            framerate=30,
            settle=0.0,
            camera=None,
            include_virtual=False,
            model="test-vision",
            camera_timeout=2.0,
            codex_timeout=2.0,
            artifacts=str(root / "artifacts"),
            keep_artifacts=False,
        )
        with mock.patch.object(camera, "require_commands"), mock.patch.object(
            camera, "enumerate_cameras", return_value=[source]
        ), mock.patch.object(
            camera, "sample_camera", side_effect=fake_sample
        ), mock.patch.object(
            camera, "CodexVision", FakeVision
        ), mock.patch.object(
            camera, "render_crop", side_effect=fake_render
        ), mock.patch.object(
            camera,
            "render_identify_preview",
            side_effect=fake_identify_preview,
        ), mock.patch.object(
            camera,
            "refine_configured_screen_boundaries",
            side_effect=fake_boundary_fit,
        ), mock.patch.object(
            camera, "measure_preview_rotation", return_value=None
        ), mock.patch.object(
            camera,
            "camera_lock",
            side_effect=lambda config_path: contextlib.nullcontext(),
        ), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            camera.configure(args)
        return json.loads(config_path.read_text(encoding="utf-8")), stages, rendered

    def test_parse_avfoundation_video_section_and_filter_nonphysical_sources(self):
        output = """
[AVFoundation indev @ 0x1] AVFoundation video devices:
[AVFoundation indev @ 0x1] [0] Elgato Facecam
[AVFoundation indev @ 0x1] [1] FaceTime HD Camera
[AVFoundation indev @ 0x1] [2] OBS Virtual Camera
[AVFoundation indev @ 0x1] [3] Capture screen 0
[AVFoundation indev @ 0x1] [4] Phone Camera
[AVFoundation indev @ 0x1] [5] Phone Camera
[AVFoundation indev @ 0x1] AVFoundation audio devices:
[AVFoundation indev @ 0x1] [0] MacBook Microphone
"""
        devices = camera.parse_avfoundation_devices(output)
        self.assertEqual([item["id"] for item in devices], ["0", "1", "4", "5"])
        self.assertEqual(devices[0]["input"], "0:none")
        self.assertEqual(devices[2]["name"], devices[3]["name"])

        with_virtual = camera.parse_avfoundation_devices(output, include_virtual=True)
        self.assertEqual([item["id"] for item in with_virtual], ["0", "1", "2", "4", "5"])

    def test_unique_avfoundation_names_become_stable_name_inputs(self):
        devices = [
            {
                "backend": "avfoundation",
                "id": "0",
                "name": "Elgato Facecam",
                "input": "0:none",
            },
            {
                "backend": "avfoundation",
                "id": "4",
                "name": "Phone Camera",
                "input": "4:none",
            },
            {
                "backend": "avfoundation",
                "id": "5",
                "name": "Phone Camera",
                "input": "5:none",
            },
        ]
        stable = camera.prefer_unique_avfoundation_names(devices)
        self.assertEqual(stable[0]["input"], "Elgato Facecam:none")
        self.assertTrue(stable[0]["stable_name_input"])
        self.assertEqual(stable[1]["input"], "4:none")
        self.assertFalse(stable[1]["stable_name_input"])

    def test_parse_v4l2_devices(self):
        output = """USB camera (usb-1):
    /dev/video0
    /dev/video1

OBS Virtual Camera (platform:v4l2loopback):
    /dev/video3

Built in:
    /dev/video4
"""
        def stable(value):
            return "/dev/v4l/by-id/usb-camera" if value == "/dev/video0" else value

        with mock.patch.object(camera, "stable_v4l2_path", side_effect=stable):
            devices = camera.parse_v4l2_devices(output)
        self.assertEqual(
            [item["id"] for item in devices],
            ["/dev/v4l/by-id/usb-camera", "/dev/video1", "/dev/video4"],
        )
        self.assertEqual(devices[0]["aliases"], ["/dev/video0"])
        self.assertEqual(devices[0]["name"], "USB camera (usb-1)")
        self.assertEqual(devices[2]["name"], "Built in")

        with mock.patch.object(camera, "stable_v4l2_path", side_effect=stable):
            with_virtual = camera.parse_v4l2_devices(output, include_virtual=True)
        self.assertIn("/dev/video3", [item["id"] for item in with_virtual])

    def test_camera_selector_accepts_original_v4l_path_alias(self):
        cameras = [
            {
                "id": "/dev/v4l/by-id/usb-camera",
                "input": "/dev/v4l/by-id/usb-camera",
                "name": "USB camera",
                "aliases": ["/dev/video0"],
            }
        ]
        self.assertEqual(
            camera.filter_camera_selector(cameras, "/dev/video0")[0]["id"],
            "/dev/v4l/by-id/usb-camera",
        )

    def test_linux_fallback_preserves_original_video_path_alias(self):
        with mock.patch.object(camera.sys, "platform", "linux"), mock.patch.object(
            camera.shutil, "which", return_value=None
        ), mock.patch.object(
            camera.glob, "glob", return_value=["/dev/video0"]
        ), mock.patch.object(
            camera, "stable_v4l2_path", return_value="/dev/v4l/by-id/usb-camera"
        ):
            devices = camera.enumerate_cameras(include_virtual=False, timeout=1)
        self.assertEqual(devices[0]["id"], "/dev/v4l/by-id/usb-camera")
        self.assertEqual(devices[0]["aliases"], ["/dev/video0"])

    def test_camera_selector_rejects_duplicate_names(self):
        cameras = [
            {"id": "4", "input": "4:none", "name": "Phone Camera"},
            {"id": "5", "input": "5:none", "name": "Phone Camera"},
        ]
        with self.assertRaisesRegex(camera.CameraError, "ambiguous"):
            camera.filter_camera_selector(cameras, "Phone Camera")
        self.assertEqual(camera.filter_camera_selector(cameras, "5")[0]["id"], "5")

    def test_configured_avfoundation_camera_is_remapped_by_unique_name(self):
        configured = {
            "backend": "avfoundation",
            "id": "0",
            "name": "Elgato Facecam",
            "input": "0:none",
        }
        current = [
            {
                "backend": "avfoundation",
                "id": "0",
                "name": "FaceTime HD Camera",
                "input": "0:none",
            },
            {
                "backend": "avfoundation",
                "id": "1",
                "name": "Elgato Facecam",
                "input": "Elgato Facecam:none",
            },
        ]
        with mock.patch.object(camera, "enumerate_cameras", return_value=current):
            resolved = camera.resolve_configured_camera(configured, timeout=2)
        self.assertEqual(resolved["id"], "1")
        self.assertEqual(resolved["input"], "Elgato Facecam:none")
        self.assertEqual(configured["input"], "0:none")

    def test_configured_duplicate_camera_name_fails_if_last_index_no_longer_matches(self):
        configured = {
            "backend": "avfoundation",
            "id": "4",
            "name": "Phone Camera",
            "input": "4:none",
        }
        current = [
            {
                "backend": "avfoundation",
                "id": "5",
                "name": "Phone Camera",
                "input": "5:none",
            },
            {
                "backend": "avfoundation",
                "id": "6",
                "name": "Phone Camera",
                "input": "6:none",
            },
        ]
        with mock.patch.object(camera, "enumerate_cameras", return_value=current):
            with self.assertRaisesRegex(camera.CameraError, "ambiguous"):
                camera.resolve_configured_camera(configured, timeout=2)

    def test_timed_out_camera_sample_is_skipped_instead_of_aborting_scan(self):
        source = {
            "backend": "avfoundation",
            "id": "4",
            "name": "Phone Camera",
            "input": "4:none",
        }
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            camera,
            "run_process",
            side_effect=camera.CameraError("ffmpeg timed out after 2 seconds"),
        ) as run:
            sampled, diagnostic = camera.sample_camera(
                source,
                output=Path(temporary) / "sample.jpg",
                requested_size=(1280, 720),
                framerate=30,
                settle_seconds=0.35,
                timeout=2,
            )
        self.assertIsNone(sampled)
        self.assertIn("timed out", diagnostic)
        run.assert_called_once()

    def test_codex_command_is_ephemeral_read_only_low_reasoning_and_structured(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            images = [root / "one.jpg", root / "two.jpg"]
            command = camera.codex_command(
                work_dir=root,
                images=images,
                schema_path=root / "schema.json",
                result_path=root / "result.json",
                model="gpt-5.6-luna",
            )
        self.assertIn("--ephemeral", command)
        self.assertIn("--ignore-user-config", command)
        self.assertIn("--ignore-rules", command)
        disabled = [
            command[index + 1]
            for index, item in enumerate(command)
            if item == "--disable"
        ]
        self.assertIn("shell_tool", disabled)
        self.assertIn("unified_exec", disabled)
        self.assertIn("browser_use", disabled)
        self.assertIn("computer_use", disabled)
        self.assertIn("multi_agent", disabled)
        self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
        self.assertEqual(command[command.index("--ask-for-approval") + 1], "never")
        self.assertLess(command.index("--ask-for-approval"), command.index("exec"))
        self.assertEqual(command[command.index("--model") + 1], "gpt-5.6-luna")
        self.assertIn('model_reasoning_effort="low"', command)
        self.assertEqual(command.count("--image"), 2)
        self.assertIn("--output-schema", command)
        self.assertIn("--output-last-message", command)
        self.assertEqual(command[-1], "-")

    def test_codex_model_falls_back_and_is_reused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / "frame.jpg"
            image.write_bytes(b"jpeg")
            calls = []

            def fake_run(command, **kwargs):
                calls.append(command)
                model = command[command.index("--model") + 1] if "--model" in command else None
                if model == "gpt-5.6-luna":
                    return subprocess.CompletedProcess(
                        command, 1, "", "model is not available for this account"
                    )
                result_path = Path(command[command.index("--output-last-message") + 1])
                result_path.write_text('{"ok": true}', encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            vision = camera.CodexVision(
                work_dir=root,
                requested_model="gpt-5.6-luna",
                allow_model_fallback=True,
                timeout=10,
            )
            with mock.patch.object(camera, "run_process", side_effect=fake_run):
                result = vision.analyze(
                    stage="first",
                    prompt="prompt",
                    images=[image],
                    schema={"type": "object"},
                )
                second = vision.analyze(
                    stage="second",
                    prompt="prompt",
                    images=[image],
                    schema={"type": "object"},
                )
        self.assertEqual(result, {"ok": True})
        self.assertEqual(second, {"ok": True})
        self.assertEqual(vision.model, "gpt-5.4-mini")
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[-1][calls[-1].index("--model") + 1], "gpt-5.4-mini")

    def test_model_unavailable_recognizes_codex_account_wording(self):
        self.assertTrue(
            camera.model_unavailable(
                "The 'gpt-5.6-luna' model is not supported when using Codex with this account."
            )
        )

    def test_isolated_codex_environment_copies_auth_then_removes_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_home = Path(temporary) / "source"
            source_home.mkdir()
            (source_home / "auth.json").write_text("secret", encoding="utf-8")
            with mock.patch.dict(os.environ, {"CODEX_HOME": str(source_home)}):
                with camera.isolated_codex_environment() as environment:
                    isolated_home = Path(environment["CODEX_HOME"])
                    self.assertNotEqual(isolated_home, source_home)
                    self.assertEqual(
                        (isolated_home / "auth.json").read_text(encoding="utf-8"),
                        "secret",
                    )
                self.assertFalse(isolated_home.exists())

    def test_validate_devices_rejects_duplicates_and_overlaps(self):
        valid = self.vision_device(2)
        duplicate = self.shifted_vision_device(valid, dx=450)
        with self.assertRaisesRegex(camera.CameraError, "duplicate"):
            camera.validate_vision_devices([valid, duplicate])

        overlapping = deepcopy(valid)
        overlapping["number"] = 3
        with self.assertRaisesRegex(camera.CameraError, "overlap"):
            camera.validate_vision_devices([valid, overlapping])

    def test_vision_schema_requires_ordered_screen_corners(self):
        self.assertIn("screen_corners", camera.vision_device_schema()["required"])

        missing = self.vision_device(2)
        missing.pop("screen_corners")
        with self.assertRaisesRegex(camera.CameraError, "corners"):
            camera.validate_vision_devices([missing])

        misordered = self.vision_device(2)
        misordered["screen_corners"]["top_right"], misordered["screen_corners"][
            "bottom_left"
        ] = (
            misordered["screen_corners"]["bottom_left"],
            misordered["screen_corners"]["top_right"],
        )
        with self.assertRaisesRegex(camera.CameraError, "misordered"):
            camera.validate_vision_devices([misordered])

    def test_screen_refinements_are_per_device_and_validate_the_number_set(self):
        _, calibration, _ = self.configured_devices(2, 7)
        reversed_refinements = [
            self.screen_refinement(7),
            self.screen_refinement(2),
        ]
        completed = camera.attach_screen_refinements(
            calibration, reversed_refinements
        )
        self.assertEqual([device["number"] for device in completed], [2, 7])
        self.assertEqual(
            completed[0]["screen"]["refinement"]["source_corners"]["normalized"],
            self.screen_refinement(2)["active_display_corners"],
        )
        self.assertEqual(
            completed[1]["screen"]["refinement"]["source_corners"]["normalized"],
            self.screen_refinement(7)["active_display_corners"],
        )

        with self.assertRaisesRegex(camera.CameraError, "set of device numbers"):
            camera.attach_screen_refinements(
                calibration, [self.screen_refinement(2)]
            )

        duplicate = self.screen_refinement(2)
        with self.assertRaisesRegex(camera.CameraError, "duplicate"):
            camera.attach_screen_refinements(calibration, [duplicate, duplicate])

        misordered = self.screen_refinement(2)
        corners = misordered["active_display_corners"]
        corners["top_right"], corners["bottom_left"] = (
            corners["bottom_left"],
            corners["top_right"],
        )
        with self.assertRaisesRegex(camera.CameraError, "misordered"):
            camera.attach_screen_refinements(
                [calibration[0]], [misordered]
            )

    def test_refinement_pixel_coordinates_are_normalized_per_device(self):
        detected = camera.validate_vision_devices([self.vision_device(2)])
        calibration = camera.attach_pixel_boxes(
            detected,
            width=1280,
            height=720,
            margin_ratio=camera.CALIBRATION_SCREEN_MARGIN_RATIO,
        )
        output = calibration[0]["screen"]["output"]
        pixel_response = {
            "number": 2,
            "active_display_corners": {
                "top_left": {"x": 10, "y": 12},
                "top_right": {"x": output["width"] - 10, "y": 14},
                "bottom_left": {"x": 12, "y": output["height"] - 14},
                "bottom_right": {
                    "x": output["width"] - 8,
                    "y": output["height"] - 12,
                },
            },
            "confidence": 0.8,
        }
        completed = camera.attach_screen_refinements(
            calibration, [pixel_response]
        )[0]
        normalized = completed["screen"]["refinement"]["source_corners"][
            "normalized"
        ]
        self.assertGreater(normalized["top_right"]["x"], 800)
        self.assertGreater(normalized["bottom_left"]["y"], 800)

    def test_active_display_coverage_outside_bounds_requires_retry(self):
        narrow = {
            "top_left": {"x": 400, "y": 400},
            "top_right": {"x": 600, "y": 400},
            "bottom_left": {"x": 400, "y": 600},
            "bottom_right": {"x": 600, "y": 600},
        }
        with self.assertRaisesRegex(camera.CameraError, "coverage is outside"):
            camera.stabilize_active_display_coverage(narrow, number=4)

    def test_physical_boundary_fit_prefers_continuous_nested_display_edges(self):
        width, height = 160, 240
        active = {
            "top_left": {"x": 42.0, "y": 32.0},
            "top_right": {"x": 122.0, "y": 38.0},
            "bottom_left": {"x": 34.0, "y": 204.0},
            "bottom_right": {"x": 130.0, "y": 210.0},
        }
        outer = {
            "top_left": {"x": 20.0, "y": 10.0},
            "top_right": {"x": 140.0, "y": 18.0},
            "bottom_left": {"x": 10.0, "y": 226.0},
            "bottom_right": {"x": 150.0, "y": 234.0},
        }
        prior = {
            "top_left": {"x": 44.0, "y": 36.0},
            "top_right": {"x": 120.0, "y": 39.0},
            "bottom_left": {"x": 37.0, "y": 199.0},
            "bottom_right": {"x": 127.0, "y": 205.0},
        }

        fitted, metadata = camera.fit_active_display_boundaries(
            self.synthetic_boundary_frame(
                width=width,
                height=height,
                active=active,
                outer=outer,
            ),
            width=width,
            height=height,
            prior_corners=prior,
        )

        self.assertTrue(metadata["geometry_accepted"])
        self.assertEqual(metadata["accepted_edge_count"], 4)
        for name in camera.SCREEN_CORNER_NAMES:
            self.assertLess(camera.point_distance(fitted[name], active[name]), 1.0)
            self.assertLess(
                camera.point_distance(fitted[name], active[name]),
                camera.point_distance(prior[name], active[name]),
            )

    def test_physical_boundary_fit_falls_back_to_prior_for_flat_crop(self):
        width, height = 120, 180
        prior = {
            "top_left": {"x": 20.0, "y": 20.0},
            "top_right": {"x": 100.0, "y": 20.0},
            "bottom_left": {"x": 20.0, "y": 160.0},
            "bottom_right": {"x": 100.0, "y": 160.0},
        }

        fitted, metadata = camera.fit_active_display_boundaries(
            bytes([128]) * (width * height * 3),
            width=width,
            height=height,
            prior_corners=prior,
        )

        self.assertEqual(fitted, prior)
        self.assertEqual(metadata["method"], "local_rgb_physical_edges")
        self.assertEqual(metadata["accepted_edge_count"], 0)
        self.assertTrue(
            all(not edge["accepted"] for edge in metadata["edges"].values())
        )

    def test_physical_boundary_fit_keeps_exact_strong_prior_locked(self):
        width, height = 160, 240
        active = {
            "top_left": {"x": 42.0, "y": 32.0},
            "top_right": {"x": 122.0, "y": 38.0},
            "bottom_left": {"x": 34.0, "y": 204.0},
            "bottom_right": {"x": 130.0, "y": 210.0},
        }
        outer = {
            "top_left": {"x": 20.0, "y": 10.0},
            "top_right": {"x": 140.0, "y": 18.0},
            "bottom_left": {"x": 10.0, "y": 226.0},
            "bottom_right": {"x": 150.0, "y": 234.0},
        }

        fitted, metadata = camera.fit_active_display_boundaries(
            self.synthetic_boundary_frame(
                width=width,
                height=height,
                active=active,
                outer=outer,
            ),
            width=width,
            height=height,
            prior_corners=deepcopy(active),
        )

        self.assertTrue(metadata["geometry_accepted"])
        self.assertEqual(metadata["accepted_edge_count"], 4)
        for name in camera.SCREEN_CORNER_NAMES:
            self.assertLess(camera.point_distance(fitted[name], active[name]), 1.0)

    def test_physical_boundary_fit_rejects_deep_inward_ui_edge(self):
        def score_for(target):
            def score(*_args, **kwargs):
                first = kwargs["first_displacement"]
                second = kwargs["second_displacement"]
                if first == target and second == target:
                    value = 50.0
                elif first == 0 and second == 0:
                    value = 20.0
                else:
                    value = 1.0
                return {
                    "score": value,
                    "coherence": 1.0,
                    "consistent_bins": 8,
                    "median_vector": (20.0, 20.0, 20.0),
                }

            return score

        arguments = {
            "pixels": bytes(100 * 200 * 3),
            "width": 100,
            "height": 200,
            "edge_name": "top",
            "first": {"x": 10.0, "y": 20.0},
            "second": {"x": 90.0, "y": 20.0},
            "normal_sign": -1.0,
        }
        with mock.patch.object(
            camera, "boundary_candidate_score", side_effect=score_for(3)
        ):
            inward = camera.fit_physical_boundary_edge(**arguments)
        with mock.patch.object(
            camera, "boundary_candidate_score", side_effect=score_for(-3)
        ):
            outward = camera.fit_physical_boundary_edge(**arguments)

        self.assertFalse(inward["accepted"])
        self.assertEqual(inward["first"], arguments["first"])
        self.assertEqual(inward["second"], arguments["second"])
        self.assertTrue(outward["accepted"])
        self.assertLess(outward["first"]["y"], arguments["first"]["y"])
        self.assertLess(outward["second"]["y"], arguments["second"]["y"])

    def test_physical_boundary_fit_handles_mixed_device_sizes_independently(self):
        relative_active = {
            "top_left": (0.27, 0.13),
            "top_right": (0.76, 0.16),
            "bottom_left": (0.22, 0.84),
            "bottom_right": (0.81, 0.87),
        }
        relative_outer = {
            "top_left": (0.12, 0.03),
            "top_right": (0.90, 0.07),
            "bottom_left": (0.05, 0.96),
            "bottom_right": (0.96, 0.99),
        }
        relative_prior = {
            "top_left": (0.29, 0.15),
            "top_right": (0.75, 0.165),
            "bottom_left": (0.24, 0.82),
            "bottom_right": (0.79, 0.85),
        }

        def scaled(corners, width, height):
            return {
                name: {"x": x * width, "y": y * height}
                for name, (x, y) in corners.items()
            }

        results = []
        for width, height in ((120, 200), (220, 320)):
            with self.subTest(width=width, height=height):
                active = scaled(relative_active, width, height)
                outer = scaled(relative_outer, width, height)
                prior = scaled(relative_prior, width, height)
                fitted, metadata = camera.fit_active_display_boundaries(
                    self.synthetic_boundary_frame(
                        width=width,
                        height=height,
                        active=active,
                        outer=outer,
                    ),
                    width=width,
                    height=height,
                    prior_corners=prior,
                )
                self.assertEqual(metadata["accepted_edge_count"], 4)
                self.assertTrue(metadata["geometry_accepted"])
                for name in camera.SCREEN_CORNER_NAMES:
                    self.assertLess(
                        camera.point_distance(fitted[name], active[name]), 1.25
                    )
                results.append(fitted)

        first_width = camera.point_distance(
            results[0]["top_left"], results[0]["top_right"]
        )
        second_width = camera.point_distance(
            results[1]["top_left"], results[1]["top_right"]
        )
        self.assertGreater(second_width, first_width * 1.7)

    def test_geometry_change_requires_corrected_crops_to_be_rendered_again(self):
        raw = self.vision_device(2)
        original = camera.validate_vision_devices([raw])
        confidence_only = camera.validate_vision_devices([{**raw, "confidence": 0.8}])
        corrected_raw = self.shifted_vision_device(raw, dx=20)
        corrected = camera.validate_vision_devices([corrected_raw])
        self.assertEqual(
            camera.device_geometry(original), camera.device_geometry(confidence_only)
        )
        self.assertNotEqual(
            camera.device_geometry(original), camera.device_geometry(corrected)
        )

    def test_base_fine_and_total_fractional_rotations_are_derived(self):
        _, calibration, completed = self.configured_devices(2)
        configured = completed[0]
        camera_corners = configured["screen"]["corners"]["pixels"]
        fine_corners = configured["screen"]["refinement"]["transform_corners"][
            "pixels"
        ]

        self.assertEqual(calibration[0]["rotation_degrees_clockwise"], -2.278)
        self.assertEqual(
            configured["base_rotation_degrees_clockwise"],
            camera.rotation_correction_degrees(camera_corners),
        )
        self.assertEqual(
            configured["fine_rotation_degrees_clockwise"],
            camera.rotation_correction_degrees(fine_corners),
        )
        self.assertEqual(
            configured["rotation_degrees_clockwise"],
            camera.normalize_rotation_degrees(
                configured["base_rotation_degrees_clockwise"]
                + configured["fine_rotation_degrees_clockwise"]
            ),
        )
        self.assertNotEqual(configured["fine_rotation_degrees_clockwise"], 0)

    def test_residual_content_rotation_is_diagnostic_only_and_deterministic(self):
        width, height = 160, 240
        pixels = bytearray([240]) * (width * height)
        slope = math.tan(math.radians(1.5))
        for base_y in (45, 85, 130, 175):
            for x in range(width):
                y = round(base_y + slope * (x - (width - 1) / 2))
                for offset in range(3):
                    pixels[(y + offset) * width + x] = 20

        evidence = camera.horizontal_line_rotation_evidence(
            bytes(pixels), width=width, height=height
        )
        self.assertEqual(
            evidence,
            camera.horizontal_line_rotation_evidence(
                bytes(pixels), width=width, height=height
            ),
        )
        self.assertIsNotNone(evidence)
        assert evidence is not None
        self.assertLess(evidence["correction_degrees_clockwise"], -1.0)
        self.assertGreaterEqual(evidence["line_count"], 2)

        _, calibration, _ = self.configured_devices(2)
        roomy_refinement = self.screen_refinement(2)
        roomy_refinement["active_display_corners"] = {
            "top_left": {"x": 150, "y": 100},
            "top_right": {"x": 850, "y": 115},
            "bottom_left": {"x": 140, "y": 885},
            "bottom_right": {"x": 840, "y": 900},
        }
        original = camera.attach_screen_refinements(
            calibration, [roomy_refinement]
        )[0]
        original = self.with_boundary_fit(original)
        with mock.patch.object(
            camera, "measure_preview_rotation", return_value=evidence
        ):
            diagnosed = camera.auto_level_rendered_crop(
                Path("source.jpg"),
                Path("crop.jpg"),
                original,
                timeout=1.0,
            )
            repeated = camera.auto_level_rendered_crop(
                Path("source.jpg"),
                Path("crop.jpg"),
                original,
                timeout=1.0,
            )
        self.assertEqual(diagnosed, repeated)
        self.assertEqual(
            original["screen"]["refinement"]["auto_level"],
            {
                "correction_degrees_clockwise": 0.0,
                "line_count": 0,
                "score_ratio": 1.0,
            },
        )
        self.assertEqual(
            diagnosed["screen"]["refinement"]["transform_corners"]["pixels"],
            original["screen"]["refinement"]["transform_corners"]["pixels"],
        )
        self.assertEqual(
            diagnosed["screen"]["refinement"]["auto_level"],
            {
                "correction_degrees_clockwise": 0.0,
                "measured_content_correction_degrees_clockwise": round(
                    evidence["correction_degrees_clockwise"], 3
                ),
                "line_count": evidence["line_count"],
                "score_ratio": round(evidence["score_ratio"], 3),
            },
        )
        self.assertEqual(
            diagnosed["screen"]["refinement"]["transform_corners"][
                "margin_ratio"
            ],
            camera.ACTIVE_DISPLAY_GUARD_RATIO,
        )
        self.assertEqual(
            diagnosed["screen"]["output"], original["screen"]["output"]
        )
        self.assertEqual(
            diagnosed["fine_rotation_degrees_clockwise"],
            original["fine_rotation_degrees_clockwise"],
        )
        self.assertEqual(
            camera.capture_geometry_fingerprint([diagnosed]),
            camera.capture_geometry_fingerprint([original]),
        )

    def test_verified_physical_alignment_requires_three_physical_edges(self):
        _, _, configured = self.configured_devices(2)
        aligned = deepcopy(configured[0])
        refinement = aligned["screen"]["refinement"]
        refinement["boundary_fit"]["geometry_accepted"] = True
        refinement["boundary_fit"]["accepted_edge_count"] = 3
        refinement["auto_level"] = {}
        self.assertTrue(camera.has_verified_physical_alignment(aligned))

        ui_only = deepcopy(aligned)
        ui_only["screen"]["refinement"]["boundary_fit"] = {}
        self.assertFalse(camera.has_verified_physical_alignment(ui_only))

        weak_physical_fit = deepcopy(aligned)
        weak_physical_fit["screen"]["refinement"]["boundary_fit"][
            "accepted_edge_count"
        ] = 2
        self.assertFalse(camera.has_verified_physical_alignment(weak_physical_fit))

        rejected_geometry = deepcopy(aligned)
        rejected_geometry["screen"]["refinement"]["boundary_fit"][
            "geometry_accepted"
        ] = False
        self.assertFalse(camera.has_verified_physical_alignment(rejected_geometry))

        conflicting_content = deepcopy(aligned)
        conflicting_content["screen"]["refinement"]["auto_level"] = {
            "correction_degrees_clockwise": 0.0,
            "measured_content_correction_degrees_clockwise": 1.75,
            "line_count": 4,
            "score_ratio": 2.0,
        }
        self.assertTrue(camera.has_verified_physical_alignment(conflicting_content))

    def test_only_four_edge_physical_fit_is_complete_and_sticky(self):
        _, _, configured = self.configured_devices(2)
        complete = configured[0]
        three_edges = self.with_boundary_fit(
            complete, accepted_edge_count=3
        )
        invalid = self.with_boundary_fit(
            complete, accepted_edge_count=4, geometry_accepted=False
        )

        self.assertTrue(camera.has_complete_physical_boundary_fit(complete))
        self.assertFalse(camera.has_complete_physical_boundary_fit(three_edges))
        self.assertFalse(camera.has_complete_physical_boundary_fit(invalid))

    def test_weak_physical_fit_synthesizes_a_crop_rejection(self):
        _, _, configured = self.configured_devices(2)
        weak = self.with_boundary_fit(configured[0], accepted_edge_count=2)
        original = {
            "number": 2,
            "crop_valid": True,
            "label_matches": True,
            "upright_portrait": True,
            "issue": "",
        }

        checked = camera.require_physical_boundary_check(weak, original)

        self.assertIsNot(checked, original)
        self.assertFalse(checked["crop_valid"])
        self.assertIn("only 2/4 edges", checked["issue"])
        self.assertIn("status row and complete lower display", checked["issue"])
        self.assertTrue(original["crop_valid"])

    def test_calibration_margin_and_active_display_guard_are_independent(self):
        _, calibration, completed = self.configured_devices(2)
        calibration_screen = calibration[0]["screen"]
        screen = completed[0]["screen"]
        corners = calibration_screen["corners"]["pixels"]
        calibration_transform = calibration_screen["transform_corners"]
        refinement = screen["refinement"]

        self.assertAlmostEqual(camera.CALIBRATION_SCREEN_MARGIN_RATIO, 0.035)
        self.assertEqual(
            calibration_transform["margin_ratio"],
            camera.CALIBRATION_SCREEN_MARGIN_RATIO,
        )
        self.assertNotEqual(calibration_transform["pixels"], corners)
        self.assertEqual(
            calibration_transform["pixels"],
            camera.expanded_screen_corners(
                corners,
                frame_width=1280,
                frame_height=720,
                margin_ratio=camera.CALIBRATION_SCREEN_MARGIN_RATIO,
            ),
        )
        self.assertEqual(
            calibration_screen["output"],
            camera.portrait_output_dimensions(
                calibration_transform["pixels"], label="test calibration"
            ),
        )
        self.assertEqual(screen["intermediate_output"], calibration_screen["output"])
        self.assertEqual(
            refinement["model_source_corners"]["normalized"],
            self.screen_refinement(2)["active_display_corners"],
        )
        self.assertEqual(
            refinement["model_source_corners"]["pixels"]["top_left"],
            camera.normalized_point_to_pixels(
                self.screen_refinement(2)["active_display_corners"]["top_left"],
                width=screen["intermediate_output"]["width"],
                height=screen["intermediate_output"]["height"],
            ),
        )
        self.assertEqual(
            refinement["boundary_fit"]["source_corners_pixels"],
            refinement["source_corners"]["pixels"],
        )
        self.assertEqual(
            refinement["transform_corners"]["margin_ratio"],
            camera.ACTIVE_DISPLAY_GUARD_RATIO,
        )
        self.assertNotIn("inset_ratio", refinement["transform_corners"])
        self.assertNotIn("guard_ratio", refinement["transform_corners"])
        self.assertGreater(camera.ACTIVE_DISPLAY_GUARD_RATIO, 0)
        self.assertEqual(
            refinement["transform_corners"]["pixels"],
            camera.expanded_screen_corners(
                refinement["source_corners"]["pixels"],
                frame_width=screen["intermediate_output"]["width"],
                frame_height=screen["intermediate_output"]["height"],
                margin_ratio=camera.ACTIVE_DISPLAY_GUARD_RATIO,
            ),
        )
        self.assertNotEqual(
            refinement["transform_corners"]["pixels"],
            refinement["source_corners"]["pixels"],
        )
        source = refinement["source_corners"]["pixels"]
        guarded = refinement["transform_corners"]["pixels"]
        self.assertLessEqual(guarded["top_left"]["x"], source["top_left"]["x"])
        self.assertLessEqual(guarded["top_left"]["y"], source["top_left"]["y"])
        self.assertGreaterEqual(
            guarded["bottom_right"]["x"], source["bottom_right"]["x"]
        )
        self.assertGreaterEqual(
            guarded["bottom_right"]["y"], source["bottom_right"]["y"]
        )
        self.assertEqual(
            refinement["auto_level"],
            {
                "correction_degrees_clockwise": 0.0,
                "line_count": 0,
                "score_ratio": 1.0,
            },
        )
        self.assertEqual(
            screen["output"],
            camera.portrait_output_dimensions(
                guarded, label="test active display"
            ),
        )
        self.assertLess(
            screen["output"]["width"], screen["intermediate_output"]["width"]
        )
        self.assertLess(
            screen["output"]["height"], screen["intermediate_output"]["height"]
        )

    def test_sideways_screen_is_rectified_to_portrait_output(self):
        sideways = {
            "number": 3,
            "screen": {"left": 100, "top": 200, "right": 800, "bottom": 500},
            "screen_corners": {
                "top_left": {"x": 790, "y": 210},
                "top_right": {"x": 790, "y": 490},
                "bottom_left": {"x": 110, "y": 210},
                "bottom_right": {"x": 110, "y": 490},
            },
            "label": {"left": 20, "top": 200, "right": 80, "bottom": 300},
            "confidence": 0.99,
        }
        detected = camera.validate_vision_devices([sideways])
        calibration = camera.attach_pixel_boxes(
            detected,
            width=1280,
            height=720,
            margin_ratio=camera.CALIBRATION_SCREEN_MARGIN_RATIO,
        )
        refinement = self.screen_refinement(2)
        refinement["number"] = 3
        configured = camera.attach_screen_refinements(calibration, [refinement])[0]

        self.assertGreater(
            configured["screen"]["pixels"]["width"],
            configured["screen"]["pixels"]["height"],
        )
        self.assertLess(
            configured["screen"]["output"]["width"],
            configured["screen"]["output"]["height"],
        )
        self.assertEqual(configured["base_rotation_degrees_clockwise"], -90.0)
        self.assertEqual(
            configured["rotation_degrees_clockwise"],
            camera.normalize_rotation_degrees(
                configured["base_rotation_degrees_clockwise"]
                + configured["fine_rotation_degrees_clockwise"]
            ),
        )
        self.assertEqual(
            [configured["screen"]["output"][key] % 2 for key in ("width", "height")],
            [0, 0],
        )

    def test_pixel_conversion_and_even_video_crop(self):
        pixels = camera.normalized_to_pixels(
            {"left": 101, "top": 101, "right": 402, "bottom": 803},
            width=1280,
            height=720,
        )
        self.assertEqual(pixels, {"x": 129, "y": 73, "width": 386, "height": 505})
        even = camera.even_video_box(pixels, frame_width=1280, frame_height=720)
        self.assertEqual(even, {"x": 128, "y": 72, "width": 388, "height": 506})
        self.assertTrue(all(even[key] % 2 == 0 for key in even))

    def test_atomic_json_replaces_only_after_complete_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.json"
            path.write_text('{"old": true}\n', encoding="utf-8")
            camera.write_json_atomic(path, {"new": True})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"new": True})
            self.assertEqual(list(path.parent.glob(".config.json.*.tmp")), [])

    def test_load_config_and_unknown_device_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_config(Path(temporary))
            config = camera.load_config(path)
            self.assertEqual(camera.configured_device(config, 7)["number"], 7)
            with self.assertRaisesRegex(camera.CameraError, "available devices: 2, 7"):
                camera.configured_device(config, 5)

            config["schema_version"] = 99
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "rerun configure"):
                camera.load_config(path)

    def test_schema_six_loader_accepts_large_corner_round_trip_tolerance(self):
        frame_width, frame_height = 3840, 2160
        detected = camera.validate_vision_devices([self.vision_device(2)])
        calibration = camera.attach_pixel_boxes(
            detected,
            width=frame_width,
            height=frame_height,
            margin_ratio=camera.CALIBRATION_SCREEN_MARGIN_RATIO,
        )
        attached = camera.attach_screen_refinements(
            calibration, [self.screen_refinement(2)]
        )[0]
        intermediate = attached["screen"]["intermediate_output"]
        self.assertGreater(intermediate["width"], camera.NORMALIZED_MAX)
        self.assertGreater(intermediate["height"], camera.NORMALIZED_MAX)

        # A 0..1000 normalized grid cannot represent every source pixel once
        # either dimension exceeds 1000. Preserve such a genuine one-pixel
        # fitted-edge result and rebuild all capture geometry from it.
        attached["screen"]["refinement"]["source_corners"]["pixels"][
            "top_left"
        ]["x"] += 1
        device = self.with_boundary_fit(attached)
        refinement = device["screen"]["refinement"]
        normalized_top_left = refinement["source_corners"]["normalized"][
            "top_left"
        ]
        derived_top_left = camera.normalized_point_to_pixels(
            normalized_top_left,
            width=intermediate["width"],
            height=intermediate["height"],
        )
        self.assertEqual(
            refinement["source_corners"]["pixels"]["top_left"]["x"]
            - derived_top_left["x"],
            1,
        )

        config = self.valid_config()
        config["device_count"] = 1
        config["camera"]["width"] = frame_width
        config["camera"]["height"] = frame_height
        config["devices"] = [device]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".pluto-devices.json"
            path.write_text(json.dumps(config), encoding="utf-8")
            loaded = camera.load_config(path)

        self.assertEqual(loaded["schema_version"], 6)
        self.assertEqual(loaded["devices"][0]["number"], 2)

    def test_load_config_rejects_out_of_frame_box_and_bad_camera_type(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_config(Path(temporary))
            config = json.loads(path.read_text(encoding="utf-8"))
            config["devices"][0]["screen"]["pixels"]["width"] = 2000
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "out-of-frame"):
                camera.load_config(path)

            config = self.valid_config()
            config["camera"]["width"] = "not-a-number"
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "invalid camera source"):
                camera.load_config(path)

    def test_load_config_rejects_rotation_that_disagrees_with_corners(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_config(Path(temporary))
            config = json.loads(path.read_text(encoding="utf-8"))
            config["devices"][0]["rotation_degrees_clockwise"] += 1.0
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "rotation does not match"):
                camera.load_config(path)

            config = self.valid_config()
            config["devices"][0]["base_rotation_degrees_clockwise"] += 1.0
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "rotation does not match"):
                camera.load_config(path)

            config = self.valid_config()
            config["devices"][0]["fine_rotation_degrees_clockwise"] += 1.0
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "rotation does not match"):
                camera.load_config(path)

    def test_load_config_rejects_outside_and_misordered_pixel_corners(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".pluto-devices.json"

            outside = self.valid_config()
            crop = outside["devices"][0]["screen"]["pixels"]
            outside["devices"][0]["screen"]["corners"]["pixels"]["top_left"][
                "x"
            ] = crop["x"] - 1
            path.write_text(json.dumps(outside), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "corner outside crop"):
                camera.load_config(path)

            misordered = self.valid_config()
            corners = misordered["devices"][0]["screen"]["corners"]["pixels"]
            corners["top_right"], corners["bottom_left"] = (
                corners["bottom_left"],
                corners["top_right"],
            )
            path.write_text(json.dumps(misordered), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "misordered"):
                camera.load_config(path)

    def test_load_config_rejects_invalid_calibration_and_refinement_transforms(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".pluto-devices.json"

            bad_margin = self.valid_config()
            bad_margin["devices"][0]["screen"]["transform_corners"][
                "margin_ratio"
            ] = 0.02
            path.write_text(json.dumps(bad_margin), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "calibration transform"):
                camera.load_config(path)

            bad_corner = self.valid_config()
            bad_corner["devices"][0]["screen"]["transform_corners"]["pixels"][
                "top_left"
            ]["x"] += 1
            path.write_text(json.dumps(bad_corner), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "calibration transform"):
                camera.load_config(path)

            bad_guard = self.valid_config()
            bad_guard["devices"][0]["screen"]["refinement"][
                "transform_corners"
            ]["margin_ratio"] = 0.02
            path.write_text(json.dumps(bad_guard), encoding="utf-8")
            with self.assertRaisesRegex(
                camera.CameraError, "active-display refinement"
            ):
                camera.load_config(path)

            bad_refinement_corner = self.valid_config()
            bad_refinement_corner["devices"][0]["screen"]["refinement"][
                "transform_corners"
            ]["pixels"]["top_left"]["x"] += 1
            path.write_text(json.dumps(bad_refinement_corner), encoding="utf-8")
            with self.assertRaisesRegex(
                camera.CameraError, "active-display refinement"
            ):
                camera.load_config(path)

    def test_image_stays_screen_only_while_video_adds_timestamp_footer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = self.write_config(root)
            config = self.valid_config()
            expected_filter = camera.device_capture_filter(config["devices"][0])
            image_args = argparse.Namespace(
                config=str(config_path),
                device=2,
                output=str(root / "out.jpg"),
                timeout=12.0,
            )
            video_args = argparse.Namespace(
                config=str(config_path),
                device=2,
                output=str(root / "out.mp4"),
                seconds=3.5,
                timeout=12.0,
            )
            with mock.patch.object(camera, "require_commands"), mock.patch.object(
                camera,
                "resolve_configured_camera",
                side_effect=lambda source, timeout: source,
            ), mock.patch.object(
                camera,
                "camera_lock",
                side_effect=lambda config_path: contextlib.nullcontext(),
            ), mock.patch.object(
                camera, "run_atomic_capture"
            ) as capture, contextlib.redirect_stdout(io.StringIO()):
                camera.capture_image(image_args)
                image_command = capture.call_args.args[0]
                capture.reset_mock()
                camera.capture_video(video_args)
                video_command = capture.call_args.args[0]
                video_timeout = capture.call_args.kwargs["timeout"]

        image_filter = image_command[image_command.index("-vf") + 1]
        video_filter = video_command[video_command.index("-vf") + 1]
        self.assertEqual(image_command[image_command.index("-i") + 1], "3:none")
        self.assertEqual(image_command[image_command.index("-ss") + 1], "0.350")
        self.assertEqual(image_filter, expected_filter)
        self.assertNotIn("pad=", image_filter)
        self.assertNotIn("drawtext=", image_filter)
        video_prefix = f"trim=start=0.350,setpts=PTS-STARTPTS,{expected_filter},"
        self.assertTrue(video_filter.startswith(video_prefix))
        video_suffix = video_filter.removeprefix(video_prefix)
        self.assertIn("setpts=PTS-STARTPTS", video_suffix)
        self.assertIn("pad=", video_suffix)
        self.assertIn("ih+", video_suffix)
        self.assertIn(":x=0:y=0:color=black", video_suffix)
        self.assertIn("drawtext=", video_suffix)
        self.assertIn("text='%{pts\\:hms}'", video_suffix)
        self.assertIn("fontcolor=white", video_suffix)
        self.assertIn("x=(w-text_w)/2", video_suffix)
        self.assertIn("fix_bounds=1", video_suffix)
        self.assertLess(
            video_suffix.index("setpts=PTS-STARTPTS"),
            video_suffix.index("pad="),
        )
        self.assertLess(video_suffix.index("pad="), video_suffix.index("drawtext="))
        filter_stages = image_filter.split(",")
        self.assertEqual(len(filter_stages), 8)
        for offset in (0, 4):
            self.assertTrue(filter_stages[offset].startswith("crop="))
            self.assertTrue(filter_stages[offset + 1].startswith("perspective="))
            self.assertTrue(filter_stages[offset + 2].startswith("scale="))
            self.assertEqual(filter_stages[offset + 3], "setsar=1")
        screen = config["devices"][0]["screen"]
        self.assertEqual(
            filter_stages[2],
            f"scale={screen['intermediate_output']['width']}:"
            f"{screen['intermediate_output']['height']}:flags=lanczos",
        )
        self.assertEqual(
            filter_stages[6],
            f"scale={screen['output']['width']}:"
            f"{screen['output']['height']}:flags=lanczos",
        )
        self.assertEqual(video_command[video_command.index("-t") + 1], "3.5")
        self.assertNotIn("-ss", video_command)
        self.assertIn("libx264", video_command)
        self.assertEqual(video_timeout, 15.85)

    def test_refinement_and_verification_stages_have_separate_schemas(self):
        devices, _, configured = self.configured_devices(2)
        refinement_schema = camera.refinement_schema()
        refinement_item = refinement_schema["properties"]["devices"]["items"]
        refinement_prompt = camera.refinement_prompt(devices)
        compact_refinement_prompt = " ".join(refinement_prompt.split())
        self.assertEqual(refinement_schema["required"], ["devices", "notes"])
        self.assertEqual(
            refinement_item["required"],
            ["number", "active_display_corners", "confidence"],
        )
        self.assertIn("INNER active-display corners", refinement_prompt)
        self.assertIn(
            "0..1000 grid relative to that crop itself", compact_refinement_prompt
        )
        self.assertIn(
            "priors for a local physical-edge fit", compact_refinement_prompt
        )
        self.assertIn(
            "fits all four long display/bezel transitions", compact_refinement_prompt
        )
        self.assertIn("time/battery/status row is screen content", compact_refinement_prompt)
        self.assertIn("tone or shading transition alone never proves bezel", compact_refinement_prompt)

        verification_prompt = camera.verification_prompt(devices, configured)
        compact_verification_prompt = " ".join(verification_prompt.split())
        self.assertIn("omits any visible time/battery/status row", compact_verification_prompt)
        self.assertIn("extent of currently bright UI content", compact_verification_prompt)
        self.assertIn("small outward safety guard", refinement_prompt)
        self.assertIn("preserving every display pixel", refinement_prompt)
        self.assertIn(
            "completely different physical size and aspect ratio",
            compact_refinement_prompt,
        )

        schema = camera.verification_schema()
        prompt = camera.verification_prompt(
            devices,
            configured,
            include_calibration_references=True,
            include_capture_footprint=True,
        )
        compact_prompt = " ".join(prompt.split())
        check_schema = schema["properties"]["checks"]["items"]
        self.assertEqual(schema["required"], ["valid", "checks", "notes"])
        self.assertEqual(
            check_schema["required"],
            [
                "number",
                "crop_valid",
                "label_matches",
                "upright_portrait",
                "issue",
            ],
        )
        self.assertIn("Return exactly one short check for each", compact_prompt)
        self.assertIn("Do not re-estimate or return geometry", compact_prompt)
        self.assertIn("expanded calibration reference", prompt)
        self.assertIn("narrow inner-bezel safety guard", prompt)
        self.assertIn("preserving every display pixel", compact_prompt)
        self.assertIn("separate full-width line measurement", compact_prompt)
        self.assertIn(
            "Physical display/bezel geometry remains authoritative", compact_prompt
        )
        self.assertIn("full rig footprint preview", compact_prompt)
        self.assertIn(
            "green quadrilateral has a different partial-degree slope",
            compact_prompt,
        )
        self.assertIn("active_display_guard_ratio_per_edge", compact_prompt)
        self.assertIn("normally 0.025", compact_prompt)
        self.assertIn("at least three physical edges", compact_prompt)
        self.assertIn("greater than about 0.2 degrees", compact_prompt)
        self.assertIn("crop_valid is independent of upright_portrait", compact_prompt)
        self.assertIn("Hardware buttons", compact_prompt)
        self.assertIn("lists accepted_edges", compact_prompt)
        self.assertNotIn("Even a one-pixel rise/fall", prompt)
        self.assertNotIn("Return corrected active_display_corners", prompt)

        proposal = json.loads(camera.device_proposal_json(devices, configured))[0]
        self.assertEqual(
            proposal["active_display_guard_ratio_per_edge"],
            camera.ACTIVE_DISPLAY_GUARD_RATIO,
        )
        self.assertEqual(
            proposal["physical_boundary_fit"]["accepted_edge_count"], 4
        )
        self.assertTrue(
            proposal["physical_boundary_fit"]["geometry_accepted"]
        )
        self.assertEqual(
            proposal["physical_boundary_fit"]["accepted_edges"],
            {name: True for name in camera.BOUNDARY_EDGE_DEFINITIONS},
        )

        correction = camera.refinement_correction_prompt(
            devices,
            configured,
            checks=[
                {
                    "number": 2,
                    "crop_valid": False,
                    "label_matches": True,
                    "upright_portrait": True,
                    "issue": "right edge clipped",
                }
            ],
            notes="expand the transform",
        )
        self.assertIn("Return corrected active_display_corners", correction)
        self.assertIn("EXPANDED\nCALIBRATION attachment", correction)
        self.assertIn("return exactly the rejected devices", correction.replace("\n", " "))
        self.assertIn("right edge clipped", correction)
        compact_correction = " ".join(correction.split())
        self.assertIn("RESTORE a clipped top, DECREASE", compact_correction)
        self.assertIn("clipped bottom by INCREASING", compact_correction)
        self.assertIn("clipped left edge by DECREASING", compact_correction)
        self.assertIn("clipped right edge by INCREASING", compact_correction)
        self.assertNotIn("normal nearly-full screen", compact_correction)

    def test_verification_checks_require_consistent_per_device_verdicts(self):
        passing = [
            {
                "number": 2,
                "crop_valid": True,
                "label_matches": True,
                "upright_portrait": True,
                "issue": "",
            }
        ]
        self.assertTrue(
            camera.validate_verification_checks(
                passing, expected_numbers={2}, global_valid=True
            )
        )

        rejected = deepcopy(passing)
        rejected[0]["crop_valid"] = False
        rejected[0]["issue"] = "bottom edge clipped"
        self.assertFalse(
            camera.validate_verification_checks(
                rejected, expected_numbers={2}, global_valid=False
            )
        )
        passing_seven = deepcopy(passing[0])
        passing_seven["number"] = 7
        self.assertEqual(
            camera.verification_rejected_numbers(
                [passing_seven, rejected[0]],
                expected_numbers={2, 7},
                global_valid=False,
            ),
            {2},
        )
        with self.assertRaisesRegex(camera.CameraError, "inconsistent verdict"):
            camera.validate_verification_checks(
                rejected, expected_numbers={2}, global_valid=True
            )
        with self.assertRaisesRegex(camera.CameraError, "set of red device numbers"):
            camera.validate_verification_checks(
                passing, expected_numbers={7}, global_valid=True
            )

    def test_capture_fingerprint_ignores_label_but_tracks_rectification(self):
        _, _, configured = self.configured_devices(2)
        original = camera.capture_geometry_fingerprint(configured)

        label_only = deepcopy(configured)
        label_only[0]["label"]["pixels"]["x"] += 20
        label_only[0]["confidence"] = 0.1
        self.assertEqual(
            original, camera.capture_geometry_fingerprint(label_only)
        )

        transformed = deepcopy(configured)
        transformed[0]["screen"]["refinement"]["transform_corners"]["pixels"][
            "top_left"
        ]["x"] += 2
        self.assertNotEqual(
            original, camera.capture_geometry_fingerprint(transformed)
        )

    def test_devices_keep_independent_final_sizes_and_aspect_ratios(self):
        _, _, configured = self.configured_devices(2, 7)
        first_output = configured[0]["screen"]["output"]
        second_output = configured[1]["screen"]["output"]

        self.assertNotEqual(first_output, second_output)
        self.assertNotEqual(
            first_output["width"] / first_output["height"],
            second_output["width"] / second_output["height"],
        )
        for device in configured:
            output = device["screen"]["output"]
            self.assertIn(
                f"scale={output['width']}:{output['height']}:flags=lanczos",
                camera.device_capture_filter(device),
            )

    def test_valid_verifier_saves_the_last_rendered_transform(self):
        detection = self.vision_device(2)
        refinement = self.screen_refinement(2)
        verification = {
            "valid": True,
            "checks": [
                {
                    "number": 2,
                    "crop_valid": True,
                    "label_matches": True,
                    "upright_portrait": True,
                    "issue": "",
                }
            ],
            "notes": "submitted transformed crop is valid",
        }
        with tempfile.TemporaryDirectory() as temporary:
            config, stages, rendered = self.run_synthetic_configure(
                Path(temporary), detection, refinement, [verification]
            )

        calibration = camera.attach_pixel_boxes(
            camera.validate_vision_devices([detection]),
            width=1280,
            height=720,
            margin_ratio=camera.CALIBRATION_SCREEN_MARGIN_RATIO,
        )[0]
        expected = camera.attach_screen_refinements(
            [calibration], [refinement]
        )[0]
        expected = self.with_boundary_fit(expected)
        self.assertEqual(
            stages,
            [
                "camera-selection",
                "screen-detection",
                "screen-refinement",
                "crop-verification-1",
            ],
        )
        self.assertEqual(rendered, [calibration, expected])
        self.assertEqual(config["devices"][0], expected)

    def test_model_approval_cannot_save_a_two_edge_physical_fit(self):
        detection = self.vision_device(2)
        refinement = self.screen_refinement(2)
        corrected = self.shifted_refinement(refinement, dx=12)
        passing = {
            "valid": True,
            "checks": [
                {
                    "number": 2,
                    "crop_valid": True,
                    "label_matches": True,
                    "upright_portrait": True,
                    "issue": "",
                }
            ],
            "notes": "model sees a plausible crop",
        }
        responses = [
            passing,
            {
                "devices": [corrected],
                "notes": "re-estimated from physical display edges",
            },
            passing,
        ]

        with tempfile.TemporaryDirectory() as temporary:
            config, stages, _ = self.run_synthetic_configure(
                Path(temporary),
                detection,
                refinement,
                responses,
                boundary_edge_counts=[2, 4],
            )

        self.assertEqual(
            stages,
            [
                "camera-selection",
                "screen-detection",
                "screen-refinement",
                "crop-verification-1",
                "screen-refinement-correction-1",
                "crop-verification-2",
            ],
        )
        self.assertEqual(
            config["devices"][0]["screen"]["refinement"]["boundary_fit"][
                "accepted_edge_count"
            ],
            4,
        )
        self.assertEqual(
            config["devices"][0]["screen"]["refinement"]["model_source_corners"]
            ["normalized"],
            corrected["active_display_corners"],
        )

    def test_passing_geometry_stays_accepted_while_another_device_is_corrected(self):
        detections = [self.vision_device(2), self.vision_device(7)]
        refinements = [self.screen_refinement(2), self.screen_refinement(7)]
        corrected_seven = self.shifted_refinement(refinements[1], dx=20)
        verifications = [
            {
                "valid": False,
                "checks": [
                    {
                        "number": 2,
                        "crop_valid": True,
                        "label_matches": True,
                        "upright_portrait": True,
                        "issue": "",
                    },
                    {
                        "number": 7,
                        "crop_valid": False,
                        "label_matches": True,
                        "upright_portrait": True,
                        "issue": "right edge clipped",
                    }
                ],
                "notes": "move only device 7 right",
            },
            {
                "devices": [corrected_seven],
                "notes": "corrected active-display refinement",
            },
            {
                "valid": False,
                "checks": [
                    {
                        "number": 2,
                        "crop_valid": False,
                        "label_matches": True,
                        "upright_portrait": False,
                        "issue": "non-deterministic regression on unchanged crop",
                    },
                    {
                        "number": 7,
                        "crop_valid": True,
                        "label_matches": True,
                        "upright_portrait": True,
                        "issue": "",
                    }
                ],
                "notes": "device 7 is corrected; device 2 verdict regressed",
            },
        ]
        with tempfile.TemporaryDirectory() as temporary:
            config, stages, rendered = self.run_synthetic_configure(
                Path(temporary), detections, refinements, verifications
            )

        calibration = camera.attach_pixel_boxes(
            camera.validate_vision_devices(detections),
            width=1280,
            height=720,
            margin_ratio=camera.CALIBRATION_SCREEN_MARGIN_RATIO,
        )
        originals = camera.attach_screen_refinements(calibration, refinements)
        originals = [self.with_boundary_fit(device) for device in originals]
        corrected = camera.attach_screen_refinements(
            [calibration[1]], [corrected_seven]
        )[0]
        corrected = self.with_boundary_fit(corrected)
        self.assertEqual(
            stages,
            [
                "camera-selection",
                "screen-detection",
                "screen-refinement",
                "crop-verification-1",
                "screen-refinement-correction-1",
                "crop-verification-2",
            ],
        )
        self.assertEqual(
            rendered,
            [
                calibration[0],
                calibration[1],
                originals[0],
                originals[1],
                originals[0],
                corrected,
            ],
        )
        self.assertEqual(config["devices"][0], originals[0])
        self.assertEqual(config["devices"][1], corrected)

    def test_three_edge_geometry_is_not_sticky_against_later_clipping(self):
        detections = [self.vision_device(2), self.vision_device(7)]
        refinements = [self.screen_refinement(2), self.screen_refinement(7)]
        corrected_seven = self.shifted_refinement(refinements[1], dx=16)
        corrected_two = self.shifted_refinement(refinements[0], dy=-14)

        def check(number, *, crop_valid=True):
            return {
                "number": number,
                "crop_valid": crop_valid,
                "label_matches": True,
                "upright_portrait": True,
                "issue": "" if crop_valid else "top status row is clipped",
            }

        responses = [
            {
                "valid": False,
                "checks": [check(2), check(7, crop_valid=False)],
                "notes": "correct device 7 first",
            },
            {"devices": [corrected_seven], "notes": "device 7 corrected"},
            {
                "valid": False,
                "checks": [check(2, crop_valid=False), check(7)],
                "notes": "device 2 clipping is now clear",
            },
            {"devices": [corrected_two], "notes": "device 2 corrected"},
            {
                "valid": True,
                "checks": [check(2), check(7)],
                "notes": "both crops are complete",
            },
        ]

        with tempfile.TemporaryDirectory() as temporary:
            config, stages, _ = self.run_synthetic_configure(
                Path(temporary),
                detections,
                refinements,
                responses,
                boundary_edge_counts=[3, 4, 4, 4],
            )

        self.assertEqual(
            stages,
            [
                "camera-selection",
                "screen-detection",
                "screen-refinement",
                "crop-verification-1",
                "screen-refinement-correction-1",
                "crop-verification-2",
                "screen-refinement-correction-2",
                "crop-verification-3",
            ],
        )
        by_number = {device["number"]: device for device in config["devices"]}
        self.assertEqual(
            by_number[2]["screen"]["refinement"]["boundary_fit"][
                "accepted_edge_count"
            ],
            4,
        )
        self.assertEqual(
            by_number[7]["screen"]["refinement"]["boundary_fit"][
                "accepted_edge_count"
            ],
            4,
        )

    def test_load_config_rejects_nonportrait_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_config(Path(temporary))
            config = json.loads(path.read_text(encoding="utf-8"))
            config["devices"][0]["screen"]["output"] = {
                "width": 600,
                "height": 400,
            }
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "portrait output"):
                camera.load_config(path)

    def test_load_config_rejects_absurd_outputs_that_disagree_with_edge_lengths(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".pluto-devices.json"

            absurd_final = self.valid_config()
            absurd_final["devices"][0]["screen"]["output"] = {
                "width": 100000,
                "height": 200000,
            }
            path.write_text(json.dumps(absurd_final), encoding="utf-8")
            with self.assertRaisesRegex(
                camera.CameraError, "final output does not match its transform"
            ):
                camera.load_config(path)

            absurd_intermediate = self.valid_config()
            absurd_intermediate["devices"][0]["screen"]["intermediate_output"] = {
                "width": 100000,
                "height": 200000,
            }
            path.write_text(json.dumps(absurd_intermediate), encoding="utf-8")
            with self.assertRaisesRegex(
                camera.CameraError, "intermediate output does not match its transform"
            ):
                camera.load_config(path)

    def test_load_config_rejects_tampered_per_device_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_config(Path(temporary))
            config = json.loads(path.read_text(encoding="utf-8"))
            config["devices"][0]["screen"]["refinement"]["coverage"][
                "width_ratio"
            ] += 0.1
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(camera.CameraError, "coverage"):
                camera.load_config(path)

    def test_capture_footprint_projects_guarded_final_crop_back_to_camera_frame(self):
        device = {
            "number": 9,
            "screen": {
                "pixels": {"x": 100, "y": 50, "width": 101, "height": 101},
                "transform_corners": {
                    "pixels": {
                        "top_left": {"x": 100, "y": 50},
                        "top_right": {"x": 200, "y": 50},
                        "bottom_left": {"x": 120, "y": 150},
                        "bottom_right": {"x": 180, "y": 150},
                    }
                },
                "intermediate_output": {"width": 100, "height": 100},
                "refinement": {
                    # These unguarded corners intentionally disagree with the
                    # transform below. Identify must show the exact guarded and
                    # auto-levelled footprint used by device_capture_filter.
                    "source_corners": {
                        "pixels": {
                            "top_left": {"x": 30, "y": 30},
                            "top_right": {"x": 70, "y": 30},
                            "bottom_left": {"x": 30, "y": 70},
                            "bottom_right": {"x": 70, "y": 70},
                        }
                    },
                    "transform_corners": {
                        "pixels": {
                            "top_left": {"x": 25, "y": 25},
                            "top_right": {"x": 75, "y": 25},
                            "bottom_left": {"x": 25, "y": 75},
                            "bottom_right": {"x": 75, "y": 75},
                        }
                    },
                },
            },
        }

        footprint = camera.device_capture_footprint(device)
        expected = {
            "top_left": {"x": 128.5714286, "y": 85.7142857},
            "top_right": {"x": 171.4285714, "y": 85.7142857},
            "bottom_left": {"x": 133.3333333, "y": 133.3333333},
            "bottom_right": {"x": 166.6666667, "y": 133.3333333},
        }
        for corner, point in expected.items():
            self.assertAlmostEqual(footprint[corner]["x"], point["x"], places=5)
            self.assertAlmostEqual(footprint[corner]["y"], point["y"], places=5)

    def test_footprint_source_edge_thicknesses_scale_per_axis_and_device(self):
        narrow_tall = {
            "top_left": {"x": 100.0, "y": 80.0},
            "top_right": {"x": 250.0, "y": 90.0},
            "bottom_left": {"x": 120.0, "y": 580.0},
            "bottom_right": {"x": 270.0, "y": 590.0},
        }
        wide_short = {
            "top_left": {"x": 100.0, "y": 100.0},
            "top_right": {"x": 1000.0, "y": 80.0},
            "bottom_left": {"x": 110.0, "y": 260.0},
            "bottom_right": {"x": 1010.0, "y": 240.0},
        }

        narrow_bands = camera.footprint_source_edge_thicknesses(
            1280, 720, narrow_tall, 6
        )
        wide_bands = camera.footprint_source_edge_thicknesses(
            1280, 720, wide_short, 6
        )

        def values(bands):
            if isinstance(bands, dict):
                return bands["vertical"], bands["horizontal"]
            return bands.vertical, bands.horizontal

        narrow_vertical, narrow_horizontal = values(narrow_bands)
        wide_vertical, wide_horizontal = values(wide_bands)
        for value in (
            narrow_vertical,
            narrow_horizontal,
            wide_vertical,
            wide_horizontal,
        ):
            self.assertIsInstance(value, int)
            self.assertGreater(value, 0)

        # A narrow footprint needs wider source bands on its vertical sides;
        # a short footprint needs wider source bands on its horizontal sides.
        self.assertGreater(narrow_vertical, wide_vertical)
        self.assertLess(narrow_horizontal, wide_horizontal)

        narrow_outer = camera.footprint_source_edge_thicknesses(
            1280, 720, narrow_tall, 10
        )
        outer_vertical, outer_horizontal = values(narrow_outer)
        self.assertGreater(outer_vertical, narrow_vertical)
        self.assertGreater(outer_horizontal, narrow_horizontal)

    def test_identify_overlay_has_red_regions_and_exact_green_footprint_per_device(self):
        config = self.valid_config()
        overlay = camera.identify_filter(config)
        first, second = config["devices"]
        for device in (first, second):
            screen = device["screen"]["pixels"]
            label = device["label"]["pixels"]
            self.assertIn(
                f"drawbox=x={screen['x']}:y={screen['y']}:"
                f"w={screen['width']}:h={screen['height']}",
                overlay,
            )
            self.assertIn(
                f"text='DEVICE {device['number']}':"
                f"x='max(0,min({label['x']},w-text_w-12))'",
                overlay,
            )
        self.assertEqual(overlay.count("color=red@0.95"), 2)
        self.assertEqual(overlay.count("color=lime@1.0"), 8)
        self.assertEqual(overlay.count("sense=destination"), 2)
        self.assertEqual(overlay.count("overlay="), 2)

    def test_identify_footprints_use_solid_black_backed_lime_bands(self):
        config = self.valid_config()
        overlay = camera.identify_filter(config)

        search_from = 0
        for index in range(len(config["devices"])):
            layer_start = overlay.index("color=c=black:s=", search_from)
            layer_end = overlay.index(f"[footprint{index}]", layer_start)
            layer = overlay[layer_start:layer_end]
            search_from = layer_end

            self.assertEqual(layer.count("color=black@0.90"), 4)
            self.assertEqual(layer.count("color=lime@1.0"), 4)
            self.assertEqual(layer.count("t=fill"), 8)
            self.assertLess(
                layer.rfind("color=black@0.90"),
                layer.find("color=lime@1.0"),
            )
            self.assertNotIn("color=lime@1.0:t=1", layer)

    def test_identify_cli_uses_and_maps_the_complex_overlay_graph(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = self.write_config(root)
            config = self.valid_config()
            args = argparse.Namespace(
                config=str(config_path),
                output=str(root / "identified.jpg"),
                timeout=12.0,
            )
            with mock.patch.object(camera, "require_commands"), mock.patch.object(
                camera,
                "resolve_configured_camera",
                side_effect=lambda source, timeout: source,
            ), mock.patch.object(
                camera,
                "camera_lock",
                side_effect=lambda config_path: contextlib.nullcontext(),
            ), mock.patch.object(
                camera, "run_atomic_capture"
            ) as capture, contextlib.redirect_stdout(io.StringIO()):
                camera.identify(args)
                command = capture.call_args.args[0]

        self.assertNotIn("-vf", command)
        self.assertIn("-filter_complex", command)
        self.assertEqual(
            command[command.index("-filter_complex") + 1],
            camera.identify_filter(config),
        )
        self.assertIn("-map", command)
        mapped_output = command[command.index("-map") + 1]
        self.assertTrue(mapped_output.startswith("[") and mapped_output.endswith("]"))

    def test_parser_accepts_config_after_subcommand(self):
        parser = camera.build_parser()
        args = parser.parse_args(
            [
                "image",
                "--config",
                "/tmp/custom.json",
                "--device",
                "7",
                "--output",
                "/tmp/device.jpg",
            ]
        )
        self.assertEqual(args.config, "/tmp/custom.json")
        self.assertEqual(args.device, 7)

    def test_parser_accepts_config_before_subcommand(self):
        parser = camera.build_parser()
        args = parser.parse_args(
            [
                "--config",
                "/tmp/custom.json",
                "identify",
                "--output",
                "/tmp/rig.jpg",
            ]
        )
        self.assertEqual(args.config, "/tmp/custom.json")

    def test_legacy_invalid_duration_is_a_controlled_error(self):
        with self.assertRaisesRegex(camera.CameraError, "invalid --seconds"):
            camera.legacy_capture(["/tmp/out.mp4", "--seconds", "nope"])


if __name__ == "__main__":
    unittest.main()
