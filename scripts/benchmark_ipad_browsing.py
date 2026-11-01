#!/usr/bin/env python3
"""Compare an already installed Soulo with Safari on an opt-in physical iPad.

Builds a separate UI driver, leaving the app's Release build unchanged. Uses
private Soulo pages and closes only the Safari tabs created by this test.
Requires Xcode, XcodeGen, device development signing and an unlocked iPad.
"""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Physical iPad hardware UDID')
    parser.add_argument('--team', required=True, help='Development team for the test driver')
    parser.add_argument('--output', type=Path, required=True, help='New local artifact directory')
    parser.add_argument('--workload', choices=['fixture', 'live', 'interaction'], default='fixture')
    parser.add_argument('--scroll-only', action='store_true')
    parser.add_argument('--edge', action='store_true', help='Use a native edge gesture in the interaction diagnostic instead of the Back button')
    parser.add_argument('--baidu', choices=['YES', 'NO'], default='YES')
    parser.add_argument('--trace-browser', choices=['soulo', 'safari'], help='Capture a finite 15 s Animation Hitches trace while this browser scrolls')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    state = args.output.resolve()
    state.mkdir(parents=True, exist_ok=False)
    driver = state / 'driver'
    driver.mkdir()
    (driver / 'Host.swift').write_text('''import UIKit
@main final class Host: UIResponder, UIApplicationDelegate {
 var window: UIWindow?
 func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  window=UIWindow(frame:UIScreen.main.bounds);window?.rootViewController=UIViewController();window?.makeKeyAndVisible();return true
 }
}
''')
    spec = {
        'name': 'BrowserBench',
        'options': {'deploymentTarget': {'iOS': '17.0'}},
        'settings': {'base': {'DEVELOPMENT_TEAM': args.team, 'CODE_SIGN_STYLE': 'Automatic', 'GENERATE_INFOPLIST_FILE': 'YES', 'TARGETED_DEVICE_FAMILY': '1,2'}},
        'targets': {
            'Host': {'type': 'application', 'platform': 'iOS', 'sources': ['Host.swift'], 'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.dkluge.Soulo.BenchmarkHost', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
            'BrowserBenchTests': {'type': 'bundle.ui-testing', 'platform': 'iOS', 'sources': [str(root / 'SouloUITests' / p) for p in ['IPadBrowserBenchmarkUITests.swift', 'BrowserBenchmarkHTTPFixture.swift']], 'dependencies': [{'target': 'Host'}], 'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.dkluge.Soulo.BenchmarkTests', 'TEST_TARGET_NAME': 'Host'}}}
        },
        'schemes': {'BrowserBench': {'build': {'targets': {'Host': 'all', 'BrowserBenchTests': ['test']}}, 'test': {'targets': ['BrowserBenchTests']}}}
    }
    spec_path = driver / 'project.json'
    spec_path.write_text(json.dumps(spec, indent=2))
    subprocess.run(['xcodegen', 'generate', '--spec', str(spec_path)], cwd=driver, check=True)
    derived = state / 'DerivedData'
    destination = 'platform=iOS,id=' + args.device
    with (state / 'build.log').open('w') as log:
        subprocess.run(['xcodebuild', '-project', str(driver / 'BrowserBench.xcodeproj'), '-scheme', 'BrowserBench', '-derivedDataPath', str(derived), '-destination', destination, '-allowProvisioningUpdates', 'build-for-testing'], stdout=log, stderr=subprocess.STDOUT, check=True)
    products = derived / 'Build/Products'
    run = next(products.glob('BrowserBench_iphoneos*.xctestrun'))
    config = plistlib.loads(run.read_bytes())
    environment = {'SOULO_IPAD_BENCHMARK': '1', 'SOULO_BENCH_SCROLL_ONLY': str(int(args.scroll_only)), 'SOULO_BENCH_BAIDU': args.baidu, 'SOULO_BENCH_EDGE': str(int(args.edge))}
    for name, target in config.items():
        if name.startswith('__') or not isinstance(target, dict):
            continue
        for key in ['EnvironmentVariables', 'TestHostEnvironmentVariables']:
            target.setdefault(key, {}).update(environment)
    configured_run = products / 'IPadBenchmark.xctestrun'
    configured_run.write_bytes(plistlib.dumps(config))
    method = {'fixture':'testFixtureComparison', 'live':'testLiveSaltComparison', 'interaction':'testLongPressSelectionAndHistory'}[args.workload]
    command = ['xcodebuild', '-xctestrun', str(configured_run), '-destination', destination, '-parallel-testing-enabled', 'NO', '-only-testing:BrowserBenchTests/IPadBrowserBenchmarkUITests/' + method, '-resultBundlePath', str(state / 'Results.xcresult'), 'test-without-building']
    test_log = state / 'test.log'
    trace = None
    seen = set()
    with test_log.open('w') as log, (state / 'trace.log').open('w') as trace_log:
        test = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        while test.poll() is None:
            contents = test_log.read_text(errors='replace')
            trigger = 'IPAD_BENCH_PHASE|' + str(args.trace_browser) + '|scroll-start|'
            if args.trace_browser and trace is None and trigger in contents:
                trace = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Animation Hitches', '--device', args.device, '--time-limit', '15s', '--all-processes', '--no-prompt', '--output', str(state / 'Scrolling.trace')], stdout=trace_log, stderr=subprocess.STDOUT)
            for line in contents.splitlines():
                if 'IPAD_BENCH_' in line and line not in seen:
                    seen.add(line)
                    print(line, flush=True)
            time.sleep(.5)
        code = test.wait()
        if trace:
            # Let the remote recording stop and save naturally. Interrupting an
            # all-process trace can fail to save on some device/Xcode versions.
            trace.wait(timeout=180)
            print('Trace exit:', trace.returncode, flush=True)
        print('Test exit:', code, flush=True)
        return code


if __name__ == '__main__':
    raise SystemExit(main())
