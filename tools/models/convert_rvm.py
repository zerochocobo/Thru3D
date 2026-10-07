"""Freeze a full recurrent RVM profile and produce an unverified ncnn candidate."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

import numpy as np
import onnx
from onnx import numpy_helper
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def set_shape(value: onnx.ValueInfoProto, dimensions: tuple[int, ...]) -> None:
    value.type.tensor_type.shape.ClearField("dim")
    for dimension in dimensions:
        value.type.tensor_type.shape.dim.add().dim_value = dimension


def convert(args: argparse.Namespace) -> dict:
    manifest_path = getattr(args, 'source_manifest', ROOT / "models/manifest/rvm_mobilenetv3.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    source = ROOT / manifest["file"]
    if digest(source) != manifest["sha256"]:
        raise ValueError("RVM source model hash differs from the manifest")
    if args.width < 32 or args.height < 32 or not 0 < args.ratio <= 1:
        raise ValueError("Invalid fixed profile")
    if 'fixed_downsample_ratio' in manifest and args.ratio != manifest['fixed_downsample_ratio']:
        raise ValueError('Requested ratio differs from the explicitly specialized source model')
    args.output.mkdir(parents=True, exist_ok=True)
    reference_options = ort.SessionOptions()
    reference_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    original = ort.InferenceSession(str(source), sess_options=reference_options, providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(20261003)
    rgb = rng.random((1, 3, args.height, args.width), dtype=np.float32)
    ratio = np.array([args.ratio], dtype=np.float32)
    names = [item.name for item in original.get_outputs()]
    bootstrap = {f"r{i}i": np.zeros((1, 1, 1, 1), dtype=np.float32) for i in range(1, 5)}
    has_ratio_input = any(value.name == 'downsample_ratio' for value in original.get_inputs())
    ratio_feed = {'downsample_ratio': ratio} if has_ratio_input else {}
    initial = original.run(None, {"src": rgb, **ratio_feed, **bootstrap})
    shapes = {"src": rgb.shape, **{f"r{i+1}i": output.shape for i, output in enumerate(initial[2:])}}
    graph = onnx.load(source)
    # Each Android profile owns a constant ratio and full, zero-initialized states.
    # This preserves recurrence; it removes only shape/ratio variability for this profile.
    keep = [value for value in graph.graph.input if value.name != "downsample_ratio"]
    del graph.graph.input[:]
    graph.graph.input.extend(keep)
    if has_ratio_input:
        graph.graph.initializer.append(numpy_helper.from_array(ratio, "downsample_ratio"))
    else:
        frozen_ratio = next(value for value in graph.graph.initializer if value.name == 'downsample_ratio')
        np.testing.assert_array_equal(numpy_helper.to_array(frozen_ratio), ratio)
    for value in graph.graph.input:
        set_shape(value, shapes[value.name])
    for value, result in zip(graph.graph.output, initial):
        set_shape(value, result.shape)
    onnx.checker.check_model(graph)
    fixed = args.output / "rvm.fixed.onnx"
    onnx.save(graph, fixed)
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    options.optimized_model_filepath = str(args.output / "rvm.optimized.onnx")
    candidate = ort.InferenceSession(str(fixed), sess_options=options, providers=["CPUExecutionProvider"])
    optimized = onnx.load(options.optimized_model_filepath)
    if any(node.domain not in ("", "ai.onnx") for node in optimized.graph.node):
        raise ValueError("Basic optimization introduced nonstandard operators")
    onnx.checker.check_model(optimized)

    previous_original = bootstrap
    previous_fixed = {name: np.zeros(shape, dtype=np.float32) for name, shape in shapes.items() if name != "src"}
    differences = []
    for index in range(4):
        frame = np.roll(rgb, index * 7, axis=3).copy()
        reference = original.run(None, {"src": frame, **ratio_feed, **previous_original})
        actual = candidate.run(None, {"src": frame, **previous_fixed})
        differences.append({name: float(np.max(np.abs(a - b))) for name, a, b in zip(names, reference, actual)})
        for expected, observed in zip(reference, actual):
            np.testing.assert_allclose(observed, expected, rtol=2e-5, atol=2e-6)
        previous_original = {f"r{i+1}i": output for i, output in enumerate(reference[2:])}
        previous_fixed = {f"r{i+1}i": output for i, output in enumerate(actual[2:])}
    report = {
        "schema_version": 1,
        "profile": f"{args.width}x{args.height}_ratio{args.ratio:g}_fp32",
        "source_sha256": manifest["sha256"],
        "source_manifest_sha256": digest(manifest_path),
        "source_model_id": manifest['model_id'],
        "specialized_source": 'fixed_downsample_ratio' in manifest,
        "input_shapes": {name: list(shape) for name, shape in shapes.items()},
        "output_shapes": {name: list(value.shape) for name, value in zip(names, initial)},
        "downsample_ratio": args.ratio,
        "onnx_fixed_sha256": digest(fixed),
        "onnx_optimized_sha256": digest(Path(options.optimized_model_filepath)),
        "fixed_profile_sequence_max_errors": differences,
        "fixed_profile_sequence": "passed",
        "ncnn_numerical_verification": "pending",
        "android_device_execution": "not_run",
        "quality_tested": False,
    }
    (args.output / "profile.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    arguments = [str(args.pnnx), str(args.output / "rvm.optimized.onnx"),
                 "inputshape=" + ",".join("[" + ",".join(map(str, shape)) + "]" for shape in shapes.values()),
                 "fp16=0", "optlevel=2",
                 f"ncnnparam={args.output / 'rvm.ncnn.param'}", f"ncnnbin={args.output / 'rvm.ncnn.bin'}",
                 f"ncnnpy={args.output / 'rvm_ncnn.py'}"]
    started = time.perf_counter()
    with (args.output / "pnnx.log").open("w", encoding="utf-8") as log:
        result = subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT, check=False)
    report["pnnx_exit_code"] = result.returncode
    report["conversion_seconds"] = time.perf_counter() - started
    report["conversion_command"] = arguments
    param = args.output / "rvm.ncnn.param"
    weights = args.output / "rvm.ncnn.bin"
    if result.returncode != 0 or not param.is_file() or not weights.is_file():
        report["conversion_status"] = "failed"
    else:
        lines = param.read_text(encoding="utf-8").splitlines()[2:]
        unsupported = [line.split()[0] for line in lines if line and "." in line.split()[0]]
        report["unconverted_layer_types"] = sorted(set(unsupported))
        report["conversion_status"] = "failed_unconverted_layers" if unsupported else "candidate_pending_verification"
        report["ncnn_param_sha256"] = digest(param)
        report["ncnn_bin_sha256"] = digest(weights)
    (args.output / "profile.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    if report["conversion_status"].startswith("failed"):
        raise RuntimeError(f"pnnx did not produce a complete ncnn candidate; inspect {args.output / 'pnnx.log'}")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--width", type=int, default=256)
    parser.add_argument("--height", type=int, default=144)
    parser.add_argument("--ratio", type=float, default=1.0)
    parser.add_argument('--source-manifest', type=Path, default=ROOT / 'models/manifest/rvm_mobilenetv3.json')
    parser.add_argument("--pnnx", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "build/rvm/256x144")
    args = parser.parse_args()
    args.output = args.output.resolve()
    print(json.dumps(convert(args), indent=2))


if __name__ == "__main__":
    main()
