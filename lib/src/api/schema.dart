/// A typed JSON-schema builder that is *both* an OpenAPI 3.1 schema ([toJson])
/// and a runtime validator ([validate]) — one declaration, so the documented
/// request shape and the shape the handler accepts can never drift.
///
/// ```dart
/// const user = ApiSchema.object({
///   'name': ApiSchema.string(),
///   'email': ApiSchema.string(format: 'email'),
///   'age': ApiSchema.integer(nullable: true),
/// }, required: ['name', 'email']);
///
/// // In the docs:
/// doc: OpenApiOperation(requestBodyDoc: OpenApiRequestBody.json(schema: user.toJson()))
/// // In the handler (or via validateJsonBody(user)):
/// final errors = user.validate(request.jsonMap());
/// ```
library;

enum _Kind { string, integer, number, boolean, object, array, ref }

/// A JSON schema node. Build with the named constructors; compose [object] and
/// [array] for nested shapes.
class ApiSchema {
  const ApiSchema._(
    this._kind, {
    this.format,
    this.enumValues,
    this.nullable = false,
    this.description,
    this.properties,
    this.required = const [],
    this.additionalProperties = true,
    this.items,
    this.refName,
  });

  /// A string, optionally with an OpenAPI [format] (`email`, `date-time`, …)
  /// or an [enumValues] allow-list.
  const ApiSchema.string({
    String? format,
    List<Object?>? enumValues,
    bool nullable = false,
    String? description,
  }) : this._(
         _Kind.string,
         format: format,
         enumValues: enumValues,
         nullable: nullable,
         description: description,
       );

  /// An integer.
  const ApiSchema.integer({bool nullable = false, String? description})
    : this._(_Kind.integer, nullable: nullable, description: description);

  /// A number (integer or double).
  const ApiSchema.number({bool nullable = false, String? description})
    : this._(_Kind.number, nullable: nullable, description: description);

  /// A boolean.
  const ApiSchema.boolean({bool nullable = false, String? description})
    : this._(_Kind.boolean, nullable: nullable, description: description);

  /// An object with named [properties], a [required] key list, and whether
  /// [additionalProperties] (unlisted keys) are allowed.
  const ApiSchema.object(
    Map<String, ApiSchema> properties, {
    List<String> required = const [],
    bool additionalProperties = true,
    bool nullable = false,
    String? description,
  }) : this._(
         _Kind.object,
         properties: properties,
         required: required,
         additionalProperties: additionalProperties,
         nullable: nullable,
         description: description,
       );

  /// An array whose elements match [items].
  const ApiSchema.array(
    ApiSchema items, {
    bool nullable = false,
    String? description,
  }) : this._(
         _Kind.array,
         items: items,
         nullable: nullable,
         description: description,
       );

  /// A `$ref` to a reusable schema registered under `components.schemas[name]`.
  /// Validation treats a ref as "any" (the registry is resolved by the doc,
  /// not here).
  const ApiSchema.ref(String name) : this._(_Kind.ref, refName: name);

  final _Kind _kind;
  final String? format;
  final List<Object?>? enumValues;
  final bool nullable;
  final String? description;
  final Map<String, ApiSchema>? properties;
  final List<String> required;
  final bool additionalProperties;
  final ApiSchema? items;
  final String? refName;

  /// The OpenAPI 3.1 schema object.
  Map<String, Object?> toJson() {
    if (_kind == _Kind.ref) {
      return {r'$ref': '#/components/schemas/$refName'};
    }
    // Map lookup, not a switch: a `ref` arm would be dead code (ref returns
    // above), and this keeps every line reachable.
    const typeNames = {
      _Kind.string: 'string',
      _Kind.integer: 'integer',
      _Kind.number: 'number',
      _Kind.boolean: 'boolean',
      _Kind.object: 'object',
      _Kind.array: 'array',
    };
    final type = typeNames[_kind]!;
    return {
      // 3.1 nullable is `type: [t, 'null']`.
      'type': nullable ? [type, 'null'] : type,
      'description': ?description,
      'format': ?format,
      'enum': ?enumValues,
      if (_kind == _Kind.object) ...{
        'properties': {
          for (final e in properties!.entries) e.key: e.value.toJson(),
        },
        if (required.isNotEmpty) 'required': required,
        'additionalProperties': additionalProperties,
      },
      if (_kind == _Kind.array) 'items': items!.toJson(),
    };
  }

  /// Validates a decoded JSON [value] against this schema, returning a list of
  /// human-readable error messages (empty when valid). [path] prefixes nested
  /// errors. A `ref` schema accepts anything (resolved elsewhere).
  List<String> validate(Object? value, [String path = r'$']) {
    if (value == null) {
      return nullable ? const [] : ['$path: expected ${_kind.name}, got null'];
    }
    switch (_kind) {
      case _Kind.ref:
        return const [];
      case _Kind.string:
        if (value is! String) return ['$path: expected string'];
        if (enumValues != null && !enumValues!.contains(value)) {
          return ['$path: "$value" not in $enumValues'];
        }
        return const [];
      case _Kind.integer:
        return value is int ? const [] : ['$path: expected integer'];
      case _Kind.number:
        return value is num ? const [] : ['$path: expected number'];
      case _Kind.boolean:
        return value is bool ? const [] : ['$path: expected boolean'];
      case _Kind.array:
        if (value is! List) return ['$path: expected array'];
        return [
          for (var i = 0; i < value.length; i++)
            ...items!.validate(value[i], '$path[$i]'),
        ];
      case _Kind.object:
        if (value is! Map) return ['$path: expected object'];
        final errors = <String>[];
        for (final key in required) {
          if (!value.containsKey(key)) errors.add('$path.$key: required');
        }
        for (final e in properties!.entries) {
          if (value.containsKey(e.key)) {
            errors.addAll(e.value.validate(value[e.key], '$path.${e.key}'));
          }
        }
        if (!additionalProperties) {
          for (final key in value.keys) {
            if (!properties!.containsKey(key)) {
              errors.add('$path.$key: unexpected property');
            }
          }
        }
        return errors;
    }
  }
}
