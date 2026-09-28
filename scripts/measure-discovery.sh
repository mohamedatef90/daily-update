#!/usr/bin/env bash
# Live, read-only discovery budget probe. Optional argument: a d5133de DailyUpdate executable.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [path-to-d5133de-DailyUpdate]" >&2
    exit 2
fi
if [[ $# -eq 1 && ! -x "$1" ]]; then
    echo "Baseline executable is missing or not executable: $1" >&2
    exit 2
fi
if ! command -v sandbox-exec >/dev/null; then
    echo "sandbox-exec is required; discovery cannot be proven offline without it" >&2
    exit 2
fi

baseline="${1:-}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-update-discovery.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Deny every write and every network operation. Deny reads of the real settings as well:
# the release binary falls back to bundled defaults and cannot inspect App Support.
python3 - "$scratch/profile.sb" <<'PY'
import os
import sys

app_support = os.path.realpath(os.path.expanduser('~/Library/Application Support/DailyUpdate'))
quoted = app_support.replace('\\', '\\\\').replace('"', '\\"')
with open(sys.argv[1], 'w', encoding='utf-8') as profile:
    profile.write('(version 1)\n(allow default)\n')
    # zsh's login startup redirects to /dev/null; keep that harmless sink writable.
    profile.write('(deny network*)\n(deny file-write*)\n')
    profile.write('(allow file-write* (literal "/dev/null"))\n')
    profile.write(f'(deny file-read* (subpath "{quoted}"))\n')
PY

swift build -c release
binary="$(swift build -c release --show-bin-path)/DailyUpdate"

# The release CLI is also measured end to end in the deny-network sandbox. Keep this
# separate from the XCTest timings so process startup and JSON encoding are visible.
python3 - "$scratch/profile.sb" "$binary" "$baseline" <<'PY'
import json
import math
import subprocess
import sys
import time

profile, binary, baseline = sys.argv[1:]
LOGIN_PATH_ERROR_ID = 'inv-error-login-path'


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def run(executable, action):
    start = time.perf_counter()
    completed = subprocess.run(
        ['sandbox-exec', '-f', profile, executable, action, '--json'],
        capture_output=True, text=True, timeout=120, check=False,
    )
    wall_ms = (time.perf_counter() - start) * 1000
    if action == '--discover' and completed.returncode != 0:
        raise RuntimeError(f'discovery exited {completed.returncode}: {completed.stderr[-1000:]}')
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f'{action} did not return JSON: {completed.stderr[-1000:]}') from error
    return payload, wall_ms, completed.returncode


reported = []
wall = []
for sample in range(1, 11):
    payload, elapsed, _ = run(binary, '--discover')
    if any(row.get('id') == LOGIN_PATH_ERROR_ID for row in payload.get('rows', [])):
        raise RuntimeError('login PATH lookup failed inside the sandbox; measurements are invalid')
    results = payload['results']
    statuses = [f'{entry["ecosystem"]}={entry["status"]}' for entry in results]
    print(f'CLI_SANDBOX sample={sample} ecosystem=status {" ".join(statuses) if statuses else "(none registered)"}', flush=True)
    incomplete = [status for status, entry in zip(statuses, results) if entry['status'] != 'complete']
    if incomplete:
        raise RuntimeError(f'incomplete discovery results in sandbox sample {sample}: {", ".join(incomplete)}; timings are invalid')
    reported.append(float(payload['elapsedMs']))
    wall.append(elapsed)

print(f'CLI_SANDBOX samples=10 proves_run_offline=yes budget_source=in_process_DISCOVERY_BUDGET network=denied writes=denied_except_dev_null appSupportRead=denied rows={len(payload["rows"])} results={len(payload["results"])}')
for name, values in [('discoveryPipeline', reported), ('discoveryWall', wall)]:
    print(f'CLI_SANDBOX {name} p50={percentile(values, .50):.2f}ms p95={percentile(values, .95):.2f}ms')

if baseline:
    current_payload, current_ms, current_exit = run(binary, '--check')
    old_payload, old_ms, old_exit = run(baseline, '--check')
    print(f'CHECK_SANDBOX daemon_brokered_writes_and_network=not_covered current={current_ms:.2f}ms exit={current_exit} baseline={old_ms:.2f}ms exit={old_exit}')
    print(f'CHECK_SANDBOX ratio={current_ms / old_ms:.3f} budget=1.100 (one paired sample; review before gating)')
PY

# The test measures whence, the coordinator, every registered enumerator and the full
# in-process pipeline separately. Its App Support is redirected by HermeticTestCase.
DAILY_UPDATE_LIVE_DISCOVERY=1 swift test --filter DiscoveryBudgetTests
