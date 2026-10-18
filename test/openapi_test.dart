import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  group('buildOpenApi', () {
    test('maps routes, templates params, sets info', () {
      final doc = buildOpenApi(
        const [
          RegisteredRoute(
            method: HttpMethod.get,
            pattern: '/users/:id',
            kind: RouteKind.handler,
          ),
          RegisteredRoute(
            method: HttpMethod.post,
            pattern: '/users',
            kind: RouteKind.handler,
          ),
          RegisteredRoute(
            method: HttpMethod.get,
            pattern: '/files/*',
            kind: RouteKind.staticResponse,
          ),
        ],
        title: 'My API',
        version: '2.0.0',
        description: 'desc',
      );
      expect(doc['openapi'], '3.1.0');
      expect((doc['info'] as Map)['title'], 'My API');
      expect((doc['info'] as Map)['version'], '2.0.0');
      expect((doc['info'] as Map)['description'], 'desc');

      final paths = doc['paths'] as Map<String, Object?>;
      expect(
        paths.keys,
        containsAll(['/users/{id}', '/users', '/files/{wildcard}']),
      );

      final get = (paths['/users/{id}'] as Map)['get'] as Map;
      expect(get['summary'], 'GET /users/:id');
      final params = get['parameters'] as List;
      expect(params, hasLength(1));
      expect((params.first as Map)['name'], 'id');
      expect((params.first as Map)['in'], 'path');

      // POST /users has no path params -> no parameters key.
      expect((paths['/users'] as Map)['post'], isNot(contains('parameters')));

      // staticResponse keeps a 200 described as such.
      final sr = (paths['/files/{wildcard}'] as Map)['get'] as Map;
      expect(
        ((sr['responses'] as Map)['200'] as Map)['description'],
        'Static response',
      );
    });

    test('expands `all`; surfaces WebSocket + custom verbs as additional', () {
      const routes = [
        RegisteredRoute(
          method: HttpMethod.all,
          pattern: '/any',
          kind: RouteKind.handler,
        ),
        RegisteredRoute(
          method: HttpMethod.get,
          pattern: '/ws',
          kind: RouteKind.webSocket,
        ),
        RegisteredRoute(
          method: HttpMethod.custom,
          customMethod: 'REPORT',
          pattern: '/report',
          kind: RouteKind.handler,
        ),
      ];
      final doc = buildOpenApi(routes);
      final paths = doc['paths'] as Map<String, Object?>;
      expect(paths.keys, ['/any']); // only `all` is an operation
      final ops = (paths['/any'] as Map).keys.toSet();
      expect(ops, containsAll(['get', 'post', 'put', 'patch', 'delete']));
      expect(((paths['/any'] as Map)['post'] as Map)['summary'], 'POST /any');

      // Non-operation routes are captured, not dropped.
      final extra = doc['x-additional-routes'] as List;
      expect(extra, contains(equals({'path': '/ws', 'type': 'websocket'})));
      expect(
        extra,
        contains(
          equals({'method': 'REPORT', 'path': '/report', 'type': 'custom'}),
        ),
      );

      // includeNonStandard: false drops them entirely.
      final lean = buildOpenApi(routes, includeNonStandard: false);
      expect(lean.containsKey('x-additional-routes'), isFalse);
    });

    test('empty pattern becomes root path', () {
      final doc = buildOpenApi(const [
        RegisteredRoute(
          method: HttpMethod.get,
          pattern: '',
          kind: RouteKind.handler,
        ),
      ]);
      expect((doc['paths'] as Map).keys, ['/']);
    });

    test('templates multiple params and a param+wildcard mix', () {
      final doc = buildOpenApi(const [
        RegisteredRoute(
          method: HttpMethod.get,
          pattern: '/a/:x/b/:y',
          kind: RouteKind.handler,
        ),
        RegisteredRoute(
          method: HttpMethod.get,
          pattern: '/tree/:root/*',
          kind: RouteKind.handler,
        ),
      ]);
      final paths = doc['paths'] as Map<String, Object?>;
      final p1 = (paths['/a/{x}/b/{y}'] as Map)['get'] as Map;
      expect(
        [for (final p in p1['parameters'] as List) (p as Map)['name']],
        ['x', 'y'],
      );
      final p2 = (paths['/tree/{root}/{wildcard}'] as Map)['get'] as Map;
      expect(
        [for (final p in p2['parameters'] as List) (p as Map)['name']],
        ['root', 'wildcard'],
      );
    });

    test('merges GET and POST on the same path into one item', () {
      final doc = buildOpenApi(const [
        RegisteredRoute(
          method: HttpMethod.get,
          pattern: '/thing',
          kind: RouteKind.handler,
        ),
        RegisteredRoute(
          method: HttpMethod.post,
          pattern: '/thing',
          kind: RouteKind.handler,
        ),
      ]);
      final item = (doc['paths'] as Map)['/thing'] as Map;
      expect(item.keys.toSet(), {'get', 'post'});
    });

    test('body methods get a default JSON requestBody; GET does not', () {
      final doc = buildOpenApi(const [
        RegisteredRoute(
          method: HttpMethod.get,
          pattern: '/a',
          kind: RouteKind.handler,
        ),
        RegisteredRoute(
          method: HttpMethod.post,
          pattern: '/a',
          kind: RouteKind.handler,
        ),
        RegisteredRoute(
          method: HttpMethod.put,
          pattern: '/a',
          kind: RouteKind.handler,
        ),
        RegisteredRoute(
          method: HttpMethod.patch,
          pattern: '/a',
          kind: RouteKind.handler,
        ),
      ]);
      final item = (doc['paths'] as Map)['/a'] as Map;
      expect((item['get'] as Map).containsKey('requestBody'), isFalse);
      for (final m in ['post', 'put', 'patch']) {
        final body = (item[m] as Map)['requestBody'] as Map;
        final schema =
            ((body['content'] as Map)['application/json'] as Map)['schema']
                as Map;
        expect(schema['type'], 'object');
      }
    });

    test('requestExample builds an inferred JSON schema and example', () {
      final doc = buildOpenApi(
        const [
          RegisteredRoute(
            method: HttpMethod.post,
            pattern: '/users',
            kind: RouteKind.handler,
          ),
        ],
        operations: const {
          'POST /users': OpenApiOperation(
            requestExample: {
              'name': 'Ada',
              'age': 36,
              'admin': true,
              'tags': ['x'],
            },
          ),
        },
      );
      final op = ((doc['paths'] as Map)['/users'] as Map)['post'] as Map;
      final json =
          ((op['requestBody'] as Map)['content'] as Map)['application/json']
              as Map;
      expect(json['example'], {
        'name': 'Ada',
        'age': 36,
        'admin': true,
        'tags': ['x'],
      });
      final props = (json['schema'] as Map)['properties'] as Map;
      expect((props['name'] as Map)['type'], 'string');
      expect((props['age'] as Map)['type'], 'integer');
      expect((props['admin'] as Map)['type'], 'boolean');
      expect((props['tags'] as Map)['type'], 'array');
      expect(((props['tags'] as Map)['items'] as Map)['type'], 'string');
    });

    test('an explicit requestBody wins over the auto body', () {
      final doc = buildOpenApi(
        const [
          RegisteredRoute(
            method: HttpMethod.post,
            pattern: '/x',
            kind: RouteKind.handler,
          ),
        ],
        operations: const {
          'POST /x': OpenApiOperation(requestBody: {'required': true}),
        },
      );
      final op = ((doc['paths'] as Map)['/x'] as Map)['post'] as Map;
      expect(op['requestBody'], {'required': true});
    });

    test('inferJsonSchema maps every JSON type', () {
      expect(inferJsonSchema(true), {'type': 'boolean'});
      expect(inferJsonSchema(1), {'type': 'integer'});
      expect(inferJsonSchema(1.5), {'type': 'number'});
      expect(inferJsonSchema('s'), {'type': 'string'});
      expect(inferJsonSchema(const []), {
        'type': 'array',
        'items': <String, Object?>{},
      });
      expect(inferJsonSchema([1]), {
        'type': 'array',
        'items': {'type': 'integer'},
      });
      expect(inferJsonSchema(null), <String, Object?>{});
      expect(inferJsonSchema(const {'a': 's'}), {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
      });
    });

    test('enriches a specific operation and adds servers/security/tags', () {
      final doc = buildOpenApi(
        const [
          RegisteredRoute(
            method: HttpMethod.get,
            pattern: '/users/:id',
            kind: RouteKind.handler,
          ),
        ],
        servers: const [
          OpenApiServer('https://api.example.com', description: 'prod'),
        ],
        securitySchemes: const {
          'bearer': {'type': 'http', 'scheme': 'bearer'},
        },
        security: const [
          {'bearer': <String>[]},
        ],
        tags: const [OpenApiTag('users', description: 'User ops')],
        operations: const {
          'GET /users/:id': OpenApiOperation(
            summary: 'Fetch a user',
            description: 'Returns one user',
            tags: ['users'],
            deprecated: true,
            parameters: [
              {
                'name': 'verbose',
                'in': 'query',
                'schema': {'type': 'boolean'},
              },
            ],
            requestBody: {'required': false},
            responses: {
              '200': {'description': 'the user'},
              '404': {'description': 'missing'},
            },
            security: [
              {'bearer': <String>[]},
            ],
          ),
        },
      );
      expect((doc['servers'] as List).first, {
        'url': 'https://api.example.com',
        'description': 'prod',
      });
      expect(((doc['components'] as Map)['securitySchemes'] as Map)['bearer'], {
        'type': 'http',
        'scheme': 'bearer',
      });
      expect(doc['security'], [
        {'bearer': <String>[]},
      ]);
      expect((doc['tags'] as List).first, {
        'name': 'users',
        'description': 'User ops',
      });

      final op = ((doc['paths'] as Map)['/users/{id}'] as Map)['get'] as Map;
      expect(op['summary'], 'Fetch a user');
      expect(op['description'], 'Returns one user');
      expect(op['tags'], ['users']);
      expect(op['deprecated'], true);
      expect(op['requestBody'], {'required': false});
      expect((op['responses'] as Map).keys, containsAll(['200', '404']));
      expect(op['security'], [
        {'bearer': <String>[]},
      ]);
      // path param + the extra query param, in order.
      final names = [
        for (final p in op['parameters'] as List) (p as Map)['name'],
      ];
      expect(names, ['id', 'verbose']);
    });

    test('server/tag without a description omit the field', () {
      final doc = buildOpenApi(
        const [],
        servers: const [OpenApiServer('http://localhost:8080')],
        tags: const [OpenApiTag('core')],
      );
      expect((doc['servers'] as List).first, {'url': 'http://localhost:8080'});
      expect((doc['tags'] as List).first, {'name': 'core'});
      expect(doc.containsKey('security'), isFalse); // none supplied
      expect(doc.containsKey('components'), isFalse);
    });
  });

  group('serveOpenApi', () {
    late NitroTestClient client;
    setUp(() => NitroTestClient.start().then((c) => client = c));
    tearDown(() => client.close());

    test('serves /openapi.json and a version-pinned Swagger UI page', () async {
      await client.server.get('/ping', (_) => ResponseContext.text('pong'));
      await serveOpenApi(
        client.server,
        title: 'Ping API',
        uiTitle: 'Ping Docs',
        swaggerUiVersion: '5.17.14',
      );

      final spec = await client.get('/openapi.json');
      expect(spec.status, 200);
      expect(spec.headers['content-type'], contains('application/json'));
      final json = spec.json() as Map<String, Object?>;
      expect((json['info'] as Map)['title'], 'Ping API');
      expect((json['paths'] as Map).containsKey('/ping'), isTrue);

      final docs = await client.get('/docs');
      expect(docs.status, 200);
      expect(docs.text(), contains('swagger-ui-dist@5.17.14'));
      expect(docs.text(), contains('Ping Docs'));
      expect(docs.text(), contains('/openapi.json'));
      expect(docs.text(), contains('deepLinking: true'));
      // Swagger UI runtime config: Authorize persists, Try-it-out is open,
      // credentials off by default.
      expect(docs.text(), contains('persistAuthorization: true'));
      expect(docs.text(), contains('tryItOutEnabled: true'));
      expect(docs.text(), contains('withCredentials: false'));
    });

    test('UI config flags are configurable', () async {
      await serveOpenApi(
        client.server,
        persistAuthorization: false,
        tryItOutEnabled: false,
        withCredentials: true,
      );
      final docs = await client.get('/docs');
      expect(docs.text(), contains('persistAuthorization: false'));
      expect(docs.text(), contains('tryItOutEnabled: false'));
      expect(docs.text(), contains('withCredentials: true'));
    });

    test('the Swagger HTML neutralises injection in config values', () async {
      await serveOpenApi(
        client.server,
        path: "/spec</script><x>'.json",
        title: '<script>alert(1)</script>"',
        swaggerUiVersion: '5"><img>',
      );
      final html = (await client.get('/docs')).text();
      // The spec path lands in a JS string: no raw </script> breakout, no raw <.
      expect(html, isNot(contains('/spec</script>')));
      expect(html, contains(r'\x3C'));
      // The title (HTML text) and version (HTML attribute) are escaped.
      expect(html, isNot(contains('<script>alert(1)')));
      expect(html, contains('&lt;script&gt;'));
      expect(html, contains('5&quot;&gt;&lt;img&gt;'));
    });

    test('docsPath null serves only the spec', () async {
      await serveOpenApi(client.server, docsPath: null, path: '/spec.json');
      expect((await client.get('/spec.json')).status, 200);
      expect((await client.get('/docs')).status, 404);
    });

    test(
      'defaults: UI title falls back to the API title, UI pinned to v5',
      () async {
        await serveOpenApi(client.server, title: 'Defaulted');
        final docs = await client.get('/docs');
        expect(docs.status, 200);
        expect(docs.text(), contains('<title>Defaulted</title>'));
        expect(docs.text(), contains('swagger-ui-dist@5/'));
      },
    );
  });

  group('OpenApi (seamless wrapper)', () {
    late NitroTestClient client;
    setUp(() => NitroTestClient.start().then((c) => client = c));
    tearDown(() => client.close());

    test('registers real routes and documents them inline', () async {
      final api = OpenApi(client.server, title: 'Wrapped', version: '9.9');
      await api.get(
        '/users/:id',
        (r) => ResponseContext.text('u${r.param('id')}'),
        doc: const OpenApiOperation(
          summary: 'Fetch a user',
          responses: {
            '200': {'description': 'the user'},
          },
        ),
      );
      await api.post(
        '/users',
        (_) => ResponseContext.text('made', status: 201),
      );
      await api.put('/users/:id', (_) => ResponseContext.text('up'));
      await api.patch('/users/:id', (_) => ResponseContext.text('pa'));
      await api.delete('/users/:id', (_) => ResponseContext.text('del'));
      await api.route(
        HttpMethod.options,
        '/users',
        (_) => ResponseContext.text('opt'),
        doc: const OpenApiOperation(summary: 'Preflight'),
      );

      // The routes actually serve.
      expect((await client.get('/users/7')).text(), 'u7');
      expect((await client.post('/users')).status, 201);

      // document() reflects the inline docs.
      final doc = api.document();
      expect((doc['info'] as Map)['title'], 'Wrapped');
      final getOp = ((doc['paths'] as Map)['/users/{id}'] as Map)['get'] as Map;
      expect(getOp['summary'], 'Fetch a user');
      expect((getOp['responses'] as Map).containsKey('200'), isTrue);
      // Undocumented route gets the auto skeleton.
      final postOp = ((doc['paths'] as Map)['/users'] as Map)['post'] as Map;
      expect(postOp['summary'], 'POST /users');
      final optOp = ((doc['paths'] as Map)['/users'] as Map)['options'] as Map;
      expect(optOp['summary'], 'Preflight');

      // serve() exposes it.
      await api.serve();
      final spec = await client.get('/openapi.json');
      expect(spec.status, 200);
      expect(
        (((spec.json() as Map)['paths'] as Map)['/users/{id}'] as Map)
            .containsKey('get'),
        isTrue,
      );
      expect((await client.get('/docs')).status, 200);
    });
  });

  group('typed params / security / body / responses', () {
    // Builds one operation for `doc` and returns its operation map.
    Map<String, Object?> opFor(
      OpenApiOperation doc, {
      HttpMethod method = HttpMethod.post,
      String pattern = '/x',
    }) {
      final built = buildOpenApi(
        [
          RegisteredRoute(
            method: method,
            pattern: pattern,
            kind: RouteKind.handler,
          ),
        ],
        operations: {'${method.token} $pattern': doc},
      );
      return ((built['paths'] as Map)[pattern] as Map)[method.token
              .toLowerCase()]
          as Map<String, Object?>;
    }

    test('OpenApiParam renders query/header/cookie inputs', () {
      final op = opFor(
        method: HttpMethod.get,
        const OpenApiOperation(
          params: [
            OpenApiParam.query(
              'q',
              required: true,
              description: 'text',
              example: 'ada',
            ),
            OpenApiParam.query('sort', enumValues: ['asc', 'desc']),
            OpenApiParam.header('X-Request-Id', deprecated: true),
            OpenApiParam.cookie('session'),
          ],
        ),
      );
      final params = (op['parameters'] as List).cast<Map<String, Object?>>();
      final q = params.firstWhere((p) => p['name'] == 'q');
      expect(q['in'], 'query');
      expect(q['required'], true);
      expect(q['description'], 'text');
      expect(q['example'], 'ada');
      final sort = params.firstWhere((p) => p['name'] == 'sort');
      expect((sort['schema'] as Map)['enum'], ['asc', 'desc']);
      final h = params.firstWhere((p) => p['name'] == 'X-Request-Id');
      expect(h['in'], 'header');
      expect(h['deprecated'], true);
      expect(h.containsKey('required'), isFalse); // default false omitted
      expect(params.firstWhere((p) => p['name'] == 'session')['in'], 'cookie');
    });

    test(
      'an array (repeatable) query param emits an array schema + explode',
      () {
        final op = opFor(
          method: HttpMethod.get,
          const OpenApiOperation(
            params: [OpenApiParam.query('tag', isArray: true)],
          ),
        );
        final p = (op['parameters'] as List)
            .cast<Map<String, Object?>>()
            .single;
        expect(p['explode'], true);
        expect((p['schema'] as Map)['type'], 'array');
        expect(((p['schema'] as Map)['items'] as Map)['type'], 'string');
      },
    );

    test(
      'requiresAuth builds the security requirement; [] is explicit public',
      () {
        final secured = opFor(const OpenApiOperation(requiresAuth: ['bearer']));
        expect(secured['security'], [
          {'bearer': <String>[]},
        ]);
        final public = opFor(const OpenApiOperation(requiresAuth: []));
        expect(public['security'], <Object?>[]);
      },
    );

    test('raw security wins over requiresAuth', () {
      final op = opFor(
        const OpenApiOperation(
          requiresAuth: ['bearer'],
          security: [
            {'apiKey': <String>[]},
          ],
        ),
      );
      expect(op['security'], [
        {'apiKey': <String>[]},
      ]);
    });

    test('requestBodyDoc covers every media type', () {
      Map<String, Object?> body(OpenApiRequestBody b) =>
          opFor(OpenApiOperation(requestBodyDoc: b))['requestBody']
              as Map<String, Object?>;

      final json = body(
        const OpenApiRequestBody.json(example: {'a': 1}, required: true),
      );
      expect(json['required'], true);
      final jsonMt = (json['content'] as Map)['application/json'] as Map;
      expect((jsonMt['schema'] as Map)['type'], 'object');
      expect(jsonMt['example'], {'a': 1});

      final named = body(
        const OpenApiRequestBody.json(
          examples: {
            'one': {'value': 1},
          },
        ),
      );
      final namedMt = (named['content'] as Map)['application/json'] as Map;
      expect(namedMt.containsKey('examples'), isTrue);
      expect(namedMt.containsKey('example'), isFalse);

      final form = body(const OpenApiRequestBody.form());
      expect(
        (form['content'] as Map).containsKey(
          'application/x-www-form-urlencoded',
        ),
        isTrue,
      );

      final multi = body(
        const OpenApiRequestBody.multipart(
          schema: {'type': 'object'},
          encoding: {'file': <String, Object?>{}},
        ),
      );
      final multiMt = (multi['content'] as Map)['multipart/form-data'] as Map;
      expect(multiMt.containsKey('encoding'), isTrue);

      final text = body(const OpenApiRequestBody.text(example: 'hi'));
      final textMt = (text['content'] as Map)['text/plain'] as Map;
      expect((textMt['schema'] as Map)['type'], 'string');

      final bin = body(const OpenApiRequestBody.binary(required: true));
      final binMt = (bin['content'] as Map)['application/octet-stream'] as Map;
      expect((binMt['schema'] as Map)['format'], 'binary');
    });

    test('request body precedence: raw > doc > example > auto', () {
      final raw = opFor(
        const OpenApiOperation(
          requestBody: {'required': true},
          requestBodyDoc: OpenApiRequestBody.binary(),
          requestExample: {'a': 1},
        ),
      );
      expect(raw['requestBody'], {'required': true});

      final doc = opFor(
        const OpenApiOperation(
          requestBodyDoc: OpenApiRequestBody.text(),
          requestExample: {'a': 1},
        ),
      );
      expect(
        ((doc['requestBody'] as Map)['content'] as Map).containsKey(
          'text/plain',
        ),
        isTrue,
      );
    });

    test('responseExample + description + extraResponses', () {
      final op = opFor(
        const OpenApiOperation(
          responseDescription: 'the thing',
          responseExample: {'id': 1},
          extraResponses: {
            '404': OpenApiResponse('missing', example: {'error': 'no'}),
            '500': OpenApiResponse('boom'),
          },
        ),
      );
      final responses = op['responses'] as Map;
      final ok = responses['200'] as Map;
      expect(ok['description'], 'the thing');
      final okMt = (ok['content'] as Map)['application/json'] as Map;
      expect(okMt['example'], {'id': 1});
      expect((okMt['schema'] as Map)['type'], 'object');
      // 404 carries content; 500 is description-only.
      expect(((responses['404'] as Map)['content'] as Map).isNotEmpty, isTrue);
      expect((responses['500'] as Map).containsKey('content'), isFalse);
    });

    test('successStatus keys the auto response (e.g. 201 for a create)', () {
      final op = opFor(
        const OpenApiOperation(
          successStatus: 201,
          responseExample: {'ok': true},
          extraResponses: {'400': OpenApiResponse('bad')},
        ),
      );
      final responses = op['responses'] as Map;
      expect(responses.containsKey('201'), isTrue);
      expect(responses.containsKey('200'), isFalse);
      expect(responses.containsKey('400'), isTrue);
    });

    test('OpenApiResponse with a named examples map and explicit schema', () {
      const r = OpenApiResponse(
        'ok',
        schema: {'type': 'string'},
        examples: {
          'a': {'value': 'x'},
        },
      );
      final json = r.toJson();
      final mt = (json['content'] as Map)['application/json'] as Map;
      expect((mt['schema'] as Map)['type'], 'string');
      expect(mt.containsKey('examples'), isTrue);
    });

    test('security scheme helpers emit valid objects', () {
      expect(bearerScheme(), {'type': 'http', 'scheme': 'bearer'});
      expect(bearerScheme(bearerFormat: 'JWT'), {
        'type': 'http',
        'scheme': 'bearer',
        'bearerFormat': 'JWT',
      });
      expect(basicScheme(), {'type': 'http', 'scheme': 'basic'});
      expect(apiKeyScheme(), {
        'type': 'apiKey',
        'in': 'header',
        'name': 'x-api-key',
      });
      expect(apiKeyScheme(name: 'token', location: 'query'), {
        'type': 'apiKey',
        'in': 'query',
        'name': 'token',
      });
      expect(oauth2Scheme(const {'implicit': <String, Object?>{}}), {
        'type': 'oauth2',
        'flows': {'implicit': <String, Object?>{}},
      });
      expect(openIdConnectScheme('https://id.example.com/.well-known'), {
        'type': 'openIdConnect',
        'openIdConnectUrl': 'https://id.example.com/.well-known',
      });
      // description rides through on both.
      expect(
        oauth2Scheme(const {
          'implicit': <String, Object?>{},
        }, description: 'd')['description'],
        'd',
      );
      expect(
        openIdConnectScheme(
          'https://x/.well-known',
          description: 'd',
        )['description'],
        'd',
      );
    });

    test('reusable components.schemas + schemaRef', () {
      expect(schemaRef('User'), {r'$ref': '#/components/schemas/User'});
      final doc = buildOpenApi(
        const [
          RegisteredRoute(
            method: HttpMethod.post,
            pattern: '/users',
            kind: RouteKind.handler,
          ),
        ],
        schemas: const {
          'User': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
            },
          },
        },
        operations: {
          'POST /users': OpenApiOperation(
            requestBodyDoc: OpenApiRequestBody.json(schema: schemaRef('User')),
          ),
        },
      );
      expect(
        ((doc['components'] as Map)['schemas'] as Map).containsKey('User'),
        isTrue,
      );
      final body = ((doc['paths'] as Map)['/users'] as Map)['post'] as Map;
      final schema =
          (((body['requestBody'] as Map)['content'] as Map)['application/json']
                  as Map)['schema']
              as Map;
      expect(schema, {r'$ref': '#/components/schemas/User'});
    });
  });
}
