/// Instance-key allocation for the Nitro multi-instance factory.
///
/// One spec class produces one shared library, so `nitro_server` cannot split
/// roles across spec files without cross-dylib symbol wiring on five
/// platforms. Roles therefore ride on the instance key the C++ factory parses:
///
/// | Key        | Backing object                                              |
/// |------------|-------------------------------------------------------------|
/// | `engine`   | process-wide singleton: capabilities, global reset        |
/// | `s:<id>`   | one `ServerInstance`: accept loop, router, pending table |
library;

/// Allocates the ids embedded in instance keys.
abstract final class Ids {
  static int _server = 0;

  static int nextServer() => ++_server;

  /// Test-only. Resets the counter so key-dependent assertions are stable.
  static void resetForTesting() => _server = 0;
}

/// The process-wide engine instance key.
const String kEngineKey = 'engine';

/// The instance key for server [serverId].
String serverKey(int serverId) => 's:$serverId';
