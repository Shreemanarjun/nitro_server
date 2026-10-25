// ion_web side of the blackbox benchmark. Serves the same routes as
// compare.dart's dart:io/shelf sides and compare_go_server.go, byte-identical,
// and prints "LISTENING <port>" for orchestrate.sh. `--isolates N` binds N
// isolates to one port with `shared: true` (SO_REUSEPORT), the same equal-CPU
// budget dart:io and shelf get. Kept in its own package so ion_web never enters
// nitro_server's dependency graph.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ion_router/ion_router.dart';
import 'package:ion_web/ion_web.dart';

final _hello = Uint8List.fromList('hello world!'.codeUnits);
final _json = Uint8List.fromList(
  jsonEncode({
    'id': 42,
    'name': 'nitro',
    'tags': ['a', 'b', 'c'],
  }).codeUnits,
);

// Encoded PER REQUEST and INLINE from the index, the same shape as nitro's
// JsonWriter, Go's strings.Builder and Node's loop: no per-request List<Map>.
// Byte-identical to jsonEncode (Dart's double toString gives "0.0", "1.5").
Uint8List _workBody() {
  final b = StringBuffer('[');
  for (var i = 0; i < 200; i++) {
    if (i > 0) b.write(',');
    b
      ..write('{"id":')
      ..write(i)
      ..write(r',"name":"item-$i","tags":["a","b"],"score":')
      ..write(i * 1.5)
      ..write('}');
  }
  b.write(']');
  return utf8.encode(b.toString());
}

// Content-Type values identical to nitro's for each route (equal header
// bytes): ResponseContext.bytes -> octet-stream, .text -> text/plain utf-8,
// .jsonMap/.jsonWriter -> application/json utf-8, getStatic -> text/plain.
const _binary = <TypedHeader>[.contentType('application/octet-stream')];
const _textUtf8 = <TypedHeader>[.contentType('text/plain', charset: 'utf-8')];
const _jsonUtf8 = <TypedHeader>[
  .contentType('application/json', charset: 'utf-8'),
];
const _plain = <TypedHeader>[.contentType('text/plain')];

Response _bytes(Uint8List b, [List<TypedHeader> h = const []]) =>
    Response.bytes(b, headers: h);

Future<Response> _echo(Request req) async {
  final b = BytesBuilder(copy: false);
  await for (final chunk in req) {
    b.add(chunk);
  }
  return _bytes(b.takeBytes(), _binary);
}

// ion's own router (ion_router), like nitro's trie router: same patterns,
// params and wildcard. Handlers are synchronous like nitro's; only /echo
// awaits (it reads the body). One pass-through middleware layer, like nitro's
// `use((r, next) => next(r))`.
Handler _buildRouter() {
  final app = Router();
  app.use(
    (next) =>
        (req) => next(req),
  );
  app.get('/hello', (_) => _bytes(_hello, _binary));
  app.get('/json', (_) => _bytes(_json, _binary));
  app.get('/static', (_) => _bytes(_hello, _plain));
  app.get('/mw', (_) => _bytes(_hello, _binary));
  app.get(
    '/users/{id}',
    (req) => _bytes(
      Uint8List.fromList('user ${req.param('id')}'.codeUnits),
      _textUtf8,
    ),
  );
  app.get(
    '/files/*',
    (req) =>
        _bytes(Uint8List.fromList('wild:${req.uri.path}'.codeUnits), _textUtf8),
  );
  app.get(
    '/q',
    (req) => _bytes(
      Uint8List.fromList(jsonEncode(req.uri.queryParameters).codeUnits),
      _jsonUtf8,
    ),
  );
  app.get('/work', (_) => _bytes(_workBody(), _jsonUtf8));
  app.post('/echo', _echo);
  return app.call;
}

final Handler _handler = _buildRouter();

Future<IonServer> _bind(int port) => IonServer.serve(
  _handler,
  address: InternetAddress.loopbackIPv4,
  port: port,
  shared: true,
  backlog: 128, // nitro's default listen backlog
);

Future<void> _worker((int, SendPort) args) async {
  await _bind(args.$1);
  args.$2.send(true);
}

Future<void> main(List<String> args) async {
  final i = args.indexOf('--isolates');
  final isolates = i >= 0 ? int.parse(args[i + 1]) : 1;
  final server = await _bind(0);
  for (var n = 1; n < isolates; n++) {
    final ready = ReceivePort();
    await Isolate.spawn(_worker, (server.port, ready.sendPort));
    await ready.first;
  }
  stderr.writeln('ion_web isolates=$isolates');
  stdout.writeln('LISTENING ${server.port}');
}
