"""Execute the production C++ JSON writer; independent Python JSON/Unicode oracle."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = [(text.encode('utf-8'), text) for text in ['', 'ASCII', '中文字幕 😀\nSecond line',
             '"quotes" \\ slash\t\r\n', ''.join(chr(i) for i in range(128)),
             '\u0080\u07ff\u0800\uffff\U00010000\U0010ffff']]
    # Invalid bytes consume one byte per U+FFFD, an explicit resynchronization policy.
    cases += [(b'\xff', '\ufffd'), (b'\xc0\xaf', '\ufffd\ufffd'),
              (b'\xed\xa0\x80', '\ufffd'*3), (b'\xf4\x90\x80\x80', '\ufffd'*4),
              (b'\xe2\x82', '\ufffd'*2), (b'\xe2X\xa1', '\ufffdX\ufffd'),
              (b'\x80valid\x00end', '\ufffdvalid\x00end')]
    rng = random.Random(20261004)
    for _ in range(512):
        points = [rng.randrange(0x110000) for _ in range(rng.randrange(1, 128))]
        text = ''.join(chr(cp) for cp in points if not 0xd800 <= cp <= 0xdfff)
        cases.append((text.encode('utf-8'), text))
    fixture = args.output/'utf8-input.hex'
    fixture.write_text(''.join(data.hex()+'\n' for data, _ in cases), encoding='ascii')
    run = subprocess.run([str(args.executable.resolve()), str(fixture.resolve())], check=True, capture_output=True)
    (args.output/'native-output.jsonl').write_bytes(run.stdout)
    results = run.stdout.decode('ascii').splitlines()
    assert len(results) == len(cases), 'Native output count differs'
    for index, ((_, expected), actual) in enumerate(zip(cases, results)):
        assert json.loads(actual) == expected, f'Independent Unicode/JSON oracle failed at {index}'
        assert all(32 <= ord(ch) < 128 for ch in actual), 'JNI string must contain ASCII without raw controls/NUL'
    sources = ['native/mpv/json_quote.h', 'benchmarks/native_mpv_json/json_oracle.cpp',
               'benchmarks/native_mpv_json/verify.py', 'benchmarks/native_mpv_json/CMakeLists.txt']
    report = dict(schema_version=1, state='passed', cases=len(cases),
                  scope='Production C++ ASCII JSON round trip through independent Python parser; JNI/device glyph rendering not exercised',
                  executable_sha256=hashlib.sha256(args.executable.read_bytes()).hexdigest(),
                  sources={p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
                  fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                  output_sha256=hashlib.sha256(run.stdout).hexdigest())
    (args.output/'verification.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(f'Native MPV JSON oracle passed: {len(cases)} cases')

if __name__ == '__main__':
    main()
