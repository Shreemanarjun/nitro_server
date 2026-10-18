/// OpenAPI 3.1 generation from a server's registered routes, enrichable from
/// code and configurable for good DX.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'context.dart';
import 'http_method.dart';
import 'server.dart';

const _standardMethods = {
  'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS', //
};

/// Methods an `all` (`*`) route is expanded to in the spec (OpenAPI has no
/// wildcard operation).
const _wildcardExpansion = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

/// A server entry for the OpenAPI `servers` list — the base URLs Swagger UI's
/// "Try it out" sends to.
class OpenApiServer {
  const OpenApiServer(this.url, {this.description});
  final String url;
  final String? description;

  Map<String, Object?> toJson() => {
    'url': url,
    if (description != null) 'description': description,
  };
}

/// A tag for grouping operations in the UI.
class OpenApiTag {
  const OpenApiTag(this.name, {this.description});
  final String name;
  final String? description;

  Map<String, Object?> toJson() => {
    'name': name,
    if (description != null) 'description': description,
  };
}

/// Per-operation enrichment layered onto the auto-generated skeleton. Supply it
/// in [buildOpenApi]'s `operations` map keyed by `"<METHOD> <route pattern>"`
/// (the registered pattern, e.g. `"GET /users/:id"`). The common fields are
/// typed; [requestBody]/[responses] take raw OpenAPI objects for full control.
class OpenApiOperation {
  const OpenApiOperation({
    this.summary,
    this.description,
    this.tags = const [],
    this.deprecated = false,
    this.parameters,
    this.requestBody,
    this.requestExample,
    this.responses,
    this.security,
  });

  final String? summary;
  final String? description;
  final List<String> tags;
  final bool deprecated;

  /// Extra parameters (query/header/cookie) appended after the path params.
  final List<Map<String, Object?>>? parameters;

  /// A raw OpenAPI `requestBody` object. Full control; wins over
  /// [requestExample] and the auto body.
  final Map<String, Object?>? requestBody;

  /// A sample JSON request body. Shortcut that builds an `application/json`
  /// [requestBody] with this value as its `example`, so Swagger UI pre-fills
  /// the "Try it out" editor. Ignored when [requestBody] is set.
  final Object? requestExample;

  /// Status code -> raw OpenAPI response object. Replaces the default `200`.
  final Map<String, Map<String, Object?>>? responses;

  /// A raw OpenAPI `security` requirement list for this operation.
  final List<Map<String, Object?>>? security;
}

/// Builds an OpenAPI 3.1 document (JSON-ready map) from [routes], enrichable and
/// configurable from code.
///
/// Each handler/static route becomes a path operation; `:param` and trailing
/// `*` segments become `{param}`/`{wildcard}` path parameters. `all` (`*`)
/// routes expand across the common verbs; WebSocket routes and custom verbs
/// (which OpenAPI cannot express) are omitted.
///
/// Enrich specific operations via [operations] (keyed `"<METHOD> <pattern>"`),
/// declare [servers], reusable [securitySchemes] + a default [security], and
/// [tags]. Everything not supplied is auto-derived, so the result is always a
/// complete map of the API surface and as detailed as you choose to make it.
Map<String, Object?> buildOpenApi(
  List<RegisteredRoute> routes, {
  String title = 'nitro_server',
  String version = '1.0.0',
  String? description,
  List<OpenApiServer> servers = const [],
  Map<String, OpenApiOperation> operations = const {},
  Map<String, Map<String, Object?>> securitySchemes = const {},
  List<Map<String, Object?>> security = const [],
  List<OpenApiTag> tags = const [],
  bool includeNonStandard = true,
}) {
  final paths = <String, Map<String, Object?>>{};
  // Routes OpenAPI operations cannot express (WebSocket, custom verbs). Captured
  // under `x-additional-routes` so the spec still reflects the whole surface.
  final additional = <Map<String, Object?>>[];
  for (final route in routes) {
    final (templated, params) = _templatePath(route.pattern);
    if (route.kind == RouteKind.webSocket) {
      if (includeNonStandard) {
        additional.add({'path': templated, 'type': 'websocket'});
      }
      continue;
    }
    final token = route.methodToken.toUpperCase();
    final methods = token == '*'
        ? _wildcardExpansion
        : (_standardMethods.contains(token) ? [token] : const <String>[]);
    if (methods.isEmpty) {
      // Custom verb: not a standard operation.
      if (includeNonStandard) {
        additional.add({'method': token, 'path': templated, 'type': 'custom'});
      }
      continue;
    }
    final item = paths.putIfAbsent(templated, () => <String, Object?>{});
    for (final method in methods) {
      item[method.toLowerCase()] = _operation(
        method,
        route,
        params,
        operations['$method ${route.pattern}'],
      );
    }
  }

  final info = <String, Object?>{'title': title, 'version': version};
  if (description != null) info['description'] = description;
  final doc = <String, Object?>{'openapi': '3.1.0', 'info': info};
  if (servers.isNotEmpty) {
    doc['servers'] = [for (final s in servers) s.toJson()];
  }
  doc['paths'] = paths;
  if (securitySchemes.isNotEmpty) {
    doc['components'] = {'securitySchemes': securitySchemes};
  }
  if (security.isNotEmpty) doc['security'] = security;
  if (tags.isNotEmpty) doc['tags'] = [for (final t in tags) t.toJson()];
  if (additional.isNotEmpty) doc['x-additional-routes'] = additional;
  return doc;
}

/// Methods that carry a request body, so Swagger UI should offer a body input.
const _bodyMethods = {'POST', 'PUT', 'PATCH'};

