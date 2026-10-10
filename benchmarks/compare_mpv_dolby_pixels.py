"""Compare actual Source screenshots to independent pixels, never just metadata.

Exact mode checks ordinary SDR/HDR A/B regression. Oracle mode tolerates the
documented chroma interpolation and tone-map curve difference from libplacebo.
Both initial and post-seek frames must pass.
"""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('candidate', type=Path)
    parser.add_argument('reference', type=Path)
    parser.add_argument('--prefix', default='')
    parser.add_argument('--exact', action='store_true')
    parser.add_argument('--same-renderer', action='store_true')
    args = parser.parse_args()
    results = {}
    for label in ('initial', 'seek'):
        actual = np.asarray(Image.open(args.candidate / (label + '.png')).convert('RGB')).astype(np.float64)
        expected = np.asarray(Image.open(args.reference / (args.prefix + label + '.png')).convert('RGB')).astype(np.float64)
        assert actual.shape == expected.shape
        diff = np.abs(actual - expected)
        rmse = float(np.sqrt(np.mean(diff * diff)))
        metrics = {'mean_abs': float(diff.mean()), 'p99': float(np.percentile(diff, 99)),
                   'max_abs': float(diff.max()), 'rmse': rmse,
                   'psnr_db': None if rmse == 0 else float(20 * np.log10(255 / rmse))}
        if args.exact:
            passed = metrics['max_abs'] == 0
        elif args.same_renderer:
            passed = metrics['mean_abs'] <= 2 and metrics['p99'] <= 16
        else:
            # vo_gpu BT.2390 knee vs libplacebo BT.2390 differs slightly in
            # brightness. A channel/matrix error is far beyond these bounds.
            passed = metrics['mean_abs'] <= 6 and metrics['p99'] <= 20 and metrics['psnr_db'] >= 30
        results[label] = {'passed': passed, **metrics}
    record = {'passed': all(r['passed'] for r in results.values()), 'reference': str(args.reference),
              'exact': args.exact, 'same_renderer': args.same_renderer, 'frames': results}
    (args.candidate / ('pixels-exact.json' if args.exact else 'pixels-oracle.json')).write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=2))
    assert record['passed'], 'Pixel comparison failed'


if __name__ == '__main__':
    main()
