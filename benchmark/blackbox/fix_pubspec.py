#!/usr/bin/env python3
"""Rewrite nitro_server's pubspec for the in-container blackbox build.

One edit: drop the publish-only Flutter SDK env constraint — nitro is Dart-only
and nitro_server's Dart code is Flutter-free, so `dart pub get` needs no Flutter.
The nitro* packages resolve from pub.dev like any other dependency.

Prints the resulting sdk lines so the build log shows what pub will resolve.
Idempotent.
"""
import re

PATH = "pubspec.yaml"
s = open(PATH).read()
s = re.sub(r"(?m)^\s*flutter:\s*['\"]>=.*$\n?", "", s)
open(PATH, "w").write(s)

print("[fix_pubspec] resulting resolution-relevant lines:")
for line in s.splitlines():
    t = line.strip()
    if t.startswith("sdk:") or t == "flutter:":
        print("  " + t)
