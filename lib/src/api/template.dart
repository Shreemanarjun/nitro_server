import 'dart:convert';
import 'dart:typed_data';

/// How a [TemplateParam]'s captured value is escaped into the response body.
enum SlotEscape {
  /// Emit the value's bytes verbatim — caller-beware; use only for values you
  /// know are safe in the surrounding syntax (numbers, pre-escaped fragments).
  raw,

  /// Emit the value as a quoted, escaped JSON string (`"`, `\`, control bytes
  /// handled). The safe default when substituting into a JSON body.
  jsonString,
}

/// One piece of a templated response body served by [NitroServer.getTemplated].
///
/// Usually you write a template *string* (`'{"id":{id},"q":{?q}}'`) and it is
/// parsed into these segments; this typed form is the escape hatch for building
/// a template programmatically. The engine concatenates the segments on its own
/// thread, per request, from the matched path's `:params` and the request's
/// query — no Dart handler runs, so a template route answers at static-route
/// throughput while still varying with the request. Slots land only in the
/// body, never a header.
sealed class TemplateSegment {
  const TemplateSegment();

  /// Literal bytes emitted verbatim.
  const factory TemplateSegment.literal(String text) = TemplateLiteral;

  /// The captured `:name` path parameter, escaped per [escape]
  /// (JSON string by default). Template string: `{name}` (or `{name!}` raw).
  const factory TemplateSegment.param(
    String name, {
    SlotEscape escape,
  }) = TemplateParam;

  /// The `?name=` query value (form-decoded), escaped per [escape]. Template
  /// string: `{?name}` (or `{?name!}` raw).
  const factory TemplateSegment.query(
    String name, {
    SlotEscape escape,
  }) = TemplateQuery;
}

/// Literal bytes in a template body.
final class TemplateLiteral extends TemplateSegment {
  final String text;
  const TemplateLiteral(this.text);
}

/// A `:name` path parameter slot in a template body.
final class TemplateParam extends TemplateSegment {
  final String name;
  final SlotEscape escape;
  const TemplateParam(this.name, {this.escape = SlotEscape.jsonString});
}

/// A `?name=` query parameter slot in a template body.
final class TemplateQuery extends TemplateSegment {
  final String name;
  final SlotEscape escape;
  const TemplateQuery(this.name, {this.escape = SlotEscape.jsonString});
}

/// The one shape a `{...}` placeholder can take: an optional `?` (query),
/// a `[A-Za-z0-9_]` name, an optional trailing `!` (raw). A `{` that does not
/// match this — including every `{`/`}` in a JSON body — is a literal, so a
/// JSON template needs no brace escaping.
final RegExp _placeholder = RegExp(r'\{(\?)?([A-Za-z0-9_]+)(!)?\}');

/// Parses a template *string* into [TemplateSegment]s. Placeholders:
///
/// - `{name}` — the `:name` path parameter, escaped per [defaultEscape].
/// - `{?name}` — the `?name=` query value, escaped per [defaultEscape].
/// - a trailing `!` (`{name!}`, `{?name!}`) forces [SlotEscape.raw] for that
///   slot (e.g. a numeric field with no quotes).
/// - any other `{` or `}` is literal (so `{"id":{id}}` needs no escaping);
///   `{{` and `}}` force a literal `{`/`}` where a real placeholder would
///   otherwise be recognised.
///
/// [defaultEscape] is [SlotEscape.jsonString] (safe for JSON bodies); pass
/// [SlotEscape.raw] for a plain-text template so every slot is verbatim. Total:
/// any string is a valid template (an unrecognised `{…}` is just literal text).
List<TemplateSegment> parseTemplate(
  String template, {
  SlotEscape defaultEscape = SlotEscape.jsonString,
}) {
  final segments = <TemplateSegment>[];
  final literal = StringBuffer();
  void flushLiteral() {
    if (literal.isNotEmpty) {
      segments.add(TemplateLiteral(literal.toString()));
      literal.clear();
    }
  }

  var i = 0;
  while (i < template.length) {
    final c = template[i];
    if (c == '{' && i + 1 < template.length && template[i + 1] == '{') {
      literal.write('{');
      i += 2;
      continue;
    }
    if (c == '}' && i + 1 < template.length && template[i + 1] == '}') {
      literal.write('}');
      i += 2;
      continue;
    }
    if (c == '{') {
      final m = _placeholder.matchAsPrefix(template, i);
      if (m != null) {
        final isQuery = m.group(1) != null;
        final name = m.group(2)!;
        final escape = m.group(3) != null ? SlotEscape.raw : defaultEscape;
        flushLiteral();
        segments.add(isQuery
            ? TemplateQuery(name, escape: escape)
            : TemplateParam(name, escape: escape));
        i = m.end;
        continue;
      }
    }
    literal.write(c);
    i++;
  }
  flushLiteral();
  return segments;
}

/// Packs [segments] into the wire blob the engine decodes at registration
/// (`decodeTemplateBlob` in `Template.h`), little-endian:
/// `[u32 count]` then per segment `[u8 kind][u8 escape][u32 len][utf8 text]`.
/// kind: 0 = literal, 1 = param. escape: 0 = raw, 1 = jsonString.
Uint8List encodeTemplateBlob(List<TemplateSegment> segments) {
  final out = BytesBuilder(copy: false);
  final header = ByteData(4)..setUint32(0, segments.length, Endian.little);
  out.add(header.buffer.asUint8List());
  for (final seg in segments) {
    final (int kind, int escape, String text) = switch (seg) {
      TemplateLiteral(:final text) => (0, 0, text),
      TemplateParam(:final name, :final escape) => (
        1,
        escape == SlotEscape.jsonString ? 1 : 0,
        name,
      ),
      TemplateQuery(:final name, :final escape) => (
        2,
        escape == SlotEscape.jsonString ? 1 : 0,
        name,
      ),
    };
    final bytes = utf8.encode(text);
    final prefix = ByteData(6)
      ..setUint8(0, kind)
      ..setUint8(1, escape)
      ..setUint32(2, bytes.length, Endian.little);
    out.add(prefix.buffer.asUint8List());
    out.add(bytes);
  }
  return out.toBytes();
}

