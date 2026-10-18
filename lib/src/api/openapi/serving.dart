/// Serving the OpenAPI document: [serveOpenApi] mounts `/openapi.json` + a
/// Swagger UI page, and the [OpenApi] wrapper captures per-route docs inline.
/// Part of the `openapi.dart` library.
part of '../openapi.dart';

/// Serves the OpenAPI document at [path] (`/openapi.json`) and, unless
/// [docsPath] is null, a Swagger UI page at [docsPath] (`/docs`) that loads it.
/// The spec is generated once from the routes registered when this is called,
/// so register routes first (and call it again after a `reload`). All of
/// [buildOpenApi]'s enrichment/config is forwarded.
///
/// Swagger UI assets load from a version-pinned unpkg CDN ([swaggerUiVersion],
/// default `5`); [uiTitle] overrides the page title.
///
/// ```dart
/// await setup(server);
/// await serveOpenApi(
///   server,
///   title: 'My API',
///   servers: const [OpenApiServer('https://api.example.com')],
///   operations: const {
///     'GET /users/:id': OpenApiOperation(summary: 'Fetch a user'),
///   },
/// );
/// ```
Future<void> serveOpenApi(
  NitroServer server, {
  String path = '/openapi.json',
  String? docsPath = '/docs',
  String title = 'nitro_server',
  String version = '1.0.0',
  String? description,
  List<OpenApiServer> servers = const [],
  Map<String, OpenApiOperation> operations = const {},
  Map<String, Map<String, Object?>> securitySchemes = const {},
  Map<String, Map<String, Object?>> schemas = const {},
  List<Map<String, Object?>> security = const [],
  List<OpenApiTag> tags = const [],
  bool includeNonStandard = true,
  String swaggerUiVersion = '5',
  String? uiTitle,
  bool persistAuthorization = true,
  bool tryItOutEnabled = true,
  bool withCredentials = false,
}) async {
  final doc = utf8.encode(
    jsonEncode(
      openApiDocument(
        server,
        title: title,
        version: version,
        description: description,
        servers: servers,
        operations: operations,
        securitySchemes: securitySchemes,
        schemas: schemas,
        security: security,
        tags: tags,
        includeNonStandard: includeNonStandard,
      ),
    ),
  );
  await server.get(
    path,
    (_) => ResponseContext(
      headers: const {'content-type': 'application/json; charset=utf-8'},
      body: Uint8List.fromList(doc),
    ),
  );
  if (docsPath != null) {
    final page = _swaggerHtml(
      uiTitle ?? title,
      path,
      swaggerUiVersion,
      persistAuthorization: persistAuthorization,
      tryItOutEnabled: tryItOutEnabled,
      withCredentials: withCredentials,
    );
    await server.get(docsPath, (_) => ResponseContext.html(page));
  }
}

/// Seamless OpenAPI: a thin wrapper over a [NitroServer] whose verb shorthands
/// register the route **and** capture its OpenAPI metadata inline, so the spec
/// comes straight from where routes are declared — no separate, string-keyed
/// specification to keep in sync.
///
/// ```dart
/// final api = OpenApi(server, title: 'My API');
/// await api.get(
///   '/users/:id',
///   getUser,
///   doc: const OpenApiOperation(summary: 'Fetch a user'),
/// );
/// await api.post('/users', createUser); // documented with the auto skeleton
/// await api.serve(); // /openapi.json + Swagger UI at /docs
/// ```
///
/// Routes registered directly on the server still appear (auto-generated); only
/// the inline `doc:` enriches them. Use the plain [serveOpenApi]/[buildOpenApi]
/// for full manual control.
class OpenApi {
  OpenApi(
    this.server, {
    this.title = 'nitro_server',
    this.version = '1.0.0',
    this.description,
    this.servers = const [],
    this.securitySchemes = const {},
    this.schemas = const {},
    this.security = const [],
    this.tags = const [],
    this.includeNonStandard = true,
    this.swaggerUiVersion = '5',
    this.persistAuthorization = true,
    this.tryItOutEnabled = true,
    this.withCredentials = false,
  });

  final NitroServer server;
  final String title;
  final String version;
  final String? description;
  final List<OpenApiServer> servers;
  final Map<String, Map<String, Object?>> securitySchemes;

  /// Reusable `components.schemas` referenced via [schemaRef].
  final Map<String, Map<String, Object?>> schemas;
  final List<Map<String, Object?>> security;
  final List<OpenApiTag> tags;
  final bool includeNonStandard;
  final String swaggerUiVersion;

  /// Swagger UI: keep the Authorize token across reloads.
  final bool persistAuthorization;

