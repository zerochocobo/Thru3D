"""Ensure a passing device report cannot certify stale, missing or relabelled frames."""
import os
from pathlib import Path
import argparse
import copy
import json
from pathlib import Path

from mpv_source_probe import verify


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('--ffmpeg', default=os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    args = parser.parse_args()
    original = json.loads(args.report.read_text(encoding='utf-8-sig'))
    verify(original, args.ffmpeg)
    cases = {}
    shifted = copy.deepcopy(original)
    shifted['source_records'][0]['pts_us'] += 33333
    cases['pixels_from_a_different_pts'] = shifted
    missing = copy.deepcopy(original)
    missing['source_records'] = [r for r in missing['source_records'] if r['pts_us'] != 5966667]
    cases['missing_last_source_frame'] = missing
    relabelled = copy.deepcopy(original)
    repeated = next(r for r in relabelled['source_records'] if r['forced'])
    repeated['source_epoch'] += 1
    cases['old_redraw_relabelled_after_seek'] = relabelled
    invalid = copy.deepcopy(original)
    invalid['source_records'][0]['flags'] &= ~16
    cases['render_failure_marked_as_a_source'] = invalid
    result = []
    for name, report in cases.items():
        try:
            verify(report, args.ffmpeg)
        except ValueError as error:
            result.append({'case': name, 'state': 'rejected', 'reason': str(error)})
        else:
            raise AssertionError(f'Invalid source evidence accepted: {name}')
    destination = args.report.with_name(args.report.stem+'_rejections.json')
    destination.write_text(json.dumps({'state': 'passed', 'cases': result}, indent=2)+'\n', encoding='utf-8')
    print(f'Four invalid source reports rejected; evidence={destination}')


if __name__ == '__main__':
    main()
