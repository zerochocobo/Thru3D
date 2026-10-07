"""Build the MNN depth model behind realtime 2D->3D (flat SBS) on Quest.

Source: Depth Anything V2 Small (Apache-2.0), the ONNX export from
onnx-community/depth-anything-v2-small. PTMediaServer's 2D->3D uses DA3
Base/Large on desktop TensorRT; on the Quest GPU only a ViT-S model fits the
30 fps frame budget, and DAv2-Small is the same DINOv2 ViT-S + DPT family.

The graph is frozen to one 16:9 input (multiples of the 14 px patch) so every
shape computation and the position-embedding interpolation fold into
constants; MNN then has no bicubic resize or dynamic shape ops to place on the
CPU. Inputs are the render bridge's float32 CHW RGB in [0, 1]; ImageNet
normalization is folded into the first ops. The output is DAv2's relative
inverse depth (larger = nearer); the runtime maps it to a 0..1 near map.

Checks: the frozen graph against the original ORT graph on real frames, and
the converted MNN model (CPU, FP32) against the frozen graph.
"""
import os
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'models/source/depth/depth_anything_v2_small.onnx'
OUT = ROOT / 'build/depth'
ASSETS = ROOT / 'android/player-plugin/src/main/assets/depth-mnn'
MNNCONVERT = Path(os.environ.get('MNNCONVERT', 'mnnconvert'))
SAMPLES = [OUT / 'sample_a.png', OUT / 'sample_b.png']
# 18 x 10 patches (16:9 within one patch). Quest 3 MNN OpenCL FP16 per frame: 364x210 ~117 ms,
# 308x168 ~77, 252x140 ~52, 196x112 ~32 (but 14 x 8 patches lose the scene). 252x140 keeps the
# person and background apart at ~19 depth updates/s; the display does not wait for them.
WIDTH, HEIGHT = 252, 140
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def frames(width, height):
    """Real frames as float32 CHW [0, 1], resized like the bridge (bilinear)."""
    from PIL import Image
    out = []
    for path in SAMPLES:
        image = Image.open(path).convert('RGB').resize((width, height), Image.BILINEAR)
        out.append(np.asarray(image, np.float32).transpose(2, 0, 1)[None] / 255.0)
    rng = np.random.default_rng(7)
    out.append(rng.random((1, 3, height, width), dtype=np.float32))
    return out


def freeze(width, height):
    from onnxsim import simplify
    model = onnx.load(str(SOURCE))
    graph = model.graph
    original = graph.input[0].name
    # src (0..1) -> (src - mean) / std == src * (1/std) + (-mean/std): one Mul + Add.
    graph.initializer.extend([
        numpy_helper.from_array((1.0 / STD).reshape(1, 3, 1, 1), 'src_scale'),
        numpy_helper.from_array((-MEAN / STD).reshape(1, 3, 1, 1), 'src_bias'),
    ])
    del graph.input[:]
    graph.input.extend([helper.make_tensor_value_info('src', TensorProto.FLOAT, [1, 3, height, width])])
    graph.node.insert(0, helper.make_node('Add', ['src_scaled', 'src_bias'], [original], name='src_normalize_bias'))
    graph.node.insert(0, helper.make_node('Mul', ['src', 'src_scale'], ['src_scaled'], name='src_normalize_scale'))
    # (1, H, W) -> (1, 1, H, W) named depth: NCHW like every other model output in the runtime.
    produced = graph.output[0].name
    graph.initializer.append(numpy_helper.from_array(np.array([1, 1, height, width], np.int64), 'depth_shape'))
    graph.node.append(helper.make_node('Reshape', [produced, 'depth_shape'], ['depth'], name='depth_nchw'))
    del graph.output[:]
    graph.output.extend([helper.make_tensor_value_info('depth', TensorProto.FLOAT, [1, 1, height, width])])
    simplified, ok = simplify(model)
    if not ok:
        raise SystemExit('onnxsim could not validate the frozen depth graph')
    left = sorted({n.op_type for n in simplified.graph.node} & {'Shape', 'Gather', 'Resize', 'Where', 'Expand', 'Equal'})
    return simplified, left