  /// Swagger UI: open every operation's "Try it out" by default.
  final bool tryItOutEnabled;

  /// Swagger UI: send credentials (cookies) on Try-it-out — needs a concrete
  /// CORS `allowOrigin` + `allowCredentials` on the server, not `*`.
  final bool withCredentials;

  final Map<String, OpenApiOperation> _operations = {};

  /// General form: registers [method]+[pattern] on the server and records [doc].
  Future<void> route(
    HttpMethod method,
    String pattern,
    RequestHandler handler, {
    OpenApiOperation? doc,
    Duration? timeout,
    String customMethod = '',
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) async {
    if (doc != null) {
      final token = (method == HttpMethod.custom ? customMethod : method.token)
          .toUpperCase();
      _operations['$token $pattern'] = doc;
    }
    await server.route(
      method,
      pattern,
      handler,
      timeout: timeout,
      customMethod: customMethod,
      middleware: middleware,
      streamBody: streamBody,
      maxBodyBytes: maxBodyBytes,
    );
  }

  Future<void> get(
    String pattern,
    RequestHandler handler, {
    OpenApiOperation? doc,
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.get,
    pattern,
    handler,
    doc: doc,
    timeout: timeout,
    middleware: middleware,
  );

  Future<void> post(
    String pattern,
    RequestHandler handler, {
    OpenApiOperation? doc,
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.post,
    pattern,
    handler,
    doc: doc,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  Future<void> put(
    String pattern,
    RequestHandler handler, {
    OpenApiOperation? doc,
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.put,
    pattern,
    handler,
    doc: doc,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  Future<void> patch(
    String pattern,
    RequestHandler handler, {
    OpenApiOperation? doc,
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.patch,
    pattern,
    handler,
    doc: doc,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  Future<void> delete(
    String pattern,
    RequestHandler handler, {
    OpenApiOperation? doc,
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.delete,
    pattern,
    handler,
    doc: doc,
    timeout: timeout,
    middleware: middleware,
  );

  /// The assembled OpenAPI document from the server's routes plus the inline
  /// docs captured so far.
  Map<String, Object?> document() => buildOpenApi(
    server.routes,
    title: title,
    version: version,
    description: description,
    servers: servers,
    operations: _operations,
    securitySchemes: securitySchemes,
    schemas: schemas,
    security: security,
    tags: tags,
    includeNonStandard: includeNonStandard,
  );

  /// Serves the document at [path] (`/openapi.json`) and Swagger UI at
  /// [docsPath] (`/docs`). Call after registering routes.
  Future<void> serve({
    String path = '/openapi.json',
    String? docsPath = '/docs',
    String? uiTitle,
  }) => serveOpenApi(
    server,
    path: path,
    docsPath: docsPath,
    title: title,
    version: version,
    description: description,
    servers: servers,
    operations: _operations,
    securitySchemes: securitySchemes,
    schemas: schemas,
    security: security,
    tags: tags,
    includeNonStandard: includeNonStandard,
    swaggerUiVersion: swaggerUiVersion,
    uiTitle: uiTitle,
    persistAuthorization: persistAuthorization,
    tryItOutEnabled: tryItOutEnabled,
    withCredentials: withCredentials,
  );
}

String _swaggerHtml(
  String title,
  String specPath,
  String uiVersion, {
  required bool persistAuthorization,
  required bool tryItOutEnabled,
  required bool withCredentials,
}) {
  // uiVersion lands in HTML attribute context (href/src) — HTML-escape it, not
  // JS-escape it.
  final base = 'https://unpkg.com/swagger-ui-dist@${_htmlEscape(uiVersion)}';
  return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>${_htmlEscape(title)}</title>
  <link rel="stylesheet" href="$base/swagger-ui.css"/>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="$base/swagger-ui-bundle.js"></script>
  <script>
    window.onload = () => SwaggerUIBundle({
      url: '${_jsString(specPath)}',
      dom_id: '#swagger-ui',
      deepLinking: true,
      persistAuthorization: $persistAuthorization,
      tryItOutEnabled: $tryItOutEnabled,
      withCredentials: $withCredentials,
    });
  </script>
</body>
</html>
''';
}

/// Escapes for HTML text AND double-quoted attribute contexts: the five
/// significant characters so an injected value can neither open a tag nor
/// close an attribute.
String _htmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// Escapes a value for a single-quoted JS string literal inside an inline
/// `<script>`: quote/backslash, line terminators (incl. U+2028/U+2029), and —
/// crucially — `<` as `\x3C` so a `</script>` sequence cannot end the element
/// at the HTML-parser level (which ignores JS quoting).
String _jsString(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll('<', r'\x3C')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');
