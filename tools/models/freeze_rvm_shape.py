"""Freeze the ratio=1 RVM source at an arbitrary input shape for backend timing.

Experimental helper for the performance study: fixes src/state shapes, drops the
unused foreground output (production consumes only pha + four states), applies
ORT basic optimization and checks the frozen graph against the dynamic source
over a short recurrent sequence. Optional --decoder-half evaluates the final
OutputBlock at half resolution (see apply_decoder_half).
"""
import argparse
from pathlib import Path

import numpy as np
import onnx
from onnx import helper
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'build/rvm-ratio-one/source/rvm.ratio-one.onnx'


def set_shape(value, dims):
    value.type.tensor_type.shape.ClearField('dim')
    for d in dims:
        value.type.tensor_type.shape.dim.add().dim_value = d


def prune(model):
    producer = {o: n for n in model.graph.node for o in n.output}
    need = {v.name for v in model.graph.output}
    stack = list(need)
    while stack:
        n = producer.get(stack.pop())
        if n:
            for i in n.input:
                if i and i not in need:
                    need.add(i)
                    stack.append(i)
    keep = [n for n in model.graph.node if any(o in need for o in n.output)]
    del model.graph.node[:]
    model.graph.node.extend(keep)
    inits = [i for i in model.graph.initializer if i.name in need]
    del model.graph.initializer[:]
    model.graph.initializer.extend(inits)


def apply_decoder_half(model):
    """Run OutputBlock + projection on the 1/2-scale decoder features.

    Upstream OutputBlock: x = upsample2x(concat(a, r1o)); conv(concat(x, s0)).
    Here: conv(concat(concat(a, r1o), s1)) at 1/2 scale, where s1 is the decoder's
    own 2x2 avg-pooled source (input of the 1/2 stage). Weights are untouched;
    pha is produced at half resolution and must be upsampled downstream.
    """
    nodes = {n.name: n for n in model.graph.node}
    cat_out, cat_half = nodes['Concat_289'], nodes['Concat_259']
    resize = nodes['Resize_280']
    half_feat = resize.input[0]           # concat(a, r1o) at 1/2 scale
    s1 = cat_half.input[2]                # 3-channel avg-pooled source at 1/2 scale
    cat_out.input[0] = half_feat
    cat_out.input[1] = s1
    pha = next(v for v in model.graph.output if v.name == 'pha')
    return pha


def freeze(width, height, decoder_half=False, batch=1):
    model = onnx.load(SOURCE)
    shapes = {'src': (batch, 3, height, width)}
    for i, (c, s) in enumerate([(16, 2), (20, 4), (40, 8), (64, 16)], 1):
        shapes[f'r{i}i'] = (batch, c, height // s, width // s)
    for v in model.graph.input:
        set_shape(v, shapes[v.name])
    keep = [v for v in model.graph.output if v.name != 'fgr']
    del model.graph.output[:]
    model.graph.output.extend(keep)
    if decoder_half:
        apply_decoder_half(model)
    for v in model.graph.output:
        v.type.tensor_type.shape.ClearField('dim')
    prune(model)
    model = onnx.shape_inference.infer_shapes(model)
    return model, shapes


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--width', type=int, required=True)
    p.add_argument('--height', type=int, required=True)
    p.add_argument('--decoder-half', action='store_true')
    p.add_argument('--batch', type=int, default=1)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.width % 32 or a.height % 32:
        raise SystemExit('width/height must be multiples of 32')
    a.output.mkdir(parents=True, exist_ok=True)
    model, shapes = freeze(a.width, a.height, a.decoder_half, a.batch)
    fixed = a.output / 'rvm.fixed.onnx'
    onnx.save(model, fixed)
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    opts.optimized_model_filepath = str(a.output / 'rvm.optimized.onnx')
    sess = ort.InferenceSession(str(fixed), opts, providers=['CPUExecutionProvider'])
    feeds = {k: np.zeros(v, np.float32) for k, v in shapes.items()}
    feeds['src'] = np.random.default_rng(1).random(shapes['src'], dtype=np.float32)
    outs = sess.run(None, feeds)
    print(a.output, {o.name: list(r.shape) for o, r in zip(sess.get_outputs(), outs)})


if __name__ == '__main__':
    main()
