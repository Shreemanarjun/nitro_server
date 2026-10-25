/// Every [ServerConfig] default in one place, so the config class, the
/// runner and helper isolates read the same value instead of repeating
/// literals. Use these to build a config relative to the defaults, e.g.
/// `ServerConfig(maxBodyBytes: ServerDefaults.maxBodyBytes * 4)`.
library;

import 'context.dart' show HttpProtocol, ServerConfig;

abstract final class ServerDefaults {
  static const host = '127.0.0.1';
  static const port = 0;
  static const backlog = 128;
  static const maxBodyBytes = 10 * 1024 * 1024;
  static const defaultTimeout = Duration(seconds: 30);
  static const keepAliveTimeout = Duration(seconds: 5);
  static const maxRequestsPerConnection = 100;
  static const workerThreads = 0;
  static const isolates = 1;
  static const maxConnections = 0;
  static const maxConnectionsPerIp = 0;
  static const headerTimeout = Duration.zero;
  static const writeTimeout = Duration(seconds: 30);
  static const wsMaxBufferBytes = 1024 * 1024;
  static const wsCompression = true;
  static const protocol = HttpProtocol.http2;
  static const responseTiming = true;
  static const exposeErrorDetails = false;
  static const bodyTimeout = Duration.zero;
  static const wsIdleTimeout = Duration(seconds: 60);
  static const maxConnectionAge = Duration.zero;
  static const maxInFlightRequests = 0;
  static const proxyProtocol = false;
  static const streamIdleTimeout = Duration(minutes: 5);
  static const streamMaxBufferBytes = 4 * 1024 * 1024;
  static const maxBufferedBodyBytes = 64 * 1024 * 1024;
  // ignore: unnecessary_nullable_for_final_variable_declarations
  static const String? serverHeader = 'Nitro Dart Server'; // null = none
  static const keepAliveHeader = true;
  static const collectMetrics = true;
}
