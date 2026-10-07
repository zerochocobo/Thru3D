"""Specialize the pinned ONNX to the upstream PyTorch ratio=1 branch.

The released ONNX unconditionally computes its guided refiner. Upstream
MattingNetwork.forward skips it at ratio=1. This separate experimental model
retains the backbone, decoder, projection and all four recurrent outputs.
It never changes bundled assets or the production profile allowlist.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnx
from onnx import helper, numpy_helper

ROOT = Path(__file__).resolve().parents[2]
SOURCE_SHA = '88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828'

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def specialize(output):
    original_manifest = json.loads((ROOT / 'models/manifest/rvm_mobilenetv3.json').read_text(encoding='utf-8'))
    source = ROOT / original_manifest['file']
    if sha(source) != SOURCE_SHA or original_manifest['sha256'] != SOURCE_SHA:
        raise ValueError('Unrecognized RVM release; branch identities must be re-audited')
    model = onnx.load(source)
    nodes = {node.name: node for node in model.graph.node}
    projection = nodes['Split_295']
    if (projection.op_type != 'Split' or list(projection.input) != ['752'] or
            list(projection.output) != ['753', '754'] or
            helper.get_attribute_value(next(a for a in projection.attribute if a.name == 'split')) != [3, 1]):
        raise ValueError('Base matting projection differs from the pinned graph')
    if list(nodes['Add_350'].input) != ['810', 'src'] or list(nodes['Clip_352'].input) != ['811', '991', '992']:
        raise ValueError('Released refined outputs differ from the pinned graph')
    nodes['Add_350'].input[0] = '753'
    nodes['Clip_352'].input[0] = '754'
    # Fix ratio in the source itself so an external caller cannot accidentally
    # feed ratio<1 to a graph with the ratio=1 refinement branch.
    kept_inputs = [value for value in model.graph.input if value.name != 'downsample_ratio']
    del model.graph.input[:]
    model.graph.input.extend(kept_inputs)
    model.graph.initializer.append(numpy_helper.from_array(np.array([1], np.float32), 'downsample_ratio'))
    producer = {name: node for node in model.graph.node for name in node.output}
    required = {value.name for value in model.graph.output}
    queue = list(required)
    while queue:
        node = producer.get(queue.pop())
        if node:
            for name in node.input:
                if name and name not in required:
                    required.add(name)
                    queue.append(name)
    kept_nodes = [node for node in model.graph.node if any(name in required for name in node.output)]
    old_count = len(model.graph.node)
    del model.graph.node[:]
    model.graph.node.extend(kept_nodes)
    kept_weights = [value for value in model.graph.initializer if value.name in required]
    del model.graph.initializer[:]
    model.graph.initializer.extend(kept_weights)
    kept_info = [value for value in model.graph.value_info if value.name in required]
    del model.graph.value_info[:]
    model.graph.value_info.extend(kept_info)
    assert [value.name for value in model.graph.output] == ['fgr', 'pha', 'r1o', 'r2o', 'r3o', 'r4o']
    assert all(name not in required for name in ['755', '757', '793', '807', '811'])
    original_weights = {value.name: value.SerializeToString() for value in onnx.load(source).graph.initializer}
    for value in model.graph.initializer:
        if value.name != 'downsample_ratio':
            assert original_weights[value.name] == value.SerializeToString()
    onnx.checker.check_model(model)
    output.mkdir(parents=True, exist_ok=True)
    target = output / 'rvm.ratio-one.onnx'
    onnx.save(model, target)
    manifest = dict(schema_version=1, model_id='rvm_ratio_one_upstream_branch_experiment',
        source=original_manifest['source'], license=original_manifest['license'],
        license_source=original_manifest['license_source'],
        upstream_branch_source='https://github.com/PeterL1n/RobustVideoMatting/blob/v1.0.0/model/model.py',
        original_source_sha256=SOURCE_SHA, file=target.relative_to(ROOT).as_posix(), sha256=sha(target),
        fixed_downsample_ratio=1.0, original_nodes=old_count, specialized_nodes=len(kept_nodes),
        retained_weights_unchanged=True, four_recurrent_outputs_retained=True,
        quality_verified=False, device_verified=False, production_enabled=False,
        scope='Explicit upstream ratio=1 branch; different Alpha/fgr oracle from released unconditional-refiner ONNX')
    (output / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rvm-ratio-one/source')
    args = parser.parse_args()
    print(json.dumps(specialize(args.output.resolve()), indent=2))