def split_patch_embedding(model, width, height):
    """MNN OpenCL has no kernel for the ViT's 14x14 stride-14 patch convolution and places it on
    the CPU (the runtime rejects that). The same layer as GPU ops: cut the frame into 14x14
    patches with Reshape/Transpose (channel = c*196 + kh*14 + kw), then a 1x1 convolution
    whose weights are the original kernel flattened in that order."""
    graph = model.graph
    inits = {i.name: i for i in graph.initializer}
    for index, node in enumerate(graph.node):
        attrs = {a.name: helper.get_attribute_value(a) for a in node.attribute}
        if node.op_type != 'Conv' or attrs.get('kernel_shape') != [14, 14] or attrs.get('strides') != [14, 14]:
            continue
        weight = numpy_helper.to_array(inits[node.input[1]])
        out_c, in_c, k, _ = weight.shape
        gh, gw = height // k, width // k
        name = node.name.replace('/', '_')
        graph.initializer.extend([
            numpy_helper.from_array(np.array([1, in_c, gh, k, gw, k], np.int64), name + '_grid'),
            numpy_helper.from_array(np.array([1, in_c * k * k, gh, gw], np.int64), name + '_patches'),
            numpy_helper.from_array(weight.reshape(out_c, in_c * k * k, 1, 1), name + '_w1x1'),
        ])
        replacement = [
            helper.make_node('Reshape', [node.input[0], name + '_grid'], [name + '_grid_out'], name=name + '_grid'),
            helper.make_node('Transpose', [name + '_grid_out'], [name + '_t'], perm=[0, 1, 3, 5, 2, 4], name=name + '_t'),
            helper.make_node('Reshape', [name + '_t', name + '_patches'], [name + '_patches_out'], name=name + '_patches'),
            helper.make_node('Conv', [name + '_patches_out', name + '_w1x1'] + list(node.input[2:]), list(node.output),
                             kernel_shape=[1, 1], name=name + '_1x1'),
        ]
        del graph.node[index]
        for offset, new in enumerate(replacement):
            graph.node.insert(index + offset, new)
        return 1
    return 0


def split_attention_heads(model):
    """Each block reshapes its fused q/k/v projection to 5D [1, N, 3, heads, d], transposes and
    picks q, k and v with Gathers: MNN OpenCL (image memory) lays out at most 4D, so these copies
    ran on the CPU. Same values in 4D: slice the projection's last axis into q, k and v, then
    Reshape [1, N, heads, d] and Transpose to [1, heads, N, d] for the Gathers' consumers."""
    graph = model.graph
    inits = {i.name: i for i in graph.initializer}
    producers = {o: n for n in graph.node for o in n.output}
    consumers = {}
    for n in graph.node:
        for i in n.input:
            consumers.setdefault(i, []).append(n)
    rewritten = 0
    for reshape in list(graph.node):
        if reshape.op_type != 'Reshape' or reshape.input[1] not in inits:
            continue
        target = numpy_helper.to_array(inits[reshape.input[1]]).tolist()
        if len(target) != 5 or target[2] != 3:
            continue
        transposes = consumers.get(reshape.output[0], [])
        if len(transposes) != 1 or transposes[0].op_type != 'Transpose' or \
                [a.ints for a in transposes[0].attribute if a.name == 'perm'][0] != [2, 0, 3, 1, 4]:
            continue
        transpose = transposes[0]
        gathers = consumers.get(transpose.output[0], [])
        picks = {}
        for gather in gathers:
            index = numpy_helper.to_array(inits[gather.input[1]]) if gather.input[1] in inits else None
            if gather.op_type != 'Gather' or index is None or index.size != 1:
                break
            picks[int(index)] = gather
        if sorted(picks) != [0, 1, 2] or len(gathers) != 3:
            continue
        _, tokens, _, heads, dim = target
        width = heads * dim
        base = reshape.name.replace('/', '_')
        graph.initializer.append(numpy_helper.from_array(np.array([1, tokens, heads, dim], np.int64), base + '_heads'))
        graph.initializer.append(numpy_helper.from_array(np.array([-1], np.int64), base + '_axis'))
        nodes = []
        for part in range(3):
            graph.initializer.extend([
                numpy_helper.from_array(np.array([part * width], np.int64), f'{base}_s{part}'),
                numpy_helper.from_array(np.array([(part + 1) * width], np.int64), f'{base}_e{part}'),
            ])
            out = picks[part].output[0]
            nodes += [
                helper.make_node('Slice', [reshape.input[0], f'{base}_s{part}', f'{base}_e{part}', base + '_axis'],
                                 [f'{base}_p{part}'], name=f'{base}_slice{part}'),
                helper.make_node('Reshape', [f'{base}_p{part}', base + '_heads'], [f'{base}_h{part}'], name=f'{base}_heads{part}'),
                helper.make_node('Transpose', [f'{base}_h{part}'], [out], perm=[0, 2, 1, 3], name=f'{base}_t{part}'),
            ]
        position = list(graph.node).index(reshape)
        for old in [reshape, transpose] + list(picks.values()):
            graph.node.remove(old)
        for offset, new in enumerate(nodes):
            graph.node.insert(position + offset, new)
        rewritten += 1
    return rewritten


