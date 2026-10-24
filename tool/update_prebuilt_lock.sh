#!/usr/bin/env bash
# Writes prebuilt_checksums.json (package root) for one released version from the
# `.sha256` sidecars the release workflow attached — run AFTER the release
# workflow finished for the tag and BEFORE `dart pub publish`, then commit the
# file. The digests then ship inside the package, so consumers verify a
# downloaded prebuilt against a value that never travelled through the
# release channel (see lib/src/internal/prebuilt_lock.dart).
#
#   tool/update_prebuilt_lock.sh 1.0.0
#
# With cosign on PATH each asset's Sigstore bundle is verified first, so a
# tampered release cannot be locked in by mistake.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version, e.g. 1.0.0}"
REPO="${NITRO_SERVER_REPO:-Shreemanarjun/nitro_server}"
BASE="${NITRO_SERVER_PREBUILT_BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
BASE="${BASE%/}"
LOCK=prebuilt_checksums.json
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
entries=""
for asset in libnitro_server-macos-arm64.dylib libnitro_server-macos-x64.dylib \
             libnitro_server-linux-arm64.so libnitro_server-linux-x64.so \
             libnitro_server-windows-x64.dll; do
  if ! curl -fsSL -o "$TMP/$asset" "$BASE/$asset"; then
    echo "skip $asset (not in the release)"; continue
  fi
  digest=$(shasum -a 256 "$TMP/$asset" | awk '{print $1}')
  sidecar=$(curl -fsSL "$BASE/$asset.sha256" | awk '{print $1}')
  [ "$digest" = "$sidecar" ] || { echo "sidecar mismatch for $asset"; exit 1; }
  if command -v cosign >/dev/null && [ "${NITRO_SERVER_SKIP_SIGSTORE:-0}" != "1" ]; then
    curl -fsSL -o "$TMP/$asset.sigstore.json" "$BASE/$asset.sigstore.json"
    cosign verify-blob --bundle "$TMP/$asset.sigstore.json" \
      --certificate-identity-regexp "^https://github.com/$REPO/" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      "$TMP/$asset" >/dev/null
    echo "verified $asset (sigstore)"
  else
    echo "locked $asset (cosign not on PATH: bundle not verified here)"
  fi
  entries="$entries    \"$asset\": \"$digest\",\n"
done
python3 - "$LOCK" "$VERSION" "$(printf "$entries")" <<'PY'
import json, sys
path, version, entries = sys.argv[1], sys.argv[2], sys.argv[3]
lock = json.load(open(path))
lock[version] = {}
for line in entries.strip().splitlines():
    k, v = line.strip().rstrip(',').split(':', 1)
    lock[version][k.strip().strip('"')] = v.strip().strip('"')
json.dump(lock, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(f"{path}: {len(lock[version])} asset(s) locked for {version}")
PY
