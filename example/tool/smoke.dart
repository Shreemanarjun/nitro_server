// Smoke test for a running example app (any platform): every transport and
// response type over the network. Usage: dart tool/smoke.dart http://127.0.0.1:PORT
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

late final String base;
final http = HttpClient()..autoUncompress = false; // check gzip bytes ourselves
var failed = 0;

Future<(int, Map<String, String>, List<int>)> call(
  String method,
  String path, {
  List<int>? body,
  Map<String, String> headers = const {},
}) async {
  final req = await http.openUrl(method, Uri.parse('$base$path'));
  req.followRedirects = false;
  req.headers.removeAll(HttpHeaders.acceptEncodingHeader);
  headers.forEach(req.headers.set);
  if (body != null) req.add(body);
  final res = await req.close();
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  final h = <String, String>{};
  res.headers.forEach((k, v) => h[k] = v.join(', '));
  return (res.statusCode, h, bytes);
}

void check(String name, bool ok, [Object? detail]) {
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name${ok ? '' : '  -> $detail'}');
  if (!ok) failed++;
}

Future<void> main(List<String> args) async {
  base = args.single;
  String text(List<int> b) => utf8.decode(b);

  var (s, h, b) = await call('GET', '/hello');
  check('GET /hello', s == 200 && text(b) == 'hi 👋', '$s ${text(b)}');
  (s, h, b) = await call('GET', '/users/42');
  check('path param', s == 200 && text(b) == '{"id":"42"}', text(b));
  (s, h, b) = await call('POST', '/echo', body: utf8.encode('ping'));
  check('POST echo', s == 200 && text(b) == 'ping', text(b));
  (s, h, b) = await call('GET', '/slow');
  check('route timeout 408', s == 408, s);
  (s, h, b) = await call('GET', '/nope');
  check('404', s == 404, s);

  (s, h, b) = await call('GET', '/stream');
  check(
    'chunked stream',
    s == 200 && text(b) == List.generate(5, (i) => 'chunk $i\n').join(),
    '$s ${h['transfer-encoding']} ${text(b)}',
  );
  (s, h, b) = await call('GET', '/events');
  final sse = text(b);
  check(
    'SSE (3 events)',
    s == 200 &&
        h['content-type']!.startsWith('text/event-stream') &&
        'event: tick'.allMatches(sse).length == 3 &&
        sse.contains('id: 2\ndata: tick 2'),
    '$s ${h['content-type']} $sse',
  );
  (s, h, b) = await call('GET', '/static');
  check('getStatic', s == 200 && text(b) == 'static ok', text(b));
  (s, h, b) = await call('GET', '/report');
  check(
    'JSON writer',
    s == 200 && text(b) == '{"rows":[{"id":0,"score":0.0},{"id":1,"score":1.5},{"id":2,"score":3.0}]}',
    text(b),
  );
  const bd = 'XyZ';
  final mp = utf8.encode(
    '--$bd\r\nContent-Disposition: form-data; name="f"; filename="a.txt"\r\n\r\nhello\r\n--$bd--\r\n',
  );
  (s, h, b) = await call(
    'POST',
    '/upload',
    body: mp,
    headers: {'content-type': 'multipart/form-data; boundary=$bd'},
  );
  check(
    'multipart',
    s == 200 && text(b) == '{"parts":[{"name":"f","file":true,"bytes":5}]}',
    text(b),
  );
  (s, h, b) = await call('POST', '/ingest', body: Uint8List(100000));
  check(
    'streamed body 100 KB',
    s == 200 && text(b) == '{"bytes":100000}',
    text(b),
  );
  (s, h, b) = await call('GET', '/big', headers: {'accept-encoding': 'gzip'});
  check(
    'gzip',
    s == 200 &&
        h['content-encoding'] == 'gzip' &&
        utf8.decode(gzip.decode(b)) == 'nitro ' * 2000,
    '${h['content-encoding']} ${b.length}B',
  );
  (s, h, b) = await call('GET', '/login');
  check(
    'set-cookie',
    (h['set-cookie'] ?? '').contains('session=abc'),
    h['set-cookie'],
  );
  (s, h, b) = await call('GET', '/whoami', headers: {'cookie': 'session=abc'});
  check('read cookie', text(b) == '{"session":"abc"}', text(b));
  (s, h, b) = await call('GET', '/go');
  check(
    'redirect 302',
    s == 302 && h['location'] == '/hello',
    '$s ${h['location']}',
  );
  (s, h, b) = await call('GET', '/problem');
  check(
    'problem+json 422',
    s == 422 && h['content-type']!.startsWith('application/problem+json'),
    '$s ${h['content-type']}',
  );
  (s, h, b) = await call('GET', '/search/books?q=dart');
  check('param + query', text(b) == '{"kind":"books","q":"dart"}', text(b));
  (s, h, b) = await call('REPORT', '/report');
  check('custom verb', s == 200 && text(b) == 'custom verb', '$s ${text(b)}');

  final ws = await WebSocket.connect('${base.replaceFirst('http', 'ws')}/ws')
      .timeout(const Duration(seconds: 10));
  final replies = <Object?>[];
  final done = ws.take(2).forEach(replies.add);
  ws.add('ping');
  ws.add(Uint8List.fromList([1, 2, 3]));
  await done.timeout(const Duration(seconds: 10));
  await ws.close();
  check('WebSocket text', replies[0] == 'echo: ping', replies);
  check(
    'WebSocket binary',
    replies[1] is List<int> && (replies[1] as List<int>).join(',') == '1,2,3',
    replies,
  );

  final many = await Future.wait([
    for (var i = 0; i < 50; i++) call('GET', '/hello').then((r) => r.$1),
  ]);
  check(
    '50 concurrent requests',
    many.every((c) => c == 200),
    many.where((c) => c != 200).length,
  );

  http.close(force: true);
  stdout.writeln(failed == 0 ? 'ALL PASSED' : '$failed FAILED');
  exit(failed == 0 ? 0 : 1);
}
