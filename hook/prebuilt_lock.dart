/// The prebuilt lock: SHA-256 digests of the engine prebuilts this package
/// version ships, embedded in the package itself so a downloaded asset is
/// checked against a value that did NOT travel through the download channel.
/// A compromised release page can replace the asset and its `.sha256`
/// sidecar together; it cannot change what is already on pub.dev.
///
/// `hook/prebuilt_checksums.json` maps `version -> asset file name -> hex
/// digest`; `tool/update_prebuilt_lock.sh` fills it from a finished release
/// before the package is published. No entry means no prebuilt for that
/// target: the hook builds from source instead of trusting the download.
library;

import 'dart:convert';
import 'dart:io';

/// The digest the lock expects for [asset] of [version], or null when the
/// lock has no entry (not published yet, unknown target).
String? expectedDigest(String lockJson, String version, String asset) {
  final Object? decoded;
  try {
    decoded = jsonDecode(lockJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final byVersion = decoded[version];
  if (byVersion is! Map) return null;
  final digest = byVersion[asset];
  if (digest is! String) return null;
  final hex = digest.trim().toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
}

/// Constant-time comparison of two hex digests.
bool digestMatches(String actualHex, String expectedHex) {
  final a = actualHex.toLowerCase().codeUnits,
      b = expectedHex.toLowerCase().codeUnits;
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Where a release's assets live: GitHub Releases by default, or the mirror
/// named by `NITRO_SERVER_PREBUILT_BASE_URL` (an internal artifact store, or
/// a local server in the hook's own end-to-end test). The tag is `v<version>`.
Uri prebuiltBaseUrl(String repo, String version, Map<String, String> env) {
  final override = env['NITRO_SERVER_PREBUILT_BASE_URL'];
  if (override != null && override.isNotEmpty) {
    return Uri.parse(override.endsWith('/') ? override : '$override/');
  }
  return Uri.parse('https://github.com/$repo/releases/download/v$version/');
}

/// The cosign invocation the strict mode runs: the bundle must prove the
/// asset was signed by [repo]'s GitHub Actions workflow (keyless identity),
/// not merely by some valid Sigstore certificate.
List<String> cosignVerifyArgs(
  String repo,
  String bundlePath,
  String assetPath,
) => [
  'verify-blob',
  '--bundle',
  bundlePath,
  '--certificate-identity-regexp',
  '^https://github.com/$repo/',
  '--certificate-oidc-issuer',
  'https://token.actions.githubusercontent.com',
  assetPath,
];

/// Downloads [asset] for [version] from [base] and accepts it only when its
/// SHA-256 equals the digest locked in [lockJson]; with [strictSigstore] the
/// release's `<asset>.sigstore.json` bundle must also pass [runCosign] (an
/// absent bundle or a failing cosign refuses the asset). Returns null when
/// the lock has no entry or the asset is not published (the caller builds
/// from source), and throws when something that should match does not —
/// never silently uses an unverified file.
///
/// [fetch] returns the body of a URL or null on a non-200; [runCosign] runs
/// `cosign` with the given arguments and returns its exit code. Both are
/// injected so the whole path is exercised in tests against a local release.
Future<bool> fetchVerifiedPrebuilt({
  required Uri base,
  required String version,
  required String asset,
  required String lockJson,
  required String repo,
  required File dest,
  required Future<List<int>?> Function(Uri url) fetch,
  required Future<int> Function(List<String> args) runCosign,
  required String Function(List<int> bytes) sha256Hex,
  bool strictSigstore = false,
}) async {
  final expected = expectedDigest(lockJson, version, asset);
  if (expected == null) return false;
  final bytes = await fetch(base.resolve(asset));
  if (bytes == null) return false;
  final actual = sha256Hex(bytes);
  if (!digestMatches(actual, expected)) {
    throw StateError(
      'prebuilt $asset does not match the digest locked in '
      'hook/prebuilt_checksums.json ($actual != $expected): refusing it',
    );
  }
  await dest.create(recursive: true);
  await dest.writeAsBytes(bytes, flush: true);
  if (!strictSigstore) return true;
  final bundle = await fetch(base.resolve('$asset.sigstore.json'));
  if (bundle == null) {
    await dest.delete();
    throw StateError(
      'NITRO_SERVER_VERIFY_SIGSTORE: no Sigstore bundle for $asset',
    );
  }
  final bundleFile = File('${dest.path}.sigstore.json');
  await bundleFile.writeAsBytes(bundle, flush: true);
  final code = await runCosign(
    cosignVerifyArgs(repo, bundleFile.path, dest.path),
  );
  if (code != 0) {
    await dest.delete();
    throw StateError(
      'NITRO_SERVER_VERIFY_SIGSTORE: cosign rejected $asset (exit $code)',
    );
  }
  return true;
}
