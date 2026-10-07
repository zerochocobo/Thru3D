"""Compare full ncnn recurrence with ONNX; desktop results are not Quest performance."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time

import ncnn
import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
OUTPUTS = ["fgr", "pha", "r1o", "r2o", "r3o", "r4o"]


class NcnnRvm:
    def __init__(self, directory: Path, profile: dict, generic_cpu: bool = False):
        self.profile = profile
        self.net = ncnn.Net()
        self.net.opt.use_vulkan_compute = False
        self.net.opt.num_threads = 4
        self.net.opt.use_fp16_packed = False
        self.net.opt.use_fp16_storage = False
        self.net.opt.use_fp16_arithmetic = False
        self.net.opt.use_bf16_storage = False
        if generic_cpu:
            self.net.opt.num_threads = 1
            self.net.opt.use_packing_layout = False
            self.net.opt.use_winograd_convolution = False
            self.net.opt.use_sgemm_convolution = False
        if self.net.load_param(str(directory / "rvm.ncnn.param")) != 0:
            raise RuntimeError("ncnn param load failed")
        if self.net.load_model(str(directory / "rvm.ncnn.bin")) != 0:
            raise RuntimeError("ncnn weights load failed")
        self.states: dict[str, list[ncnn.Mat]] = {}

    def reset(self, eye: str) -> None:
        states = []
        for index in range(1, 5):
            _, channels, height, width = self.profile["input_shapes"][f"r{index}i"]
            matrix = ncnn.Mat(width, height, channels)
            matrix.fill(0.0)
            states.append(matrix)
        self.states[eye] = states

    def process(self, eye: str, src: np.ndarray) -> list[np.ndarray]:
        if eye not in self.states:
            self.reset(eye)
        with self.net.create_extractor() as extractor:
            extractor.set_light_mode(False)
            if extractor.input("in0", ncnn.Mat(src[0]).clone()) != 0:
                raise RuntimeError("ncnn RGB input failed")
            for index, state in enumerate(self.states[eye]):
                if extractor.input(f"in{index + 1}", state) != 0:
                    raise RuntimeError("ncnn state input failed")
            matrices = []
            arrays = []
            for index, name in enumerate(OUTPUTS):
                result, matrix = extractor.extract(f"out{index}")
                if result != 0:
                    raise RuntimeError(f"ncnn {name} extraction failed: {result}")
                array = matrix.numpy()[None].copy()
                if list(array.shape) != self.profile["output_shapes"][name] or not np.isfinite(array).all():
                    raise AssertionError(f"ncnn {name} shape or finite check failed: {array.shape}")
                matrices.append(matrix.clone())
                arrays.append(array)
            self.states[eye] = matrices[2:]
            return arrays

    def close(self) -> None:
        self.states.clear()
        self.net.clear()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=ROOT / "build/rvm/256x144")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/rvm-ncnn-reference/256x144")
    args = parser.parse_args()
    profile = json.loads((args.profile / "profile.json").read_text(encoding="utf-8"))
    for filename, key in [("rvm.ncnn.param", "ncnn_param_sha256"), ("rvm.ncnn.bin", "ncnn_bin_sha256")]:
        if hashlib.sha256((args.profile / filename).read_bytes()).hexdigest() != profile[key]:
            raise ValueError("ncnn candidate differs from conversion manifest")
    args.output.mkdir(parents=True, exist_ok=True)
    session = ort.InferenceSession(str(args.profile / "rvm.fixed.onnx"), providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(20261003)
    frames = {}
    for eye in ("left", "right"):
        base = rng.random(profile["input_shapes"]["src"], dtype=np.float32)
        frames[eye] = [np.roll(base, frame * 8, axis=3).copy() for frame in range(4)]
    runner = NcnnRvm(args.profile, profile)
    reference_states = {eye: {name: np.zeros(shape, dtype=np.float32)
                             for name, shape in profile["input_shapes"].items() if name != "src"} for eye in frames}
    stored = {eye: [] for eye in frames}
    errors = []
    timings = []
    # Independent ONNX streams and interleaved ncnn streams, complete state feedback.
    try:
        for index in range(4):
            for eye in frames:
                src = frames[eye][index]
                reference = session.run(None, {"src": src, **reference_states[eye]})
                reference_states[eye] = {f"r{i+1}i": state for i, state in enumerate(reference[2:])}
                started = time.perf_counter()
                actual = runner.process(eye, src)
                timings.append((time.perf_counter() - started) * 1000)
                stored[eye].append(actual)
                frame_errors = {}
                for name, expected, observed in zip(OUTPUTS, reference, actual):
                    difference = np.abs(observed - expected)
                    frame_errors[name] = {"max_abs": float(difference.max()),
                                          "mean_abs": float(difference.mean()),
                                          "rms": float(np.sqrt(np.mean(difference ** 2)))}
                errors.append({"eye": eye, "frame": index, "outputs": frame_errors})
                np.savez_compressed(args.output / f"{eye}_{index}.npz", src=src,
                                    **{name: value for name, value in zip(OUTPUTS, actual)})
        # Re-run each eye in isolation. This must agree with the interleaved run.
        for eye in frames:
            runner.reset(eye)
            for index, src in enumerate(frames[eye]):
                for expected, actual in zip(stored[eye][index], runner.process(eye, src)):
                    np.testing.assert_allclose(actual, expected, rtol=1e-6, atol=1e-6)
        other_before = [state.numpy().copy() for state in runner.states["right"]]
        runner.reset("left")
        for expected, actual in zip(stored["left"][0], runner.process("left", frames["left"][0])):
            np.testing.assert_allclose(actual, expected, rtol=1e-6, atol=1e-6)
        for expected, actual in zip(other_before, runner.states["right"]):
            np.testing.assert_array_equal(expected, actual.numpy())
        if np.allclose(runner.states["left"][0].numpy(), runner.states["right"][0].numpy()):
            raise AssertionError("Distinct eyes have identical state")
    finally:
        runner.close()
    maxima = {name: max(item["outputs"][name]["max_abs"] for item in errors) for name in OUTPUTS}
    rms = {name: max(item["outputs"][name]["rms"] for item in errors) for name in OUTPUTS}
    # FP32 backend validation bounds; retain raw errors for review.
    bounds = {name: {"max_abs": 1e-4 if name in ("fgr", "pha") else 1e-3, "rms": 1e-4} for name in OUTPUTS}
    passed = all(maxima[name] <= bounds[name]["max_abs"] and rms[name] <= bounds[name]["rms"] for name in OUTPUTS)
    report = {"schema_version": 1, "scope": "Windows ncnn CPU FP32 full recurrence",
              "profile": profile["profile"], "ncnn": ncnn.__version__, "threads": 4,
              "param_sha256": profile["ncnn_param_sha256"], "bin_sha256": profile["ncnn_bin_sha256"],
              "frames_per_eye": 4, "errors": errors, "max_abs": maxima, "max_rms": rms,
              "validation_bounds": bounds, "numerical": "passed" if passed else "failed",
              "eye_isolation": "passed", "reset": "passed", "desktop_sample_ms": timings,
              "quest_performance_tested": False, "quality_tested": False, "android_device_execution": "not_run"}
    (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "errors"}, indent=2))
    if not passed:
        raise AssertionError("ncnn numerical error exceeds the fixed validation bounds; see raw report")


if __name__ == "__main__":
    main()
