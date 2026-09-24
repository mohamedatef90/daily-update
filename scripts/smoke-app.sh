#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/DailyUpdate.app"
RESOURCE_BUNDLE="$APP/DailyUpdate_DailyUpdate.bundle"

[[ -x "$APP/Contents/MacOS/DailyUpdate" ]] || {
  echo "FAIL: app executable is missing" >&2
  exit 1
}

[[ -f "$RESOURCE_BUNDLE/Contents/Resources/detectors.json" ]] || {
  echo "FAIL: SwiftPM resource bundle is missing from the packaged app" >&2
  exit 1
}

[[ -x "$RESOURCE_BUNDLE/Contents/Resources/check-app-update.sh" ]] || {
  echo "FAIL: bundled update-check script is missing or not executable" >&2
  exit 1
}

echo "PASS: packaged executable and SwiftPM resources are present"
