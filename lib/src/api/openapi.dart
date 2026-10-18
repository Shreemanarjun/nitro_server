/// OpenAPI 3.1 generation from a server's registered routes, enrichable from
/// code and configurable for good DX.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'context.dart';
import 'http_method.dart';
import 'server.dart';

part 'openapi/models.dart';
part 'openapi/serving.dart';

const _standardMethods = {
  'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS', //
};

/// Methods an `all` (`*`) route is expanded to in the spec (OpenAPI has no
/// wildcard operation).
const _wildcardExpansion = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

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
  Map<String, Map<String, Object?>> schemas = const {},
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
  final components = <String, Object?>{
    if (securitySchemes.isNotEmpty) 'securitySchemes': securitySchemes,
    if (schemas.isNotEmpty) 'schemas': schemas,
  };
  if (components.isNotEmpty) doc['components'] = components;
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
    if (extra?.params != null)
      for (final p in extra!.params!) p.toJson(),
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
  // input, even when the route described none. Precedence: a raw `requestBody`
  // wins, then a typed `requestBodyDoc`, then a `requestExample` (freeform
  // JSON pre-filled with the sample), else a body method falls back to a
  // freeform JSON object.
  final requestBody =
      extra?.requestBody ??
      extra?.requestBodyDoc?.toJson() ??
      (extra?.requestExample != null
          ? _jsonRequestBody(example: extra!.requestExample)
          : (_bodyMethods.contains(method) ? _jsonRequestBody() : null));
  if (requestBody != null) op['requestBody'] = requestBody;
  // Security: a raw `security` wins; else `requiresAuth` synthesises the
  // requirement list (empty list → explicitly public).
  if (extra?.security != null) {
    op['security'] = extra!.security;
  } else if (extra?.requiresAuth != null) {
    op['security'] = [
      for (final s in extra!.requiresAuth!) {s: const <String>[]},
    ];
  }
  // Responses: a raw `responses` map fully replaces the default; otherwise the
  // auto 200 (with an optional inferred example) is merged with any
  // `extraResponses`.
  if (extra?.responses != null) {
    op['responses'] = extra!.responses;
  } else {
    final ok = <String, Object?>{
      'description':
          extra?.responseDescription ??
          (route.kind == RouteKind.staticResponse ? 'Static response' : 'OK'),
    };
    if (extra?.responseExample != null) {
      ok['content'] = {
        'application/json': {
          'schema': inferJsonSchema(extra!.responseExample),
          'example': extra.responseExample,
        },
      };
    }
    final responses = <String, Object?>{'${extra?.successStatus ?? 200}': ok};
    if (extra?.extraResponses != null) {
      for (final e in extra!.extraResponses!.entries) {
        responses[e.key] = e.value.toJson();
      }
    }
    op['responses'] = responses;
  }
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
  Map<String, Map<String, Object?>> schemas = const {},
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
  schemas: schemas,
  security: security,
  tags: tags,
  includeNonStandard: includeNonStandard,
);

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
