"""Build the single dynamic-shape MNN model used by the Quest OpenCL backend.

Source: the ratio=1 upstream-branch ONNX (refiner skipped, as in PyTorch at
ratio 1). The unused foreground output is pruned; production consumes pha and
the four recurrent states. Shapes stay dynamic so every allowlisted profile
resizes one session. The pruned graph is checked against the unpruned source
over a recurrent ORT sequence at each profile before conversion.

Zero-copy: MNN imports RGBA8 AHardwareBuffers as raw 0..255 values and exports
by truncating to uchar. The converted graph therefore takes src in 0..255
(first op multiplies by 1/255) and adds pha_u8 = pha * 255 + 0.5, so
truncation rounds exactly like the CPU path's lround(alpha * 255).

Bandwidth: tools/models/fuse_rvm_graph.py then removes elementwise and copy passes
(HardSwish, Scale input, split convolutions, no Expand/Split) and the converter keeps
NC4HW4 inputs (--keepInputFormat=0), which drops the layout conversions that MNN
otherwise inserts around every Concat/Interp. Quest 3, 320x320 FP16: 37.8 -> 29.3 ms
per stereo pair, closer to ORT FP32 than the unfused graph.
"""
import os
from pathlib import Path
import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort

import fuse_rvm_graph

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'build/rvm-ratio-one/source/rvm.ratio-one.onnx'
OUT = ROOT / 'build/rvm/mnn'
ASSETS = ROOT / 'android/player-plugin/src/main/assets/rvm-mnn'
MNNCONVERT = Path(os.environ.get('MNNCONVERT', 'mnnconvert'))
STUDENT_MANIFEST = ROOT / 'models/manifest/rvm_student.json'
PROFILES = json.loads((ROOT / 'models/manifest/rvm_profiles.json').read_text(encoding='utf-8'))['profiles']


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prune_fgr(model):
    keep = [v for v in model.graph.output if v.name != 'fgr']
    del model.graph.output[:]
    model.graph.output.extend(keep)
    producer = {o: n for n in model.graph.node for o in n.output}
    need = {v.name for v in model.graph.output}
    stack = list(need)
    while stack:
        node = producer.get(stack.pop())
        if node:
            for name in node.input:
                if name and name not in need:
                    need.add(name)
                    stack.append(name)
    nodes = [n for n in model.graph.node if any(o in need for o in n.output)]
    del model.graph.node[:]
    model.graph.node.extend(nodes)
    inits = [i for i in model.graph.initializer if i.name in need]
    del model.graph.initializer[:]
    model.graph.initializer.extend(inits)
    return model


def add_u8_io(model):
    """src in 0..255 -> x/255 into the network; extra output pha_u8 = pha*255 + 0.5."""
    from onnx import helper, numpy_helper, TensorProto
    graph = model.graph
    for node in graph.node:
        for i, name in enumerate(node.input):
            if name == 'src':
                node.input[i] = 'src_unit'
    graph.initializer.extend([numpy_helper.from_array(np.array(1 / 255, np.float32), 'u8_to_unit'),
                              numpy_helper.from_array(np.array(255, np.float32), 'unit_to_u8'),
                              numpy_helper.from_array(np.array(0.5, np.float32), 'u8_round')])
    graph.node.insert(0, helper.make_node('Mul', ['src', 'u8_to_unit'], ['src_unit'], name='SrcU8ToUnit'))
    graph.node.extend([helper.make_node('Mul', ['pha', 'unit_to_u8'], ['pha_scaled'], name='PhaToU8'),
                       helper.make_node('Add', ['pha_scaled', 'u8_round'], ['pha_u8'], name='PhaU8Round')])
    graph.output.append(helper.make_tensor_value_info('pha_u8', TensorProto.FLOAT, ['batch', 1, 'height', 'width']))
    return model


