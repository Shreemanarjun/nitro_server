// Repro for 'the first native touch of a new incarnation stops stragglers'.
// Mirrors the e2e test exactly, with stage prints.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/instance_keys.dart';
import 'package:nitro_server/src/internal/native_attach.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

Future<String> get_(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client
        .openUrl('GET', Uri.parse('http://127.0.0.1:$port$path'))
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
    final bytes = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    ).timeout(const Duration(seconds: 5));
    return utf8.decode(bytes.toBytes());
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  loadNitroServerNative();

  final server = await NitroServer.bind();
  await server.route(
    HttpMethod.get,
    '/',
    (_) async => ResponseContext.text('one'),
  );
  final firstPort = server.port;
  print('STAGE1 body=${await get_(firstPort, '/')}');

  resetNativeAttachForTesting();
  Ids.resetForTesting();

  print('STAGE2 resetNative');
  NitroServerNative.forKey(kEngineKey).resetNative();

  print('STAGE3 reborn bind');
  final reborn = await NitroServer.bind();
  print('STAGE3 reborn port=${reborn.port} firstPort=$firstPort');
  await reborn.route(
    HttpMethod.get,
    '/',
    (_) async => ResponseContext.text('two'),
  );

  // Does the old port still answer (straggler alive) or refuse?
  try {
    print('STAGE4 old port: ${await get_(firstPort, '/')}');
  } catch (e) {
    print('STAGE4 old port refused/failed: $e');
  }

  try {
    print('STAGE5 reborn body=${await get_(reborn.port, '/')}');
  } catch (e) {
    print('STAGE5 reborn FAILED: $e');
  }

  await server.close();
  await reborn.close();
  exit(0);
}
