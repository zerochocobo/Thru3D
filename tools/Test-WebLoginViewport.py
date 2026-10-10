"""Run local-only Android WebView fixtures on an explicitly selected emulator/device.

Build with -PincludeWebLoginFixture=true :web-login-fixture:assembleDebug.
Uses the production viewport source, a separate APK/UID, and no Internet permission.
No player data or real provider login is involved.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default='adb')
parser.add_argument('--serial', required=True)
parser.add_argument('--apk', type=Path, default=Path('android/web-login-fixture/build/outputs/apk/debug/web-login-fixture-debug.apk'))
parser.add_argument('--out', type=Path, default=Path('artifacts/web-login-viewport'))
parser.add_argument('--vary-device-density', action='store_true', help='Emulator only: exercise actual display DPI and restore it afterward')
args = parser.parse_args()
adb = [args.adb, '-s', args.serial]
package = 'org.vrpassthroughplayer.webfixture'
activity = package + '/.WebLoginFixtureActivity'
args.out.mkdir(parents=True, exist_ok=True)
if args.vary_device_density and not args.serial.startswith('emulator-'):
    parser.error('--vary-device-density only accepts an emulator serial')

def run(*command, **kwargs):
    return subprocess.run(adb + list(command), check=True, **kwargs)

run('install', '-r', str(args.apk))
original_density = None
if args.vary_device_density:
    original_density = run('shell', 'wm', 'density', capture_output=True, text=True).stdout
cases = [
    ('legacy-480', 480, 1.8, False, True),
    ('fixed-160', 160, 1.0, False, False),
    ('fixed-480', 480, 1.8, False, False),
    ('fixed-640-portrait', 640, 2.0, True, False),
]
reports = {}
try:
    for name, density, font_scale, portrait, legacy in cases:
        if args.vary_device_density:
            run('shell', 'wm', 'density', str(density))
        target = args.out / name
        target.mkdir(exist_ok=True)
        run('shell', 'run-as', package, 'rm', '-f', 'files/report.json')
        run('shell', 'am', 'start', '-S', '-n', activity, '--ei', 'density', str(density),
            '--ef', 'font_scale', str(font_scale), '--ez', 'portrait', str(portrait).lower(),
            '--ez', 'legacy', str(legacy).lower())
        deadline = time.monotonic() + 45
        report = None
        while time.monotonic() < deadline:
            result = subprocess.run(adb + ['exec-out', 'run-as', package, 'cat', 'files/report.json'], capture_output=True)
            if result.returncode == 0:
                try:
                    report = json.loads(result.stdout)
                    break
                except (ValueError, UnicodeDecodeError):
                    pass
            time.sleep(0.5)
        if report is None:
            raise RuntimeError(f'{name}: timed out waiting for fixture')
        (target / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        for phase in ('initial', 'captcha', 'resized'):
            result = run('exec-out', 'run-as', package, 'cat', f'files/{phase}.png', capture_output=True)
            assert result.stdout.startswith(b'\x89PNG\r\n\x1a\n'), f'{name}: invalid PNG'
            (target / f'{phase}.png').write_bytes(result.stdout)
        reports[name] = report
        if legacy:
            assert not report['passed'] and not report['checks']['desktop_css_viewport'], 'Legacy must reproduce the DPI failure'
            assert not report['checks']['captcha_confirm_visible'], 'Legacy must expose the inaccessible confirmation'
        else:
            assert report['passed'], f'{name}: {report["checks"]}'
        print(name + ': ' + json.dumps(report['checks']))
finally:
    run('shell', 'am', 'force-stop', package)
    if original_density is not None:
        import re
        override = re.search(r'Override density:\s*(\d+)', original_density)
        run('shell', 'wm', 'density', override.group(1) if override else 'reset')
(args.out / 'verification.json').write_text(json.dumps({'serial': args.serial, 'passed': True, 'cases': reports}, indent=2), encoding='utf-8')
