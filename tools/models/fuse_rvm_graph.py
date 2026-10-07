"""Bandwidth-oriented rewrites of the production u8 RVM graph (ratio=1, fgr pruned).

MNN OpenCL is memory-bound on Quest: every elementwise op and every Concat/Split/
Expand (lowered to Raster copies) reads and writes a whole feature map. These
rewrites keep the network function while removing such passes; all are valid for
any input shape (the graph stays dynamic):

  input   src(0..255) -> Mul 1/255 -> Resize(ratio 1) -> Sub mean -> Div std -> Conv
          becomes Mul 1/255 -> one per-channel Scale -> Conv (default), or with
          --fold weights Conv(src - 255 mean) with 1/255 and 1/std folded into conv
          weights (one pass less; zero padding unchanged either way).
  hswish  HardSigmoid(x) * x -> HardSwish(x) (opset 14): one pass instead of four.
  expand  Expand(r_i, Shape(feature)) -> r_i (states already have that shape).
  gru     (1 - z) * h + z * c -> h + z * (c - h): three passes instead of four.
  project Conv(16 -> 4) + Split -> Conv(16 -> 1) for Alpha only.
  split   (optional) Conv -> act -> Split -> two half convolutions, no Raster.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'build/rvm/mnn/rvm.ratio-one.u8.onnx'


class Graph:
    def __init__(self, model):
        self.model = model
        self.g = model.graph
        self.inits = {i.name: i for i in self.g.initializer}
        self.consts = {n.output[0]: numpy_helper.to_array(n.attribute[0].t) for n in self.g.node if n.op_type == 'Constant'}

    def node(self, name):
        return next(n for n in self.g.node if n.name == name)

    def producer(self, tensor):
        return next((n for n in self.g.node if tensor in n.output), None)

    def consumers(self, tensor):
        return [n for n in self.g.node if tensor in n.input]

    def array(self, name):
        if name in self.inits:
            return numpy_helper.to_array(self.inits[name])
        return self.consts[name]

    def set_init(self, name, value):
        tensor = numpy_helper.from_array(np.ascontiguousarray(value.astype(np.float32)), name)
        if name in self.inits:
            self.g.initializer.remove(self.inits[name])
        self.g.initializer.append(tensor)
        self.inits[name] = tensor

    def rename_input(self, old, new):
        for n in self.g.node:
            for i, name in enumerate(n.input):
                if name == old:
                    n.input[i] = new

    def remove(self, *nodes):
        for n in nodes:
            self.g.node.remove(n)


def fold_input(graph):
    mul = graph.node('SrcU8ToUnit')
    resize = graph.node('Resize_3')
    sub, div, conv = graph.node('Sub_5'), graph.node('Div_7'), graph.node('Conv_8')
    mean = graph.array(sub.input[1]).reshape(3)
    std = graph.array(div.input[1]).reshape(3)
    w = graph.array(conv.input[1]).copy()
    b = graph.array(conv.input[2]).copy()
    # conv((src/255 - m)/s) = conv'(src - 255 m) with w' = w / (255 s). Keeping the mean
    # subtraction keeps the zero padding identical (padded 0 still means normalized 0).
    w /= (255.0 * std)[None, :, None, None]
    graph.set_init(conv.input[1], w)
    graph.set_init('src_mean_u8', (255.0 * mean).reshape(1, 3, 1, 1))
    centred = helper.make_node('Sub', ['src', 'src_mean_u8'], ['src_centred'], name='SrcCentre')
    conv.input[0] = 'src_centred'
    # Raw skip inputs: the decoder convolutions take 1/255 on those channels.
    raw = resize.output[0]  # '389'
    index = list(graph.g.node).index(mul)
    graph.remove(mul, resize, sub, div)
    graph.g.node.insert(index, centred)
    graph.rename_input(raw, 'src')
    skip = {'src': 'Conv_290', '602': 'Conv_260', '603': 'Conv_230', '604': 'Conv_200'}
    for tensor, conv_name in skip.items():
        concat = next(n for n in graph.consumers(tensor) if n.op_type == 'Concat')
        target = graph.node(conv_name)
        assert target.input[0] == concat.output[0], (conv_name, concat.name)
        assert concat.input[-1] == tensor, concat.name  # raw image channels are the last three
        w = graph.array(target.input[1]).copy()
        w[:, -3:] /= 255.0
        graph.set_init(target.input[1], w)
    return 4


def fold_input_scale(graph):
    """FP16-friendly variant: keep src/255 for the skips and the original weights;
    Resize(ratio 1) goes and Sub/Div become one per-channel BatchNormalization (Scale)."""
    resize = graph.node('Resize_3')
    sub, div, conv = graph.node('Sub_5'), graph.node('Div_7'), graph.node('Conv_8')
    mean = graph.array(sub.input[1]).reshape(3)
    std = graph.array(div.input[1]).reshape(3)
    eps = 1e-5
    for name, value in (('src_bn_scale', np.ones(3)), ('src_bn_bias', np.zeros(3)), ('src_bn_mean', mean),
                        ('src_bn_var', std ** 2 - eps)):
        graph.set_init(name, value)
    bn = helper.make_node('BatchNormalization', ['src_unit', 'src_bn_scale', 'src_bn_bias', 'src_bn_mean', 'src_bn_var'],
                          ['src_normalized'], name='SrcNormalize', epsilon=eps)
    conv.input[0] = 'src_normalized'
    raw = resize.output[0]
    index = list(graph.g.node).index(resize)
    graph.remove(resize, sub, div)
    graph.g.node.insert(index, bn)
    graph.rename_input(raw, 'src_unit')
    return 3


def fuse_hardswish(graph):
    count = 0
    for hs in [n for n in graph.g.node if n.op_type == 'HardSigmoid']:
        alpha = next((a.f for a in hs.attribute if a.name == 'alpha'), 0.2)
        beta = next((a.f for a in hs.attribute if a.name == 'beta'), 0.5)
        if abs(alpha - 1 / 6) > 1e-6 or abs(beta - 0.5) > 1e-6:
            continue
        x = hs.input[0]
        users = graph.consumers(hs.output[0])
        if len(users) != 1 or users[0].op_type != 'Mul' or x not in users[0].input:
            continue
        mul = users[0]
        swish = helper.make_node('HardSwish', [x], [mul.output[0]], name=hs.name.replace('HardSigmoid', 'HardSwish'))
        index = list(graph.g.node).index(hs)
        graph.remove(hs, mul)
        graph.g.node.insert(index, swish)
        count += 1
    return count


def drop_expand(graph):
    count = 0
    for ex in [n for n in graph.g.node if n.op_type == 'Expand' and n.input[0] in ('r1i', 'r2i', 'r3i', 'r4i')]:
        shape = graph.producer(ex.input[1])
        graph.rename_input(ex.output[0], ex.input[0])
        graph.remove(ex)
        if shape is not None and shape.op_type == 'Shape' and not graph.consumers(shape.output[0]):
            graph.remove(shape)
        count += 1
    return count


def rewrite_gru(graph):
    count = 0
    for sub in [n for n in graph.g.node if n.op_type == 'Sub' and n.input[0] in graph.consts
                and np.all(graph.consts[n.input[0]] == 1)]:
        z = sub.input[1]
        (mul_h,) = graph.consumers(sub.output[0])
        h = next(i for i in mul_h.input if i != sub.output[0])
        (add,) = graph.consumers(mul_h.output[0])
        other = next(i for i in add.input if i != mul_h.output[0])
        mul_c = graph.producer(other)
        assert mul_c.op_type == 'Mul' and z in mul_c.input, sub.name
        c = next(i for i in mul_c.input if i != z)
        out = add.output[0]
        index = list(graph.g.node).index(add)
        diff, step = f'{sub.name}_c_minus_h', f'{sub.name}_z_step'
        nodes = [helper.make_node('Sub', [c, h], [diff], name=f'{sub.name}_gru_diff'),
                 helper.make_node('Mul', [z, diff], [step], name=f'{sub.name}_gru_step'),
                 helper.make_node('Add', [h, step], [out], name=f'{sub.name}_gru_out')]
        graph.remove(sub, mul_h, mul_c, add)
        index = min(index, len(graph.g.node))
        for k, n in enumerate(nodes):
            graph.g.node.insert(index - 3 + k, n)
        count += 1
    return count


def project_alpha(graph):
    conv, split = graph.node('Conv_294'), graph.node('Split_295')
    w, b = graph.array(conv.input[1]), graph.array(conv.input[2])
    graph.set_init(conv.input[1], w[3:4])
    graph.set_init(conv.input[2], b[3:4])
    alpha = split.output[1]
    conv.output[0] = alpha
    graph.remove(split)
    return 1


def split_convs(graph):
    """Conv -> (Relu|Sigmoid) -> Split(axis 1) => per-part Conv -> act; no Raster copy."""
    count = 0
    for split in [n for n in graph.g.node if n.op_type == 'Split']:
        act = graph.producer(split.input[0])
        if act is None or act.op_type not in ('Relu', 'Sigmoid') or len(graph.consumers(act.output[0])) != 1:
            continue
        conv = graph.producer(act.input[0])
        if conv is None or conv.op_type != 'Conv' or len(graph.consumers(conv.output[0])) != 1:
            continue
        sizes = next(onnx.helper.get_attribute_value(a) for a in split.attribute if a.name == 'split')
        w, b = graph.array(conv.input[1]), graph.array(conv.input[2])
        index = list(graph.g.node).index(conv)
        graph.remove(conv, act, split)
        start = 0
        new = []
        for part, (size, out) in enumerate(zip(sizes, split.output)):
            wn, bn, mid = f'{conv.name}_w{part}', f'{conv.name}_b{part}', f'{conv.name}_y{part}'
            graph.set_init(wn, w[start:start + size])
            graph.set_init(bn, b[start:start + size])
            start += size
            new.append(helper.make_node('Conv', [conv.input[0], wn, bn], [mid], name=f'{conv.name}_part{part}',
                                        **{a.name: helper.get_attribute_value(a) for a in conv.attribute}))
            new.append(helper.make_node(act.op_type, [mid], [out], name=f'{act.name}_part{part}'))
        for k, n in enumerate(new):
            graph.g.node.insert(index + k, n)
        count += 1
    return count


def split_concat_conv(graph, names):
    """Conv(Concat(a, b, ...)) -> Conv_a(a) + Conv_b(b) + ...: no Raster copy of the concat.
    The bias stays on the first part; only for concats whose sole consumer is the conv."""
    count = 0
    for conv_name in names:
        conv = graph.node(conv_name)
        concat = graph.producer(conv.input[0])
        if concat is None or concat.op_type != 'Concat' or len(graph.consumers(concat.output[0])) != 1:
            continue
        shapes = {v.name: v for v in onnx.shape_inference.infer_shapes(graph.model).graph.value_info}
        w, b = graph.array(conv.input[1]), graph.array(conv.input[2])
        channels = []
        for name in concat.input:
            dims = shapes[name].type.tensor_type.shape.dim if name in shapes else []
            channels.append(3 if name in ('src', 'src_unit') else (dims[1].dim_value if len(dims) > 1 else 0))
        if channels.count(0) == 1:  # e.g. the cropped upsample: the rest of the weight's inputs
            channels[channels.index(0)] = w.shape[1] - sum(channels)
        assert sum(channels) == w.shape[1] and all(channels), (conv_name, channels, w.shape)
        index = list(graph.g.node).index(conv)
        attrs = {a.name: helper.get_attribute_value(a) for a in conv.attribute}
        nodes, partial, start = [], [], 0
        for part, (name, size) in enumerate(zip(concat.input, channels)):
            wn, out = f'{conv.name}_in{part}_w', f'{conv.name}_in{part}_y'
            graph.set_init(wn, w[:, start:start + size])
            inputs = [name, wn]
            if part == 0:
                graph.set_init(f'{conv.name}_in0_b', b)
                inputs.append(f'{conv.name}_in0_b')
            nodes.append(helper.make_node('Conv', inputs, [out], name=f'{conv.name}_in{part}', **attrs))
            partial.append(out)
            start += size
        total = partial[0]
        for part, name in enumerate(partial[1:], 1):
            out = conv.output[0] if part == len(partial) - 1 else f'{conv.name}_sum{part}'
            nodes.append(helper.make_node('Add', [total, name], [out], name=f'{conv.name}_sum{part}'))
            total = out
        graph.remove(concat, conv)
        for k, n in enumerate(nodes):
            graph.g.node.insert(index - 1 + k, n)
        count += 1
    return count


def upsample_deconv(graph, conv_name='Conv_290'):
    """Conv3x3(Concat(crop(Upsample2x(a)), raw)) -> crop(ConvTranspose(a)) + Conv3x3(raw).

    Bilinear 2x upsampling (half-pixel) is a stride-2 transposed convolution with the kernel
    [.25 .75 .75 .25]; followed by a 3x3 convolution it composes into one stride-2 transposed
    convolution with a 6x6 kernel that reads the half-resolution features directly. The full-
    resolution upsampled map and the Concat copy disappear. Interior pixels are exact; the outer
    two rows/columns differ (the upsample clamps at the border, the composite zero-pads)."""
    conv = graph.node(conv_name)
    concat = graph.producer(conv.input[0])
    crop = graph.producer(concat.input[0])
    resize = graph.producer(crop.input[0])
    assert concat.op_type == 'Concat' and crop.op_type == 'Slice' and resize.op_type == 'Resize', conv_name
    assert np.allclose(graph.array(resize.input[2]), [1, 1, 2, 2])
    raw = concat.input[1]
    w, b = graph.array(conv.input[1]), graph.array(conv.input[2])
    ca = w.shape[1] - (3 if raw in ('src', 'src_unit') else 0)
    u = np.array([0.25, 0.75, 0.75, 0.25], np.float64)
    k = np.zeros((w.shape[0], ca, 6, 6))
    for ky in range(3):
        for kx in range(3):
            # K[t] = sum_k w[k] u[t - 2 + k]
            k[:, :, 2 - ky:6 - ky, 2 - kx:6 - kx] += w[:, :ca, ky, kx][:, :, None, None] * np.outer(u, u)[None, None]
    deconv_w = k.transpose(1, 0, 2, 3)  # ConvTranspose weight: (C_in, C_out, kH, kW)
    graph.set_init(f'{conv_name}_up_w', deconv_w)
    graph.set_init(f'{conv_name}_raw_w', w[:, ca:])
    graph.set_init(f'{conv_name}_raw_b', b)
    up = f'{conv_name}_up_y'
    nodes = [helper.make_node('ConvTranspose', [resize.input[0], f'{conv_name}_up_w'], [up], name=f'{conv_name}_up',
                              kernel_shape=[6, 6], strides=[2, 2], pads=[2, 2, 2, 2]),
             helper.make_node('Slice', [up] + list(crop.input[1:]), [f'{up}_crop'], name=f'{conv_name}_up_crop'),
             helper.make_node('Conv', [raw, f'{conv_name}_raw_w', f'{conv_name}_raw_b'], [f'{conv_name}_raw_y'],
                              name=f'{conv_name}_raw', kernel_shape=[3, 3], pads=[1, 1, 1, 1], strides=[1, 1]),
             helper.make_node('Add', [f'{up}_crop', f'{conv_name}_raw_y'], [conv.output[0]], name=f'{conv_name}_sum')]
    index = list(graph.g.node).index(conv)
    graph.remove(concat, conv)
    for i, n in enumerate(nodes):
        graph.g.node.insert(index - 1 + i, n)
    return 1


RAW_IMAGES = ('src_unit', '602', '603', '604')  # the source pyramid concatenated into the decoder


def rgba_input(graph):
    """Take src as RGBA (4 channels, the 4th ignored by zero weights).

    MNN keeps feature maps as 4-channel blocks; a 3-channel source pyramid concatenated after
    a multiple of 4 forces the Raster copy into a slow per-element path at every decoder stage
    (0.85 ms at 320x320 alone). With 4 channels every concat is block aligned. The zero-copy
    input buffer already is RGBA, so nothing else changes."""
    src = next(v for v in graph.g.input if v.name == 'src')
    src.type.tensor_type.shape.dim[1].dim_value = 4
    bn = graph.node('SrcNormalize')
    for name, extra in zip(bn.input[1:], (1.0, 0.0, 0.0, 1.0 - 1e-5)):
        graph.set_init(name, np.append(graph.array(name), extra))
    padded = 0
    conv = graph.node('Conv_8')
    w = graph.array(conv.input[1])
    graph.set_init(conv.input[1], np.concatenate([w, np.zeros_like(w[:, :1])], axis=1))
    padded += 1
    for concat in [n for n in graph.g.node if n.op_type == 'Concat' and n.input[-1] in RAW_IMAGES]:
        for user in graph.consumers(concat.output[0]):
            assert user.op_type == 'Conv', (concat.name, user.op_type)
            w = graph.array(user.input[1])
            graph.set_init(user.input[1], np.concatenate([w, np.zeros_like(w[:, :1])], axis=1))
            padded += 1
    del graph.g.value_info[:]
    return padded


HSWISH_MARKER = '__hswish'


def mark_conv_hardswish(graph):
    """MNN fork only (tools/mnn/patch_mnn_vrpp.py): drop HardSwish after a convolution and mark the
    convolution's output name; the forked OpenCL kernels apply it in the convolution epilogue.
    The marked graph is not a valid ONNX model of RVM without that fork."""
    count = 0
    for hs in [n for n in graph.g.node if n.op_type == 'HardSwish']:
        conv = graph.producer(hs.input[0])
        if conv is None or conv.op_type != 'Conv' or len(graph.consumers(conv.output[0])) != 1:
            continue
        marked = hs.output[0] + HSWISH_MARKER
        conv.output[0] = marked
        conv.name = conv.name + HSWISH_MARKER
        graph.rename_input(hs.output[0], marked)
        graph.remove(hs)
        count += 1
    return count


def prune_unused(graph):
    need = {o.name for o in graph.g.output}
    changed = True
    while changed:
        changed = False
        used = set(need)
        for n in graph.g.node:
            used.update(n.input)
        for n in list(graph.g.node):
            if not any(o in used for o in n.output):
                graph.g.node.remove(n)
                changed = True
    used = {i for n in graph.g.node for i in n.input}
    for init in list(graph.g.initializer):
        if init.name not in used:
            graph.g.initializer.remove(init)


def build(split=False, fold='scale', source=SOURCE, concat_convs=(), conv_hardswish=False, deconv=False, rgba=False):
    model = onnx.load(source)
    graph = Graph(model)
    report = dict(input=(fold_input_scale if fold == 'scale' else fold_input)(graph), hardswish=fuse_hardswish(graph), expand=drop_expand(graph),
                  gru=rewrite_gru(graph), project=project_alpha(graph))
    if split:
        report['split'] = split_convs(graph)
    if concat_convs:
        report['concat_conv'] = split_concat_conv(graph, concat_convs)
    if deconv:
        report['upsample_deconv'] = upsample_deconv(graph)
    if rgba:
        report['rgba_input'] = rgba_input(graph)
    if conv_hardswish:
        report['conv_hardswish'] = mark_conv_hardswish(graph)
    prune_unused(graph)
    for opset in model.opset_import:
        if opset.domain in ('', 'ai.onnx'):
            opset.version = max(opset.version, 14)
    # Opset 13 moved Split sizes from an attribute to an input.
    for n in graph.g.node:
        sizes = [a for a in n.attribute if n.op_type == 'Split' and a.name == 'split']
        if sizes:
            name = f'{n.name}_sizes'
            graph.g.initializer.append(numpy_helper.from_array(np.array(sizes[0].ints, np.int64), name))
            n.attribute.remove(sizes[0])
            n.input.append(name)
    model = onnx.shape_inference.infer_shapes(model)
    onnx.checker.check_model(model)
    return model, report


def compare(reference, fused, width, height, frames=6):
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    a = ort.InferenceSession(str(reference), opts, providers=['CPUExecutionProvider'])
    b = ort.InferenceSession(str(fused), opts, providers=['CPUExecutionProvider'])
    rng = np.random.default_rng(width + height)
    def dims(level):
        w, h = width, height
        for _ in range(level):
            w, h = (w + 1) // 2, (h + 1) // 2
        return h, w
    sa = {f'r{i + 1}i': np.zeros((1, c) + dims(i + 1), np.float32) for i, c in enumerate((16, 20, 40, 64))}
    sb = dict(sa)
    rgba_b = next(i for i in b.get_inputs() if i.name == 'src').shape[1] == 4
    worst = dict(pha=0.0, interior=0.0, states=0.0)
    base = rng.integers(0, 256, (1, 3, height, width)).astype(np.float32)
    for f in range(frames):
        src = np.clip(base + rng.normal(0, 8, base.shape), 0, 255).astype(np.float32)
        ra = dict(zip([o.name for o in a.get_outputs()], a.run(None, {'src': src, **sa})))
        src_b = np.concatenate([src, rng.integers(0, 256, src[:, :1].shape).astype(np.float32)], axis=1) if rgba_b else src
        rb = dict(zip([o.name for o in b.get_outputs()], b.run(None, {'src': src_b, **sb})))
        d = np.abs(ra['pha'] - rb['pha'])
        worst['pha'] = max(worst['pha'], float(d.max()))
        worst['interior'] = max(worst['interior'], float(d[..., 8:-8, 8:-8].max()))
        worst['states'] = max(worst['states'], max(float(np.abs(ra[f'r{i}o'] - rb[f'r{i}o']).max()) for i in range(1, 5)))
        sa = {f'r{i}i': ra[f'r{i}o'] for i in range(1, 5)}
        sb = {f'r{i}i': rb[f'r{i}o'] for i in range(1, 5)}
    return worst


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, default=ROOT / 'build/rvm-expert/fused')
    p.add_argument('--split', action='store_true')
    p.add_argument('--fold', choices=('scale', 'weights'), default='scale',
                   help='weights also folds 1/255 into conv weights (one pass less, FP16 weights get tiny)')
    p.add_argument('--rgba', action='store_true', help='4-channel src input: block-aligned source pyramid concats')
    p.add_argument('--deconv', action='store_true', help='Final upsample + 3x3 conv as one stride-2 transposed conv')
    p.add_argument('--conv-hardswish', action='store_true', help='MNN fork only: HardSwish in the conv kernels')
    p.add_argument('--concat-convs', nargs='*', default=[], help='e.g. Conv_290: sum of per-input convolutions')
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    model, report = build(a.split, a.fold, concat_convs=a.concat_convs, conv_hardswish=a.conv_hardswish, deconv=a.deconv,
                          rgba=a.rgba)
    path = a.output / 'rvm.fused.u8.onnx'
    onnx.save(model, path)
    ops = {}
    for n in model.graph.node:
        ops[n.op_type] = ops.get(n.op_type, 0) + 1
    report['ops'] = ops
    if not a.conv_hardswish:  # a marked graph only computes RVM on the forked MNN
        report['max_abs'] = {f'{w}x{h}': compare(SOURCE, path, w, h) for w, h in ((320, 320), (384, 216))}
    print(json.dumps(report, indent=2))
    (a.output / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
