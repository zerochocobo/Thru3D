"""Real full-recurrence ONNX reference. Synthetic fixtures do not measure matting quality."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import onnx
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "models/manifest/rvm_mobilenetv3.json"


class RvmReference:
    def __init__(self, model: Path, ratio: float = 1.0):
        self.session = ort.InferenceSession(str(model), providers=["CPUExecutionProvider"])
        self.ratio = np.array([ratio], dtype=np.float32)
        self.states: dict[str, list[np.ndarray]] = {}

    def reset(self, eye: str) -> None:
        self.states[eye] = [np.zeros((1, 1, 1, 1), dtype=np.float32) for _ in range(4)]

    def process(self, eye: str, src: np.ndarray) -> list[np.ndarray]:
        if eye not in self.states:
            self.reset(eye)
        feeds = {"src": src, "downsample_ratio": self.ratio}
        feeds.update({f"r{i + 1}i": state for i, state in enumerate(self.states[eye])})
        outputs = self.session.run(None, feeds)
        for output in outputs:
            if not np.isfinite(output).all():
                raise AssertionError("Model produced a nonfinite output")
        if outputs[1].shape != (1, 1, src.shape[2], src.shape[3]):
            raise AssertionError("Alpha dimensions differ from the RGB frame")
        if float(outputs[1].min()) < 0 or float(outputs[1].max()) > 1:
            raise AssertionError("Alpha is outside [0, 1]")
        if [output.shape[1] for output in outputs[2:]] != [16, 20, 40, 64]:
            raise AssertionError("Recurrent state channels differ from the model contract")
        self.states[eye] = outputs[2:]
        return outputs


def fixtures() -> dict[str, list[np.ndarray]]:
    # Deterministic, distinct eyes with motion; no copyrighted person footage.
    random = np.random.default_rng(20261003)
    result = {}
    for eye in ("left", "right"):
        base = random.random((1, 3, 144, 256), dtype=np.float32)
        result[eye] = [np.roll(base, frame * 8, axis=3).copy() for frame in range(4)]
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/rvm-reference")
    arguments = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    model = ROOT / manifest["file"]
    if hashlib.sha256(model.read_bytes()).hexdigest() != manifest["sha256"]:
        raise ValueError("Source model differs from the pinned hash")
    onnx.checker.check_model(onnx.load(model))
    arguments.output.mkdir(parents=True, exist_ok=True)
    inputs = fixtures()
    runner = RvmReference(model)
    isolated = {}
    timings = []
    for eye, frames in inputs.items():
        isolated[eye] = []
        for index, frame in enumerate(frames):
            started = time.perf_counter()
            outputs = runner.process(eye, frame)
            timings.append((time.perf_counter() - started) * 1000)
            isolated[eye].append(outputs)
            names = [item.name for item in runner.session.get_outputs()]
            np.savez_compressed(arguments.output / f"{eye}_{index}.npz", src=frame, **dict(zip(names, outputs)))

    runner.reset("left")
    runner.reset("right")
    for index in range(4):
        for eye in inputs:
            interleaved = runner.process(eye, inputs[eye][index])
            for expected, actual in zip(isolated[eye][index], interleaved):
                np.testing.assert_allclose(actual, expected, rtol=1e-6, atol=1e-6)
    if np.allclose(runner.states["left"][0], runner.states["right"][0]):
        raise AssertionError("Distinct eyes unexpectedly have identical recurrent state")
    runner.reset("left")
    # Reset must reproduce a fresh stream without changing the other eye's state.
    right_before_reset = [state.copy() for state in runner.states["right"]]
    reset_output = runner.process("left", inputs["left"][0])
    for expected, actual in zip(isolated["left"][0], reset_output):
        np.testing.assert_allclose(actual, expected, rtol=1e-6, atol=1e-6)
    for expected, actual in zip(right_before_reset, runner.states["right"]):
        np.testing.assert_array_equal(actual, expected)

    report = {
        "schema_version": 1,
        "scope": "Windows CPU tensor contract, recurrence, eye isolation, reset",
        "model_sha256": manifest["sha256"],
        "provider": runner.session.get_providers(),
        "onnxruntime": ort.__version__,
        "source_shape": [1, 3, 144, 256],
        "downsample_ratio": 1.0,
        "frames_per_eye": 4,
        "checks": {"onnx_checker": "passed", "full_state_feedback": "passed",
                   "interleaved_eye_isolation": "passed", "reset": "passed"},
        "desktop_sample_ms": timings,
        "quality_tested": False,
        "quest_performance_tested": False,
        "android_conversion_completed": False,
    }
    (arguments.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
