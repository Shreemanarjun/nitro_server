// ApiSchema: the typed builder that is both an OpenAPI schema and a runtime
// validator, and the validateJsonBody middleware that enforces it.
import 'dart:convert';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

const _user = ApiSchema.object(
  {
    'name': ApiSchema.string(),
    'email': ApiSchema.string(format: 'email'),
    'age': ApiSchema.integer(nullable: true),
    'role': ApiSchema.string(enumValues: ['admin', 'user']),
    'tags': ApiSchema.array(ApiSchema.string()),
  },
  required: ['name', 'email'],
);

void main() {
  group('ApiSchema.toJson', () {
    test('object with properties, required, nested array and enum', () {
      final json = _user.toJson();
      expect(json['type'], 'object');
      expect(json['required'], ['name', 'email']);
      final props = json['properties'] as Map;
      expect((props['name'] as Map)['type'], 'string');
      expect((props['email'] as Map)['format'], 'email');
      // nullable integer → type is [integer, null].
      expect((props['age'] as Map)['type'], ['integer', 'null']);
      expect((props['role'] as Map)['enum'], ['admin', 'user']);
      expect((props['tags'] as Map)['type'], 'array');
      expect(((props['tags'] as Map)['items'] as Map)['type'], 'string');
    });

    test('scalars, ref, additionalProperties:false', () {
      expect(const ApiSchema.number().toJson()['type'], 'number');
      expect(const ApiSchema.boolean().toJson()['type'], 'boolean');
      expect(const ApiSchema.ref('User').toJson(), {
        r'$ref': '#/components/schemas/User',
      });
      final closed = const ApiSchema.object({
        'a': ApiSchema.string(),
      }, additionalProperties: false).toJson();
      expect(closed['additionalProperties'], false);
    });
  });

  group('ApiSchema.validate', () {
    test('accepts a valid object', () {
      expect(
        _user.validate({
          'name': 'Ada',
          'email': 'a@b.c',
          'age': null,
          'role': 'admin',
          'tags': ['x', 'y'],
        }),
        isEmpty,
      );
    });

    test('reports every violation with a path', () {
      final errors = _user.validate({
        'email': 123, // wrong type
        'age': 'old', // wrong type
        'role': 'root', // not in enum
        'tags': ['ok', 7], // element wrong type
      });
      expect(errors, contains(matches(r'name: required')));
      expect(errors, contains(matches(r'\.email: expected string')));
      expect(errors, contains(matches(r'\.age: expected integer')));
      expect(errors, contains(matches(r'role.*not in')));
      expect(errors, contains(matches(r'tags\[1\]: expected string')));
    });

    test('nullable allows null; non-nullable rejects it', () {
      expect(const ApiSchema.integer(nullable: true).validate(null), isEmpty);
      expect(const ApiSchema.integer().validate(null), isNotEmpty);
    });

    test('type mismatches at the top level', () {
      expect(const ApiSchema.object({}).validate('nope'), isNotEmpty);
      expect(const ApiSchema.array(ApiSchema.string()).validate(1), isNotEmpty);
      expect(const ApiSchema.boolean().validate('t'), isNotEmpty);
      expect(const ApiSchema.number().validate('n'), isNotEmpty);
    });

    test('additionalProperties:false rejects unknown keys', () {
      const closed = ApiSchema.object({
        'a': ApiSchema.string(),
      }, additionalProperties: false);
      expect(closed.validate({'a': 'x', 'b': 'y'}), isNotEmpty);
      expect(closed.validate({'a': 'x'}), isEmpty);
    });

    test('a ref validates as any', () {
      expect(const ApiSchema.ref('X').validate({'anything': 1}), isEmpty);
    });
  });

  group('validateJsonBody error cap', () {
    test(
      'a body with thousands of violations answers a bounded list',
      () async {
        final client = await NitroTestClient.start();
        addTearDown(client.close);
        const schema = ApiSchema.array(ApiSchema.integer());
        await client.server.post(
          '/n',
          (_) => ResponseContext.text('ok'),
          middleware: [validateJsonBody(schema, maxErrors: 5)],
        );
        final res = await client.post(
          '/n',
          body: utf8.encode(jsonEncode(List.filled(1000, 'x'))),
          headers: const {'content-type': 'application/json'},
        );
        expect(res.status, 422);
        final errors = (res.json() as Map)['errors'] as List;
        expect(errors, hasLength(6));
        expect(errors.last, '… 995 more error(s) omitted');
        // Deep nesting cannot blow the stack: dart:convert parses iteratively.
        final deep = '${'[' * 100000}${']' * 100000}';
        final nested = await client.post(
          '/n',
          body: utf8.encode(deep),
          headers: const {'content-type': 'application/json'},
        );
        expect(nested.status, 422); // an array of arrays, not integers
      },
    );
  });

  group('validateJsonBody middleware', () {
    late NitroTestClient client;
    setUp(() => NitroTestClient.start().then((c) => client = c));
    tearDown(() => client.close());

    test(
      'passes a valid body, 422s an invalid one, 400s malformed JSON',
      () async {
        await client.server.post(
          '/users',
          (r) => ResponseContext.jsonBody({'ok': true}),
          middleware: [validateJsonBody(_user)],
        );
        // Valid.
        final ok = await client.post(
          '/users',
          body: {'name': 'Ada', 'email': 'a@b.c'},
        );
        expect(ok.status, 200);
        // Schema violation → 422 problem+json with errors.
        final bad = await client.post('/users', body: {'name': 'Ada'});
        expect(bad.status, 422);
        expect(
          bad.headers['content-type'],
          contains('application/problem+json'),
        );
        final body = jsonDecode(bad.text()) as Map<String, Object?>;
        expect(body['errors'], isA<List<Object?>>());
        // Malformed JSON → 400.
        final malformed = await client.post('/users', body: 'not json');
        expect(malformed.status, 400);
      },
    );
  });
}
