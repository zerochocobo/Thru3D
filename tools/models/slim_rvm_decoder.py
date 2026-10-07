"""Narrow RVM's high-resolution decoder stages (bandwidth) on the fused u8 graph.

The decoder carries ~60% of RVM's memory traffic at 320x320, most of it in decode1
(1/2 scale) and the full-resolution output block. Variants keep the first channels of
each sliced layer (a teacher-initialised student; distill_rvm_decoder.py trains it):

  d1   decode1 32 -> 16 channels (GRU state r1 16 -> 8), output block 16 -> 8
  d1w  decode1 as d1, output block kept at 16 channels
  d12  d1 + decode2 40 -> 20 (r2 20 -> 10), output block 16 -> 4
  d12s d12 cut from a trained d1 student (--source), keeping the channels its next
       layer weighs most instead of the first ones: the first-channel d12 starts
       nearly broken and distillation stalls

State inputs get static channel counts, which MnnRvmBackend reads from the model.
Quest 3, 320x320 stereo FP16 (untrained weights, timing only): 33.6 -> 27.7 (d1) /
25.9 (d12) ms; in the player d1 measured 22.2 -> 26.7 Alpha pairs/s.
"""
import argparse
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'build/rvm/mnn/rvm.fused.u8.onnx'
STATES = {'d1': (8, 20, 40, 64), 'd1w': (8, 20, 40, 64), 'd12': (8, 10, 40, 64), 'd12s': (8, 10, 40, 64),
          'd2n32': (8, 16, 40, 64)}


def r(a, b):
    return list(range(a, b))


def slim(model, variant):
    g = model.graph
    inits = {i.name: i for i in g.initializer}
    node = {n.name: n for n in g.node}

    def arr(name):
        return numpy_helper.to_array(inits[name])

    def put(name, value):
        g.initializer.remove(inits[name])
        inits[name] = numpy_helper.from_array(np.ascontiguousarray(value.astype(np.float32)), name)
        g.initializer.append(inits[name])

    def conv(name, out_idx, in_idx=None):
        n = node[name]
        w = arr(n.input[1])
        put(n.input[1], w[out_idx][:, r(0, w.shape[1]) if in_idx is None else in_idx])
        if len(n.input) > 2:
            put(n.input[2], arr(n.input[2])[out_idx])

    def weight(name):
        return arr(node[name].input[1])

    def top(score, count):
        return sorted(np.argsort(-score)[:count].tolist())

    if variant in ('d12s', 'd2n32'):
        # Trained d1: decode1 is 8 wide, output block 8. decode2 splits into a2 | b2 (20 each);
        # the GRU keeps b2/r2 channel k together. decode1 reads up(a2 | r2o) | f1 | src/2.
        # d2n32 narrows decode2 only (40 -> 32, halves 16: C4-aligned) and keeps the output block,
        # the single-variable test the d12s result could not separate.
        keep2 = 16 if variant == 'd2n32' else 10
        w = np.abs(weight('Conv_260_part0')).sum((0, 2, 3)) + np.abs(weight('Conv_260_part1')).sum((0, 2, 3))
        a2, gru = top(w[:20], keep2), top(w[20:40], keep2)
        conv('Conv_230_part0', a2); conv('Conv_230_part1', gru)
        gru2 = gru + [20 + k for k in gru]
        for name in ('Conv_236_part0', 'Conv_236_part1', 'Conv_241'):
            conv(name, gru, gru2)
        d1_in = a2 + [20 + k for k in gru] + r(40, 59)
        conv('Conv_260_part0', r(0, 8), d1_in); conv('Conv_260_part1', r(0, 8), d1_in)
        if variant == 'd2n32':
            return finish(g, variant)
        keep = top(np.abs(weight('Conv_294')).sum((0, 2, 3)), 4)
        mid = top(np.abs(weight('Conv_292')[keep]).sum((0, 2, 3)), 4)
        conv('Conv_290', mid); conv('Conv_292', keep, mid); conv('Conv_294', [0], keep)
        return finish(g, variant)
    d1_in = None
    if variant == 'd12':
        conv('Conv_230_part0', r(0, 10)); conv('Conv_230_part1', r(0, 10))
        gru2 = r(0, 10) + r(20, 30)
        for name in ('Conv_236_part0', 'Conv_236_part1', 'Conv_241'):
            conv(name, r(0, 10), gru2)
        d1_in = r(0, 10) + r(20, 30) + r(40, 59)  # up(concat(a2, r2o)) + f1 (16) + src/2 (3)
    conv('Conv_260_part0', r(0, 8), d1_in); conv('Conv_260_part1', r(0, 8), d1_in)
    gru1 = r(0, 8) + r(16, 24)
    for name in ('Conv_266_part0', 'Conv_266_part1', 'Conv_271'):
        conv(name, r(0, 8), gru1)
    out = {'d1': 8, 'd1w': 16, 'd12': 4}[variant]
    conv('Conv_290', r(0, out), r(0, 8) + r(16, 24) + [32, 33, 34])
    if out < 16:
        conv('Conv_292', r(0, out), r(0, out))
        conv('Conv_294', [0], r(0, out))
    return finish(g, variant)


def finish(g, variant):
    outputs = {v.name: v for v in g.output}
    for value, channels in zip(g.input[1:], STATES[variant]):
        value.type.tensor_type.shape.dim[1].dim_value = channels
        outputs[value.name[:-1] + 'o'].type.tensor_type.shape.dim[1].dim_value = channels
    del g.value_info[:]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--variant', choices=sorted(STATES), default='d1')
    p.add_argument('--source', type=Path, default=SOURCE)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    a.output.parent.mkdir(parents=True, exist_ok=True)
    model = onnx.load(a.source)
    slim(model, a.variant)
    onnx.checker.check_model(model)
    onnx.save(model, a.output)
    print('wrote', a.output)


if __name__ == '__main__':
    main()
