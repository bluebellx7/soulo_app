#!/usr/bin/env python3
"""Compare cold launches of a DEBUG build on a disposable iOS simulator.

Install the app first. Example:
  python3 scripts/benchmark_webview_startup.py --device <UDID> --repeats 3
Each run terminates the app, toggles only the debug warmup switch, then opens a
URL via Soulo's existing search route. Local responses disable HTTP caching.
This measures app-process cold starts, not simulator/OS cold boots.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import statistics
import subprocess
import threading
import time
import urllib.parse


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'''<!doctype html><meta name="viewport" content="width=device-width">
        <title>Soulo startup fixture</title><style>body{font:24px system-ui;padding:24px;background:#f3f5ee;color:#162b22}</style>
        <h1>Page ready</h1><p>Local startup benchmark</p><input placeholder="Retained tab state">
        <p>No external scripts, images, fonts or network dependencies.</p>'''
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def events(path):
    result = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if line.startswith("SOULO_TIMING|"):
                _, timestamp, event, detail = line.split("|", 3)
                result.append({"time": float(timestamp), "event": event, "detail": detail})
    return result


def wait_event(path, names, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        records = events(path)
        if any(item["event"] in names for item in records):
            return records
        time.sleep(0.05)
    return events(path)


def summarize(records):
    first = {}
    for item in records:
        first.setdefault(item["event"], item["time"])
    metrics = {}
    for name, start, end in [
        ("submit_to_visible_ms", "search_submit", "content_visible"),
        ("submit_to_commit_ms", "search_submit", "navigation_commit"),
        ("submit_to_finish_ms", "search_submit", "navigation_finish"),
        ("acquire_ms", "acquire_start", "acquire_end"),
        ("runtime_ms", "runtime_start", "runtime_end"),
        ("submit_to_attached_ms", "search_submit", "view_attached"),
        ("attached_to_commit_ms", "view_attached", "navigation_commit"),
        ("warmup_ms", "warmup_start", "warmup_ready"),
    ]:
        if start in first and end in first:
            metrics[name] = round((first[end] - first[start]) * 1000, 1)
    metrics["pool_hit"] = "pool_hit" in first
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--delays", type=float, nargs="+", default=[0.1, 2.5])
    parser.add_argument("--url", help="Real website; default is a fixed localhost fixture")
    parser.add_argument("--output", default="/tmp/soulo-webview-startup-ab")
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    target = args.url or f"http://127.0.0.1:{server.server_port}/fixture"
    bundle = "com.dkluge.Soulo"

    def simctl(*command, **kwargs):
        return subprocess.run(["xcrun", "simctl", *command], text=True, capture_output=True, **kwargs)

    container = simctl("get_app_container", args.device, bundle, "data")
    if container.returncode:
        raise RuntimeError(container.stderr)
    simulator_data = Path(container.stdout.strip()).parents[3]
    assert simulator_data.name == "data"
    results = []
    try:
        for delay in args.delays:
            for repeat in range(args.repeats):
                # Alternate pair ordering to limit one-sided system-cache bias.
                for warm in ([False, True] if repeat % 2 == 0 else [True, False]):
                    label = f"delay-{delay}-run-{repeat}-{'warm' if warm else 'cold'}"
                    # simctl interprets redirected paths inside the simulator.
                    redirected = Path("/tmp") / f"soulo-startup-{label}.log"
                    log = simulator_data / str(redirected).lstrip("/")
                    log.write_text("")
                    simctl("terminate", args.device, bundle)
                    time.sleep(1)
                    env = dict(os.environ, SIMCTL_CHILD_SOULO_BROWSER_TRACE="1",
                               SIMCTL_CHILD_SOULO_DISABLE_WEBVIEW_WARMUP="0" if warm else "1")
                    launched = simctl("launch", f"--stdout={redirected}", f"--stderr={redirected}.stderr",
                                      args.device, bundle, "-privacy_https_upgrade_enabled", "NO", env=env)
                    if launched.returncode:
                        raise RuntimeError(launched.stderr)
                    activated = wait_event(log, {"pool_activate"}, 30)
                    if not any(item["event"] == "pool_activate" for item in activated):
                        raise RuntimeError(f"App never reached activation: {log}")
                    time.sleep(delay)
                    route = "soulo://open?" + urllib.parse.urlencode({"url": target})
                    opened = simctl("openurl", args.device, route)
                    if opened.returncode:
                        raise RuntimeError(opened.stderr)
                    records = wait_event(log, {"content_visible"}, 45)
                    # Capture load completion too, but don't confuse it with first content.
                    if any(item["event"] == "content_visible" for item in records):
                        records = wait_event(log, {"navigation_finish"}, 5)
                    result = dict(label=label, warm=warm, delay=delay, url=target,
                                  metrics=summarize(records), events=records)
                    (output / f"{label}.log").write_text(log.read_text(errors="replace"))
                    results.append(result)
                    (output / "results.json").write_text(json.dumps(results, indent=2))
                    print(json.dumps({"run": label, **result["metrics"]}), flush=True)
        summary = []
        for delay in args.delays:
            for warm in [False, True]:
                rows = [r["metrics"] for r in results if r["delay"] == delay and r["warm"] == warm]
                keys = sorted({key for row in rows for key in row if key.endswith("_ms")})
                summary.append(dict(delay=delay, warm=warm, runs=len(rows),
                                    visible_samples=sum("submit_to_visible_ms" in r for r in rows),
                                    medians={key: statistics.median(r[key] for r in rows if key in r) for key in keys}))
        (output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
