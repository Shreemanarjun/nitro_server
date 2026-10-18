/// OpenAPI value types: the typed building blocks you pass to
/// [OpenApiOperation] / [buildOpenApi] / [OpenApi] — servers, tags, params,
/// request/response bodies, and the security-scheme helpers. Part of the
/// `openapi.dart` library so these stay a cohesive public surface while the
/// generation and serving logic live in their own files.
part of '../openapi.dart';

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
    this.params,
    this.parameters,
    this.requestBody,
    this.requestBodyDoc,
    this.requestExample,
    this.responses,
    this.responseExample,
    this.responseDescription,
    this.successStatus = 200,
    this.extraResponses,
    this.security,
    this.requiresAuth,
  });

  final String? summary;
  final String? description;
  final List<String> tags;
  final bool deprecated;

  /// Typed query/header/cookie parameters (see [OpenApiParam]) — the ergonomic
  /// way to get Swagger to render inputs. Appended after the path params.
  final List<OpenApiParam>? params;

  /// Raw OpenAPI parameter objects, appended after [params]. Escape hatch for
  /// shapes [OpenApiParam] does not cover.
  final List<Map<String, Object?>>? parameters;

  /// A raw OpenAPI `requestBody` object. Full control; wins over
  /// [requestBodyDoc], [requestExample] and the auto body.
  final Map<String, Object?>? requestBody;

  /// A typed request body (JSON/form/multipart/text/binary — see
  /// [OpenApiRequestBody]) so Swagger shows the right input. Wins over
  /// [requestExample] and the auto body; loses to the raw [requestBody].
  final OpenApiRequestBody? requestBodyDoc;

  /// A sample JSON request body. Shortcut that builds an `application/json`
  /// body with this value as its `example`, so Swagger UI pre-fills the "Try
  /// it out" editor. Ignored when [requestBody]/[requestBodyDoc] is set.
  final Object? requestExample;

  /// Status code -> raw OpenAPI response object. Replaces the default `200`
  /// entirely (including any [responseExample]/[extraResponses]).
  final Map<String, Map<String, Object?>>? responses;

  /// A sample success (`200`) response body; builds that response's
  /// `application/json` content + inferred schema so Swagger shows a model.
  final Object? responseExample;

  /// Overrides the default `200` description (`'OK'`).
  final String? responseDescription;

  /// The success status code the auto response is keyed under (default `200`).
  /// Set to `201` for a create, `202`, etc. so the documented success matches
  /// what the handler returns.
  final int successStatus;

  /// Extra status codes (see [OpenApiResponse]) merged onto the auto `200` —
  /// e.g. a `404`/`400` without hand-writing the success response.
  final Map<String, OpenApiResponse>? extraResponses;

  /// A raw OpenAPI `security` requirement list for this operation. Wins over
  /// [requiresAuth].
  final List<Map<String, Object?>>? security;

  /// Scheme names this operation requires (empty scopes): builds `security` as
  /// `[{name: []}, …]`. `requiresAuth: const []` marks the operation
  /// explicitly public, overriding a global default. Ignored when [security]
  /// is set.
  final List<String>? requiresAuth;
}

/// A typed request parameter — query string, header, or cookie — so Swagger UI
/// renders a labelled input and sends it on "Try it out". Use the named
/// constructors; pass a list in [OpenApiOperation.params].
///
/// Model an auth credential (`Authorization`, an API key) as a security scheme
/// (see [bearerScheme]/[apiKeyScheme]/[basicScheme]) rather than a header
/// param — Swagger ignores an `Authorization` header parameter by spec.
class OpenApiParam {
  const OpenApiParam.query(
    this.name, {
    this.required = false,
    this.schema = const {'type': 'string'},
    this.description,
    this.example,
    this.enumValues,
    this.deprecated = false,
    this.isArray = false,
  }) : location = 'query';
  const OpenApiParam.header(
    this.name, {
    this.required = false,
    this.schema = const {'type': 'string'},
    this.description,
    this.example,
    this.enumValues,
    this.deprecated = false,
    this.isArray = false,
  }) : location = 'header';

  /// A cookie parameter. Note: Swagger UI's browser-based "Try it out" cannot
  /// set the `Cookie` header from this field (fetch forbids it) — it only
  /// rides an existing jar cookie when `withCredentials` is on. The field still
  /// documents the contract; see [OpenApi]/`serveOpenApi`'s `withCredentials`.
  const OpenApiParam.cookie(
    this.name, {
    this.required = false,
    this.schema = const {'type': 'string'},
    this.description,
    this.example,
    this.enumValues,
    this.deprecated = false,
    this.isArray = false,
  }) : location = 'cookie';

  final String name;

  /// `query`, `header` or `cookie`.
  final String location;
  final bool required;
  final Map<String, Object?> schema;
  final String? description;
  final Object? example;

  /// Allowed values — emitted as the schema's `enum`.
  final List<Object?>? enumValues;
  final bool deprecated;

  /// Repeatable (`?tag=a&tag=b`): wraps [schema] in an array with `explode:true`
  /// so Swagger renders an add-item input and sends every value. Pair with
  /// `RequestContext.queryParamAll` on the handler side.
  final bool isArray;

  Map<String, Object?> toJson() {
    final item = enumValues == null ? schema : {...schema, 'enum': enumValues};
    return {
      'name': name,
      'in': location,
      if (required) 'required': true,
      if (deprecated) 'deprecated': true,
      if (isArray) 'explode': true,
      if (description != null) 'description': description,
      'schema': isArray ? {'type': 'array', 'items': item} : item,
      'example': ?example,
    };
  }
}

