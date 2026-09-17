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
/// A template is a list of segments the engine concatenates on its own thread,
/// per request, from the matched path's `:params` — no Dart handler runs, so a
/// template route answers at static-route throughput while still varying with
/// the request. Slots only ever land in the body, never a header.
sealed class TemplateSegment {
  const TemplateSegment();

  /// Literal bytes emitted verbatim.
  const factory TemplateSegment.literal(String text) = TemplateLiteral;

  /// The captured `:name` path parameter, escaped per [escape]
  /// (JSON string by default).
  const factory TemplateSegment.param(
    String name, {
    SlotEscape escape,
  }) = TemplateParam;
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
    out.add(kind == 1
        ? TemplateParam(text,
            escape: escape == 1 ? SlotEscape.jsonString : SlotEscape.raw)
        : TemplateLiteral(text));
  }
  return out;
}

/// Assembles a template body from [segments] and captured path [params] —
/// literals verbatim, params escaped per slot (`jsonString` → a quoted JSON
/// string via [jsonEncode]). Mirrors `assembleTemplateBody` in `Template.h`; a
/// missing param contributes an empty value. Used by the in-memory harness.
String assembleTemplateBody(
  List<TemplateSegment> segments,
  Map<String, String> params,
) {
  final out = StringBuffer();
  for (final seg in segments) {
    switch (seg) {
      case TemplateLiteral(:final text):
        out.write(text);
      case TemplateParam(:final name, :final escape):
        final value = params[name] ?? '';
        out.write(escape == SlotEscape.jsonString ? jsonEncode(value) : value);
    }
  }
  return out.toString();
}
