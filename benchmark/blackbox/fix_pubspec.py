#!/usr/bin/env python3
"""Rewrite nitro_server's pubspec for the in-container blackbox build.

Two edits, both no-ops once nitro ships to pub.dev:
  1. Repoint the local nitro path-overrides (any `../` depth) at the copies
     run.sh vendored into benchmark/blackbox/_vendor.
  2. Drop the publish-only Flutter SDK env constraint — nitro is Dart-only and
     nitro_server's Dart code is Flutter-free, so `dart pub get` needs no Flutter.

Prints the resulting override/sdk lines so the build log shows exactly what pub
will resolve. Idempotent.
"""
import re

PATH = "pubspec.yaml"
s = open(PATH).read()
s = re.sub(
    r"(path:\s*)\S*flutter_package/nitro_ecosystem/packages/(\w+)",
    r"\1/app/benchmark/blackbox/_vendor/\2",
    s,
)
s = re.sub(r"(?m)^\s*flutter:\s*['\"]>=.*$\n?", "", s)
open(PATH, "w").write(s)

print("[fix_pubspec] resulting resolution-relevant lines:")
for line in s.splitlines():
    t = line.strip()
    if "path:" in line or t.startswith("sdk:") or t == "flutter:":
        print("  " + t)