def verify_u8(unit_path, u8_path, width, height):
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    a = ort.InferenceSession(str(unit_path), opts, providers=['CPUExecutionProvider'])
    b = ort.InferenceSession(str(u8_path), opts, providers=['CPUExecutionProvider'])
    rng = np.random.default_rng(7)
    states = {f'r{i + 1}i': np.zeros((1, c) + state_hw(width, height, i + 1)[::-1], np.float32)
              for i, c in enumerate((16, 20, 40, 64))}
    u8 = rng.integers(0, 256, (1, 3, height, width)).astype(np.float32)
    ra = dict(zip([o.name for o in a.get_outputs()], a.run(None, {'src': u8 / 255, **states})))
    rb = dict(zip([o.name for o in b.get_outputs()], b.run(None, {'src': u8, **states})))
    worst = max(float(np.max(np.abs(ra[k] - rb[k]))) for k in ('pha', 'r1o', 'r2o', 'r3o', 'r4o'))
    rounding = float(np.max(np.abs(np.floor(rb['pha_u8']) - np.round(ra['pha'] * 255))))
    return worst, rounding


def state_hw(width, height, level):
    """Each stride-2 stage rounds up, so states use repeated ceil(x / 2)."""
    for _ in range(level):
        width, height = (width + 1) // 2, (height + 1) // 2
    return width, height


def verify(pruned_path, width, height, frames=3):
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    full = ort.InferenceSession(str(SOURCE), opts, providers=['CPUExecutionProvider'])
    pruned = ort.InferenceSession(str(pruned_path), opts, providers=['CPUExecutionProvider'])
    rng = np.random.default_rng(width * 1000 + height)
    state_a = {f'r{i + 1}i': np.zeros((1, c) + state_hw(width, height, i + 1)[::-1], np.float32)
               for i, c in enumerate((16, 20, 40, 64))}
    state_b = dict(state_a)
    worst = 0.0
    for _ in range(frames):
        src = rng.random((1, 3, height, width), dtype=np.float32)
        a = dict(zip([o.name for o in full.get_outputs()], full.run(None, {'src': src, **state_a})))
        b = dict(zip([o.name for o in pruned.get_outputs()], pruned.run(None, {'src': src, **state_b})))
        for k in ('pha', 'r1o', 'r2o', 'r3o', 'r4o'):
            worst = max(worst, float(np.max(np.abs(a[k] - b[k]))))
        state_a = {f'r{i}i': a[f'r{i}o'] for i in range(1, 5)}
        state_b = {f'r{i}i': b[f'r{i}o'] for i in range(1, 5)}
    return worst


def convert(onnx_path, target):
    log = subprocess.run([str(MNNCONVERT), '-f', 'ONNX', '--modelFile', str(onnx_path), '--MNNModel', str(target),
                          '--bizCode', 'rvm', '--keepInputFormat=0'], capture_output=True, text=True)
    if log.returncode != 0 or not target.is_file():
        raise SystemExit('mnnconvert failed:' + chr(10) + log.stdout + log.stderr)


def install():
    """Copy the verified model into the plugin assets (separate from the ncnn bundle)."""
    manifest = json.loads((OUT / 'manifest.json').read_text(encoding='utf-8'))
    if sha(OUT / 'rvm.mnn') != manifest['mnn_sha256'] or sha(SOURCE) != manifest['source_sha256'] or             sha(OUT / 'rvm_quality.mnn') != manifest.get('quality_mnn_sha256'):
        raise SystemExit('MNN model or source changed since conversion; rerun with --regenerate')
    ASSETS.mkdir(parents=True, exist_ok=True)
    for name in ('rvm.mnn', 'rvm_quality.mnn', 'manifest.json'):
        (ASSETS / name).write_bytes((OUT / name).read_bytes())
    (ASSETS / 'RVM_GPL-3.0.txt').write_bytes((ROOT / 'models/licenses/RVM_GPL-3.0.txt').read_bytes())
    print(f'Installed MNN RVM model {manifest["mnn_sha256"][:12]} -> {ASSETS}')