/// Infers an OpenAPI 3.1 schema from a sample JSON [value] — so a
/// `requestExample` or any JSON sample becomes a typed schema automatically.
/// Objects map each key to its value's schema; arrays take the first element's
/// schema (empty array → any item); `null`/unknown → any (`{}`). Exported for
/// building schemas by hand too.
Map<String, Object?> inferJsonSchema(Object? value) {
  if (value is bool) return const {'type': 'boolean'};
  if (value is int) return const {'type': 'integer'};
  if (value is num) return const {'type': 'number'};
  if (value is String) return const {'type': 'string'};
  if (value is List) {
    return {
      'type': 'array',
      'items': value.isEmpty
          ? const <String, Object?>{}
          : inferJsonSchema(value.first),
    };
  }
  if (value is Map) {
    return {
      'type': 'object',
      'properties': {
        for (final e in value.entries) '${e.key}': inferJsonSchema(e.value),
      },
    };
  }
  return const {}; // null or an unsupported type: any
}

/// An `application/json` request body. Freeform object by default (Swagger
/// shows an editable JSON field); with [example] the editor is pre-filled.
Map<String, Object?> _jsonRequestBody({Object? example}) => {
  'required': false,
  'content': {
    'application/json': {
      'schema': example != null
          ? inferJsonSchema(example)
          : const {'type': 'object', 'additionalProperties': true},
      'example': ?example,
    },
  },
};

/// One operation object: the auto skeleton (summary, path params, `200`) with
/// [extra] enrichment layered on top (supplied fields win).
Map<String, Object?> _operation(
  String method,
  RegisteredRoute route,
  List<String> pathParams,
  OpenApiOperation? extra,
) {
  final parameters = <Map<String, Object?>>[
    for (final p in pathParams)
      {
        'name': p,
        'in': 'path',
        'required': true,
        'schema': {'type': 'string'},
      },
  ];
  if (extra?.parameters != null) parameters.addAll(extra!.parameters!);

  final op = <String, Object?>{
    'summary': extra?.summary ?? '$method ${route.pattern}',
  };
  if (extra?.description != null) op['description'] = extra!.description;
  if (extra != null && extra.tags.isNotEmpty) op['tags'] = extra.tags;
  if (extra?.deprecated ?? false) op['deprecated'] = true;
  if (parameters.isNotEmpty) op['parameters'] = parameters;
  // Body-bearing methods always get a requestBody so Swagger UI shows a body
  // input, even when the route described none. An explicit `requestBody` wins;
  // a `requestExample` builds a JSON body pre-filled with that sample; else a
  // body method falls back to a freeform JSON object.
  final requestBody =
      extra?.requestBody ??
      (extra?.requestExample != null
          ? _jsonRequestBody(example: extra!.requestExample)
          : (_bodyMethods.contains(method) ? _jsonRequestBody() : null));
  if (requestBody != null) op['requestBody'] = requestBody;
  if (extra?.security != null) op['security'] = extra!.security;
  op['responses'] =
      extra?.responses ??
      {
        '200': {
          'description': route.kind == RouteKind.staticResponse
              ? 'Static response'
              : 'OK',
        },
      };
  return op;
}

/// Same as [buildOpenApi], reading [server]'s current route snapshot.
Map<String, Object?> openApiDocument(
  NitroServer server, {
  String title = 'nitro_server',
  String version = '1.0.0',
  String? description,
  List<OpenApiServer> servers = const [],
  Map<String, OpenApiOperation> operations = const {},
  Map<String, Map<String, Object?>> securitySchemes = const {},
  List<Map<String, Object?>> security = const [],
  List<OpenApiTag> tags = const [],
  bool includeNonStandard = true,
}) => buildOpenApi(
  server.routes,
  title: title,
  version: version,
  description: description,
  servers: servers,
  operations: operations,
  securitySchemes: securitySchemes,
  security: security,
  tags: tags,
  includeNonStandard: includeNonStandard,
);

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
  List<Map<String, Object?>> security = const [],
  List<OpenApiTag> tags = const [],
  bool includeNonStandard = true,
  String swaggerUiVersion = '5',
  String? uiTitle,
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
    final page = _swaggerHtml(uiTitle ?? title, path, swaggerUiVersion);
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
    this.security = const [],
    this.tags = const [],
    this.includeNonStandard = true,
    this.swaggerUiVersion = '5',
  });

  final NitroServer server;
  final String title;
  final String version;
  final String? description;
  final List<OpenApiServer> servers;
  final Map<String, Map<String, Object?>> securitySchemes;
  final List<Map<String, Object?>> security;
  final List<OpenApiTag> tags;
  final bool includeNonStandard;
  final String swaggerUiVersion;

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
    security: security,
    tags: tags,
    includeNonStandard: includeNonStandard,
    swaggerUiVersion: swaggerUiVersion,
    uiTitle: uiTitle,
  );
}

/// Converts a nitro route pattern to an OpenAPI path template and the ordered
/// list of path-parameter names. `:id` -> `{id}`; a trailing `*` -> `{wildcard}`.
(String, List<String>) _templatePath(String pattern) {
  if (pattern.isEmpty) return ('/', const []);
  final params = <String>[];
  final segments = pattern.split('/').map((seg) {
    if (seg.startsWith(':')) {
      final name = seg.substring(1);
      params.add(name);
      return '{$name}';
    }
    if (seg == '*') {
      params.add('wildcard');
      return '{wildcard}';
    }
    return seg;
  });
  final joined = segments.join('/');
  return (joined.isEmpty ? '/' : joined, params);
}

String _swaggerHtml(String title, String specPath, String uiVersion) {
  final base = 'https://unpkg.com/swagger-ui-dist@${_jsString(uiVersion)}';
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
    });
  </script>
</body>
</html>
''';
}

String _htmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _jsString(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
