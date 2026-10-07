"""Pad Conv input channels to a multiple of N without changing the math.

ncnn Vulkan selects elempack from the channel count; RVM decoder convs read
concat(features, RGB) with 35/59/107/171 channels, which forces the slow
pack1 path on Adreno. This appends zero channels to the producing Concat and
zero input-channel weights to the Conv, then checks ORT outputs over a
recurrent sequence against the unpadded graph.
"""
import argparse
from pathlib import Path

import numpy as np
import onnx
from onnx import helper, numpy_helper, shape_inference
import onnxruntime as ort


def pad_model(model: onnx.ModelProto, multiple: int) -> list[str]:
    model = model
    inferred = shape_inference.infer_shapes(model)
    shapes = {v.name: [d.dim_value for d in v.type.tensor_type.shape.dim]
              for v in list(inferred.graph.value_info) + list(inferred.graph.input)}
    inits = {i.name: i for i in model.graph.initializer}
    producer = {o: n for n in model.graph.node for o in n.output}
    consumers = {}
    for n in model.graph.node:
        for i in n.input:
            consumers.setdefault(i, []).append(n)
    changed = []
    for node in list(model.graph.node):
        if node.op_type != 'Conv':
            continue
        group = next((a.i for a in node.attribute if a.name == 'group'), 1)
        weight = numpy_helper.to_array(inits[node.input[1]])
        cin = weight.shape[1] * group
        if group != 1 or cin % multiple == 0:
            continue
        src = producer.get(node.input[0])
        if src is None or src.op_type != 'Concat' or len(consumers[node.input[0]]) != 1:
            continue
        axis = next(a.i for a in src.attribute if a.name == 'axis')
        shape = shapes[node.input[0]]
        if axis != 1 or len(shape) != 4 or not all(shape):
            continue
        pad = multiple - cin % multiple
        zeros_name = f'{node.name}_pad_zeros'
        model.graph.initializer.append(numpy_helper.from_array(
            np.zeros((shape[0], pad, shape[2], shape[3]), np.float32), zeros_name))
        src.input.append(zeros_name)
        padded = np.concatenate([weight, np.zeros((weight.shape[0], pad) + weight.shape[2:], weight.dtype)], axis=1)
        inits[node.input[1]].CopyFrom(numpy_helper.from_array(padded, node.input[1]))
        changed.append(f'{node.name}: {cin}->{cin + pad} ({shape[2]}x{shape[3]})')
    return changed


def verify(reference: Path, candidate: Path, frames: int = 4) -> float:
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    a = ort.InferenceSession(str(reference), opts, providers=['CPUExecutionProvider'])
    b = ort.InferenceSession(str(candidate), opts, providers=['CPUExecutionProvider'])
    feeds = {i.name: np.zeros([d for d in i.shape], np.float32) for i in a.get_inputs()}
    rng = np.random.default_rng(20261004)
    worst = 0.0
    sa, sb = dict(feeds), dict(feeds)
    for _ in range(frames):
        rgb = rng.random(feeds['src'].shape, dtype=np.float32)
        sa['src'] = sb['src'] = rgb
        oa = a.run(None, sa)
        ob = b.run(None, sb)
        worst = max(worst, max(float(np.max(np.abs(x - y))) for x, y in zip(oa, ob)))
        for k, i in enumerate(range(1, 5)):
            sa[f'r{i}i'] = oa[2 + k]
            sb[f'r{i}i'] = ob[2 + k]
    return worst


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--multiple', type=int, default=4)
    args = parser.parse_args()
    model = onnx.load(args.input)
    changed = pad_model(model, args.multiple)
    onnx.checker.check_model(model)
    onnx.save(model, args.output)
    print('\n'.join(changed))
    print(f'max |padded - original| over 4 recurrent frames: {verify(args.input, args.output):.3e}')


if __name__ == '__main__':
    main()
