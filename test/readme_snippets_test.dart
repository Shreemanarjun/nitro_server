/// README code is verified, not illustrative: every ```dart block in README.md
/// is copied verbatim into test/readme/*.dart (fragments in snippets.dart, full
/// programs as their own files). Those files are compiled here, and this test
/// fails when a README code line is not present in them — so README code
/// cannot drift from the real API.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'readme/hot_reload_example.dart' as hot_reload;
import 'readme/quick_start.dart' as quick_start;
import 'readme/snippets.dart' as snippets;
import 'readme/testing_example.dart' as testing_example;

void main() {
  test('every line of every README dart block is compiled in test/readme', () {
    final readme = File('README.md').readAsStringSync();
    final blocks = RegExp(
      r'```dart\n(.*?)```',
      dotAll: true,
    ).allMatches(readme).map((m) => m.group(1)!).toList();
    expect(blocks.length, greaterThan(20));
    final compiled = Directory('test/readme')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .expand((f) => f.readAsLinesSync())
        .map((l) => l.trim())
        .toSet();
    final missing = <String>[];
    for (final (i, block) in blocks.indexed) {
      for (final line in block.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty && !compiled.contains(t)) {
          missing.add('block ${i + 1}: $t');
        }
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'README code absent from test/readme/*.dart',
    );
    // The imports above make `dart test` compile every snippet file.
    expect([
      quick_start.main,
      hot_reload.main,
      testing_example.main,
      snippets.env,
    ], hasLength(4));
  });
}
