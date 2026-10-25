#!/usr/bin/env bash
# CI (and local) Android smoke test: needs a running emulator/device on adb and
# an APK built with
#   flutter build apk --debug --dart-define=NITRO_EXAMPLE_AUTOSTART=true \
#     --dart-define=NITRO_EXAMPLE_PORT=8765
# Installs it, starts the server, forwards the port and runs tool/smoke.dart.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${NITRO_EXAMPLE_PORT:-8765}"
PKG=dev.shreeman.nitro_server_example
adb wait-for-device
adb install -r -g build/app/outputs/flutter-apk/app-debug.apk
ACTIVITY=$(adb shell cmd package resolve-activity --brief "$PKG" | tail -1 | tr -d '\r')
adb shell am start -W -n "$ACTIVITY" >/dev/null
adb forward "tcp:$PORT" "tcp:$PORT"
for _ in $(seq 1 120); do
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT/hello" && break
  sleep 1
done
dart tool/smoke.dart "http://127.0.0.1:$PORT"