def main():
    import sys
    current = OUT / 'manifest.json'
    if '--regenerate' not in sys.argv and current.is_file() and (OUT / 'rvm.mnn').is_file():
        install()
        return
    OUT.mkdir(parents=True, exist_ok=True)
    model = prune_fgr(onnx.load(SOURCE))
    onnx.checker.check_model(model)
    pruned = OUT / 'rvm.ratio-one.pha.onnx'
    onnx.save(model, pruned)
    checks = {p['key']: verify(pruned, p['width'], p['height']) for p in PROFILES}
    for key, value in checks.items():
        if value != 0.0:
            raise SystemExit(f'Pruned graph differs from source at {key}: {value}')
    u8 = OUT / 'rvm.ratio-one.u8.onnx'
    u8_model = add_u8_io(onnx.load(pruned))
    onnx.checker.check_model(u8_model)
    onnx.save(u8_model, u8)
    u8_checks = {p['key']: verify_u8(pruned, u8, p['width'], p['height']) for p in PROFILES}
    for key, (worst, rounding) in u8_checks.items():
        if worst > 1e-5 or rounding > 0:
            raise SystemExit(f'0..255 input graph differs at {key}: {worst} / rounding {rounding}')
    fused = OUT / 'rvm.fused.u8.onnx'
    fused_model, fusion = fuse_rvm_graph.build(split=True, fold='scale', source=u8, rgba=True)
    onnx.save(fused_model, fused)
    fused_checks = {p['key']: fuse_rvm_graph.compare(u8, fused, p['width'], p['height']) for p in PROFILES}
    for key, worst in fused_checks.items():
        if max(worst.values()) > 1e-4:
            raise SystemExit(f'Fused graph differs at {key}: {worst}')
    # Shipped graphs additionally move HardSwish into the convolutions; only the player's MNN fork
    # (tools/mnn/patch_mnn_vrpp.py) computes it, so the ORT checks above use unmarked graphs.
    #   rvm_quality.mnn  the fused upstream network (Alpha quality option)
    #   rvm.mnn          the distilled narrow-decoder student (default; models/manifest/rvm_student.json),
    #                    scored by benchmarks/rvm_layer_profile/rvm_bandwidth_sim.py, not by equality
    marked = OUT / 'rvm.fused.hswish.u8.onnx'
    marked_model, marked_fusion = fuse_rvm_graph.build(split=True, fold='scale', source=u8, conv_hardswish=True, rgba=True)
    fusion['conv_hardswish'] = marked_fusion['conv_hardswish']
    onnx.save(marked_model, marked)
    convert(marked, OUT / 'rvm_quality.mnn')
    student_manifest = json.loads(STUDENT_MANIFEST.read_text(encoding='utf-8'))
    student = ROOT / student_manifest['file']
    if sha(student) != student_manifest['sha256']:
        raise SystemExit('Distilled RVM student hash differs from models/manifest/rvm_student.json')
    graph = fuse_rvm_graph.Graph(onnx.load(student))
    fuse_rvm_graph.rgba_input(graph)
    student_hswish = fuse_rvm_graph.mark_conv_hardswish(graph)
    fuse_rvm_graph.prune_unused(graph)
    student_marked = OUT / 'rvm.student.hswish.u8.onnx'
    onnx.save(graph.model, student_marked)
    convert(student_marked, OUT / 'rvm.mnn')
    target = OUT / 'rvm.mnn'
    manifest = dict(schema_version=4, backend='MNN 3.6.1 OpenCL', source_onnx=str(SOURCE.relative_to(ROOT)),
                    source_sha256=sha(SOURCE), pruned_onnx_sha256=sha(pruned), u8_onnx_sha256=sha(u8),
                    fused_onnx_sha256=sha(fused), marked_onnx_sha256=sha(marked), mnn_sha256=sha(target),
                    quality_mnn_sha256=sha(OUT / 'rvm_quality.mnn'),
                    student=dict(manifest='models/manifest/rvm_student.json', sha256=student_manifest['sha256'],
                                 conv_hardswish=student_hswish, marked_onnx_sha256=sha(student_marked)),
                    mnn_runtime='MNN 3.6.1 + tools/mnn/patch_mnn_vrpp.py (convolutions named *__hswish apply HardSwish)', fusion=fusion, fused_vs_u8_max_abs=fused_checks,
                    converter_flags=['--keepInputFormat=0'],
                    input_src_range='0..255 (graph multiplies by 1/255)', input_channels='RGBA (4th ignored)',
                    outputs=['pha', 'r1o', 'r2o', 'r3o', 'r4o', 'pha_u8'], dynamic_shape=True,
                    pruned_vs_source_max_abs=checks, u8_vs_unit_max_abs_and_rounding=u8_checks,
                    branch='ratio=1 upstream (refiner skipped), fgr pruned, u8 io for AHardwareBuffer zero-copy, '
                           'bandwidth-fused graph with NC4HW4 inputs and HardSwish in the convolutions')
    (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(manifest, indent=2))
    install()


if __name__ == '__main__':
    main()
