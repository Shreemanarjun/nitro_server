// The shared ANSI/log palette: every branch asserted directly so colours and
// the latency formatter are pinned.
import 'package:nitro_server/src/internal/ansi.dart';
import 'package:test/test.dart';

void main() {
  test('ansi wraps only when on', () {
    expect(ansi('x', '32', on: true), '\x1b[32mx\x1b[0m');
    expect(ansi('x', '32', on: false), 'x');
  });

  test('methodHue colours every verb class', () {
    expect(methodHue('GET'), '32');
    expect(methodHue('HEAD'), '32');
    expect(methodHue('POST'), '33');
    expect(methodHue('PUT'), '33');
    expect(methodHue('PATCH'), '33');
    expect(methodHue('DELETE'), '31');
    expect(methodHue('OPTIONS'), '36'); // fallthrough
    expect(methodHue('PURGE'), '36'); // custom verb
  });

  test('statusHue colours every status class', () {
    expect(statusHue(200), '32');
    expect(statusHue(301), '36');
    expect(statusHue(404), '33');
    expect(statusHue(500), '31');
  });

  test('formatLatency uses µs under 1ms and ms above', () {
    expect(formatLatency(0), '0µs');
    expect(formatLatency(843), '843µs');
    expect(formatLatency(999), '999µs');
    expect(formatLatency(1000), '1.00ms');
    expect(formatLatency(1234), '1.23ms');
    expect(formatLatency(2_500_000), '2500.00ms');
  });
}
