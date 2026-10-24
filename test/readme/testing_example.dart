// README block: Testing (verbatim; verified by readme_snippets_test.dart).
// Verbatim README code (see readme_snippets_test.dart); not reformatted:
// dart format off
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  test('routes and websocket', () async {
    final client = await NitroTestClient.start();
    final s = client.server;
    await s.get('/users/:id', (r) => ResponseContext.text('u${r.param('id')}'));
    await s.post('/echo', (r) => ResponseContext.jsonBody(r.jsonMap()));
    await s.ws('/ws', (session) async {
      await for (final m in session.messages) {
        if (m is WsText) session.sendText('echo: ${m.text}');
      }
    });

    expect((await client.get('/users/42')).text(), 'u42');

    final posted = await client.post('/echo',
        body: {'a': 1}, headers: {'content-type': 'application/json'});
    expect(posted.status, 200);
    expect(posted.json(), {'a': 1});

    final ws = await client.ws('/ws');
    ws.sendText('hi');
    expect((await ws.messages.first).text, 'echo: hi');
    await ws.close();

    await client.close();
  });
}