def check_frozen(frozen_path, width, height):
    reference = ort.InferenceSession(str(SOURCE), providers=['CPUExecutionProvider'])
    frozen = ort.InferenceSession(str(frozen_path), providers=['CPUExecutionProvider'])
    worst = 0.0
    for src in frames(width, height):
        normalized = (src - MEAN.reshape(1, 3, 1, 1)) / STD.reshape(1, 3, 1, 1)
        a = reference.run(None, {reference.get_inputs()[0].name: normalized})[0]
        b = frozen.run(None, {'src': src})[0]
        worst = max(worst, float(np.max(np.abs(a.reshape(b.shape) - b)) / max(1e-6, float(np.max(np.abs(a))))))
    return worst


def check_mnn(mnn_path, frozen_path, width, height):
    import MNN
    frozen = ort.InferenceSession(str(frozen_path), providers=['CPUExecutionProvider'])
    interpreter = MNN.Interpreter(str(mnn_path))
    session = interpreter.createSession({'precision': 'high'})
    src_tensor = interpreter.getSessionInput(session, 'src')
    worst = 0.0
    for src in frames(width, height):
        expected = frozen.run(None, {'src': src})[0]
        host = MNN.Tensor((1, 3, height, width), MNN.Halide_Type_Float, src.copy(), MNN.Tensor_DimensionType_Caffe)
        src_tensor.copyFrom(host)
        interpreter.runSession(session)
        output = interpreter.getSessionOutput(session, 'depth')
        result = MNN.Tensor(output.getShape(), MNN.Halide_Type_Float,
                            np.zeros(expected.shape, np.float32), MNN.Tensor_DimensionType_Caffe)
        output.copyToHostTensor(result)
        got = np.array(result.getData(), np.float32).reshape(expected.shape)
        worst = max(worst, float(np.max(np.abs(got - expected)) / max(1e-6, float(np.max(np.abs(expected))))))
    return worst


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--width', type=int, default=WIDTH)
    parser.add_argument('--height', type=int, default=HEIGHT)
    parser.add_argument('--install', action='store_true', help='copy the verified model into the plugin assets')
    args = parser.parse_args()
    width, height = args.width, args.height
    if width % 14 or height % 14 or width % 2 or height % 2 or width > 512 or height > 512:
        raise SystemExit('Depth input must be even multiples of 14, at most 512 (render bridge limit)')
    OUT.mkdir(parents=True, exist_ok=True)
    key = f'{width}x{height}'
    frozen, leftovers = freeze(width, height)
    if split_patch_embedding(frozen, width, height) != 1:
        raise SystemExit('Patch embedding convolution not found')
    blocks = split_attention_heads(frozen)
    if blocks != 12:
        raise SystemExit(f'Expected 12 attention blocks to split, found {blocks}')
    frozen_path = OUT / f'depth_{key}.onnx'
    onnx.save(frozen, str(frozen_path))
    frozen_error = check_frozen(frozen_path, width, height)
    if frozen_error > 1e-4:
        raise SystemExit(f'Frozen depth graph differs from the source: {frozen_error}')
    mnn_path = OUT / f'depth_{key}.mnn'
    log = subprocess.run([str(MNNCONVERT), '-f', 'ONNX', '--modelFile', str(frozen_path), '--MNNModel', str(mnn_path),
                          '--bizCode', 'depth', '--fp16'], capture_output=True, text=True)
    if log.returncode != 0 or not mnn_path.is_file():
        raise SystemExit('mnnconvert failed:\n' + log.stdout + log.stderr)
    mnn_error = check_mnn(mnn_path, frozen_path, width, height)
    if mnn_error > 0.02:  # FP16 weights; relative to the largest output value
        raise SystemExit(f'MNN depth model differs from the frozen graph: {mnn_error}')
    manifest = dict(schema_version=1, backend='MNN 3.6.1 OpenCL', model='Depth Anything V2 Small',
                    license='Apache-2.0', source_onnx=str(SOURCE.relative_to(ROOT)), source_sha256=sha(SOURCE),
                    input='src float32 1x3xHxW RGB 0..1 (ImageNet normalization folded)',
                    output='depth float32 1x1xHxW relative inverse depth (larger = nearer)',
                    width=width, height=height, frozen_onnx_sha256=sha(frozen_path), mnn_sha256=sha(mnn_path),
                    mnn_file='depth.mnn', dynamic_ops_left=leftovers,
                    frozen_vs_source_rel_max=frozen_error, mnn_fp16_weights_vs_frozen_rel_max=mnn_error)
    (OUT / f'manifest_{key}.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(manifest, indent=2))
    if args.install:
        ASSETS.mkdir(parents=True, exist_ok=True)
        (ASSETS / 'depth.mnn').write_bytes(mnn_path.read_bytes())
        (ASSETS / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        (ASSETS / 'LICENSE-DepthAnythingV2-Small.txt').write_bytes(
            (ROOT / 'models/licenses/DepthAnythingV2_Apache-2.0.txt').read_bytes())
        print(f'Installed depth model {manifest["mnn_sha256"][:12]} -> {ASSETS}')


if __name__ == '__main__':
    main()
