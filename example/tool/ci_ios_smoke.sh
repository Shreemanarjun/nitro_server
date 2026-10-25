#!/usr/bin/env bash
# CI (and local) iOS simulator smoke test: boots an available iPhone simulator,
# builds the example with autostart on a fixed port, installs + launches it and
# runs tool/smoke.dart (the simulator shares the host's loopback).
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${NITRO_EXAMPLE_PORT:-8765}"
BUNDLE=dev.shreeman.nitroServerExample
UDID="${SIMULATOR_UDID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
for runtime in sorted(devs, reverse=True):
    if "iOS" in runtime:
        for d in devs[runtime]:
            if d["name"].startswith("iPhone"):
                print(d["udid"]); sys.exit()
')}"
echo "simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
flutter build ios --simulator --debug \
  --dart-define=NITRO_EXAMPLE_AUTOSTART=true --dart-define=NITRO_EXAMPLE_PORT="$PORT"
xcrun simctl install "$UDID" build/ios/iphonesimulator/Runner.app
xcrun simctl launch "$UDID" "$BUNDLE"
for _ in $(seq 1 120); do
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT/hello" && break
  sleep 1
done
dart tool/smoke.dart "http://127.0.0.1:$PORT"