/// Inverse of [encodeTemplateBlob]. Throws [FormatException] on a truncated or
/// implausible blob (mirrors `decodeTemplateBlob` in `Template.h`). Used by the
/// in-memory test harness to serve template routes without the native engine.
List<TemplateSegment> decodeTemplateBlob(Uint8List blob) {
  final data = ByteData.sublistView(blob);
  void need(int off, int n) {
    if (off + n > blob.length) throw const FormatException('truncated template blob');
  }

  need(0, 4);
  final count = data.getUint32(0, Endian.little);
  if (count > 100000) throw const FormatException('implausible segment count');
  var off = 4;
  final out = <TemplateSegment>[];
  for (var i = 0; i < count; i++) {
    need(off, 6);
    final kind = data.getUint8(off);
    final escape = data.getUint8(off + 1);
    final len = data.getUint32(off + 2, Endian.little);
    off += 6;
    need(off, len);
    final text = utf8.decode(blob.sublist(off, off + len));
    off += len;
    final esc = escape == 1 ? SlotEscape.jsonString : SlotEscape.raw;
    out.add(switch (kind) {
      1 => TemplateParam(text, escape: esc),
      2 => TemplateQuery(text, escape: esc),
      _ => TemplateLiteral(text),
    });
  }
  return out;
}

/// A dynamic value in a [jsonTemplate] structure: a path param or query value
/// the engine fills per request. Anything else in the structure (strings,
/// numbers, bools, null, lists, maps) is a literal, JSON-encoded at build time.
final class Slot {
  final TemplateSegment segment;
  const Slot._(this.segment);

  /// The `:name` path param as a JSON **string** (quoted, escaped): `"42"`.
  factory Slot.param(String name) => Slot._(TemplateParam(name));

  /// The `:name` path param **verbatim** — for a field that is already a JSON
  /// literal, e.g. a numeric segment: `/count/:n` → `42` (no quotes). The value
  /// must be valid JSON in that position; a path param is always present.
  factory Slot.paramRaw(String name) =>
      Slot._(TemplateParam(name, escape: SlotEscape.raw));

  /// The `?name=` query value as a JSON **string** (quoted, escaped); a missing
  /// query param yields `""`, so the JSON stays valid.
  factory Slot.query(String name) => Slot._(TemplateQuery(name));

  /// The `?name=` query value **verbatim** (numeric query fields). Caller-beware:
  /// a missing or non-numeric value breaks the JSON — use [Slot.query] unless
  /// you control the input.
  factory Slot.queryRaw(String name) =>
      Slot._(TemplateQuery(name, escape: SlotEscape.raw));
}

/// Builds template segments from a JSON-shaped Dart [structure] — the ergonomic
/// way to describe a JSON template body without hand-writing the encoded string
/// or worrying about quoting. [Slot] values become engine-filled slots; every
/// other value (String/num/bool/null/List/Map, nested freely) is JSON-encoded
/// as a literal. See [NitroServer.getTemplatedJson].
///
/// ```dart
/// jsonTemplate({
///   'userId': Slot.param('id'),   // -> "42"
///   'active': true,               // literal
///   'tags': ['a', 'b'],           // literal array
/// });
/// ```
List<TemplateSegment> jsonTemplate(Object? structure) {
  final segments = <TemplateSegment>[];
  final literal = StringBuffer();
  void flush() {
    if (literal.isNotEmpty) {
      segments.add(TemplateLiteral(literal.toString()));
      literal.clear();
    }
  }

  void walk(Object? v) {
    if (v is Slot) {
      flush();
      segments.add(v.segment);
    } else if (v is Map) {
      literal.write('{');
      var first = true;
      v.forEach((k, value) {
        if (!first) literal.write(',');
        first = false;
        literal
          ..write(jsonEncode(k.toString()))
          ..write(':');
        walk(value);
      });
      literal.write('}');
    } else if (v is List) {
      literal.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) literal.write(',');
        walk(v[i]);
      }
      literal.write(']');
    } else {
      literal.write(jsonEncode(v));  // String/num/bool/null
    }
  }

  walk(structure);
  flush();
  return segments;
}

/// Assembles a template body from [segments], captured path [params] and the
/// (form-decoded) [query] map — literals verbatim, slots escaped per mode
/// (`jsonString` → a quoted JSON string via [jsonEncode]). Mirrors
/// `assembleTemplateBody` in `Template.h`; a missing field contributes an empty
/// value. Used by the in-memory harness.
String assembleTemplateBody(
  List<TemplateSegment> segments,
  Map<String, String> params,
  Map<String, String> query,
) {
  final out = StringBuffer();
  for (final seg in segments) {
    final (String value, SlotEscape escape) = switch (seg) {
      TemplateLiteral(:final text) => (text, SlotEscape.raw),
      TemplateParam(:final name, :final escape) => (params[name] ?? '', escape),
      TemplateQuery(:final name, :final escape) => (query[name] ?? '', escape),
    };
    out.write(escape == SlotEscape.jsonString ? jsonEncode(value) : value);
  }
  return out.toString();
}