/// A typed request body for one media type, so Swagger renders the right input
/// — a JSON editor, URL-encoded/multipart form fields, a file picker, or a
/// plain textarea. Use the named constructors; pass it in
/// [OpenApiOperation.requestBodyDoc].
class OpenApiRequestBody {
  /// `application/json`. [schema] overrides the schema inferred from [example].
  const OpenApiRequestBody.json({
    this.schema,
    this.example,
    this.examples,
    this.required = false,
  }) : mediaType = 'application/json',
       encoding = null;

  /// `application/x-www-form-urlencoded` — Swagger renders per-field inputs.
  const OpenApiRequestBody.form({
    this.schema,
    this.example,
    this.required = false,
  }) : mediaType = 'application/x-www-form-urlencoded',
       examples = null,
       encoding = null;

  /// `multipart/form-data` — set `format: binary` on file fields in [schema]
  /// (and optionally [encoding]) for a file picker.
  const OpenApiRequestBody.multipart({
    this.schema,
    this.example,
    this.required = false,
    this.encoding,
  }) : mediaType = 'multipart/form-data',
       examples = null;

  /// `text/plain` — a plain textarea.
  const OpenApiRequestBody.text({this.example, this.required = false})
    : mediaType = 'text/plain',
      schema = const {'type': 'string'},
      examples = null,
      encoding = null;

  /// `application/octet-stream` — a raw/binary file input.
  const OpenApiRequestBody.binary({this.required = false})
    : mediaType = 'application/octet-stream',
      schema = const {'type': 'string', 'format': 'binary'},
      example = null,
      examples = null,
      encoding = null;

  final String mediaType;
  final Map<String, Object?>? schema;
  final Object? example;

  /// Named examples (`{name: {value, summary?}}`) — a dropdown in Swagger.
  /// Takes precedence over [example].
  final Map<String, Object?>? examples;
  final bool required;
  final Map<String, Object?>? encoding;

  Map<String, Object?> toJson() {
    final content = <String, Object?>{
      'schema':
          schema ??
          (example != null
              ? inferJsonSchema(example)
              : const {'type': 'object', 'additionalProperties': true}),
      if (encoding != null) 'encoding': encoding,
    };
    if (examples != null) {
      content['examples'] = examples;
    } else if (example != null) {
      content['example'] = example;
    }
    return {
      'required': required,
      'content': {mediaType: content},
    };
  }
}

/// A typed response for one status code, so Swagger shows a response model and
/// sample. Pass in [OpenApiOperation.extraResponses].
class OpenApiResponse {
  const OpenApiResponse(
    this.description, {
    this.example,
    this.schema,
    this.examples,
    this.mediaType = 'application/json',
  });

  final String description;
  final Object? example;
  final Map<String, Object?>? schema;
  final Map<String, Object?>? examples;
  final String mediaType;

  Map<String, Object?> toJson() {
    if (example == null && schema == null && examples == null) {
      return {'description': description};
    }
    final content = <String, Object?>{
      'schema':
          schema ??
          (example != null
              ? inferJsonSchema(example)
              : const <String, Object?>{}),
    };
    if (examples != null) {
      content['examples'] = examples;
    } else if (example != null) {
      content['example'] = example;
    }
    return {
      'description': description,
      'content': {mediaType: content},
    };
  }
}

/// A `{type: http, scheme: bearer}` security scheme (e.g. JWT). Declare it in
/// `securitySchemes` and require it per-operation with
/// [OpenApiOperation.requiresAuth]; Swagger then shows "Authorize" and sends
/// `Authorization: Bearer <token>`.
Map<String, Object?> bearerScheme({String? bearerFormat}) => {
  'type': 'http',
  'scheme': 'bearer',
  'bearerFormat': ?bearerFormat,
};

/// A `{type: http, scheme: basic}` security scheme — Swagger shows a
/// username/password dialog and sends `Authorization: Basic …`.
Map<String, Object?> basicScheme() => const {'type': 'http', 'scheme': 'basic'};

/// A `{type: apiKey, in: <location>, name: <name>}` security scheme. [location]
/// is `header` (default), `query` or `cookie`; keep [name] in sync with the
/// `apiKeyAuth` middleware's header name.
Map<String, Object?> apiKeyScheme({
  String name = 'x-api-key',
  String location = 'header',
}) => {'type': 'apiKey', 'in': location, 'name': name};

/// An OAuth2 security scheme. [flows] is the raw OpenAPI `flows` object, e.g.
/// `{'authorizationCode': {'authorizationUrl': …, 'tokenUrl': …, 'scopes': {…}}}`.
/// Swagger's Authorize dialog drives the chosen flow.
Map<String, Object?> oauth2Scheme(
  Map<String, Object?> flows, {
  String? description,
}) => {'type': 'oauth2', 'flows': flows, 'description': ?description};

/// An OpenID Connect security scheme pointing at the discovery document
/// [openIdConnectUrl].
Map<String, Object?> openIdConnectScheme(
  String openIdConnectUrl, {
  String? description,
}) => {
  'type': 'openIdConnect',
  'openIdConnectUrl': openIdConnectUrl,
  'description': ?description,
};

/// A JSON-Schema `$ref` to a reusable schema registered under
/// `components.schemas[name]` (pass it in `buildOpenApi`/`OpenApi`'s `schemas`).
/// Use it as the `schema:` of an [OpenApiRequestBody]/[OpenApiResponse] or
/// [OpenApiParam] to share one definition across operations.
Map<String, Object?> schemaRef(String name) => {
  r'$ref': '#/components/schemas/$name',
};
