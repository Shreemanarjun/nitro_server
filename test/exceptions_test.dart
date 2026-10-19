// Unit tests for throwIfFailed and the native-status -> exception mapping.
// No native library needed: pure data against the wire mapping table.
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/raw_mapping.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:test/test.dart';

void main() {
  group('throwIfFailed', () {
    test('none returns the bound port', () {
      expect(
        throwIfFailed(
          const RawServerStatus(boundPort: 4567),
          operation: 'start',
        ),
        4567,
      );
    });

    test('every error kind maps to its exception type', () {
      final cases = <RawServerErrorKind, Type>{
        RawServerErrorKind.alreadyRunning: ServerAlreadyRunningException,
        RawServerErrorKind.notRunning: ServerNotRunningException,
        RawServerErrorKind.bindFailed: ServerBindException,
        RawServerErrorKind.tlsError: ServerTlsException,
        RawServerErrorKind.routeNotFound: RouteNotFoundException,
        RawServerErrorKind.handlerTimeout: HandlerTimeoutException,
        RawServerErrorKind.requestTooLarge: ServerBadRequestException,
        RawServerErrorKind.badRequest: ServerBadRequestException,
        RawServerErrorKind.responseTooLarge: ServerUnknownException,
        RawServerErrorKind.io: ServerUnknownException,
        RawServerErrorKind.unknown: ServerUnknownException,
      };
      for (final entry in cases.entries) {
        expect(
          () => throwIfFailed(
            RawServerStatus(errorKind: entry.key, errorMessage: 'm'),
            operation: 'op',
          ),
          throwsA(
            isA<NitroServerException>().having(
              (e) => e.runtimeType.toString(),
              'type',
              entry.value.toString(),
            ),
          ),
          reason: 'wrong mapping for ${entry.key}',
        );
      }
    });
  });
}
