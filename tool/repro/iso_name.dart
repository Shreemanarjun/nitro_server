import 'dart:isolate';
import 'package:test/test.dart';
void main() {
  test('isolate name', () {
    print('DEBUGNAME=${Isolate.current.debugName}');
  });
}
