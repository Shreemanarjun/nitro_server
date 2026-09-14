/// `multipart/form-data` parsing (RFC 7578).
library;

import 'dart:convert';
import 'dart:typed_data';

/// One part of a multipart body: a form field or a file upload.
class MultipartPart {
  const MultipartPart({
    required this.name,
    required this.bytes,
    this.filename,
    this.contentType,
  });

  /// The `name` of the `content-disposition`.
  final String name;

  /// The `filename` of the `content-disposition`; null for plain fields.
  final String? filename;

  /// The part's `content-type`, if it sent one.
  final String? contentType;
  final Uint8List bytes;

  /// True for file uploads (a `filename` was sent).
  bool get isFile => filename != null;

  /// The bytes as UTF-8 text.
  String text() => utf8.decode(bytes);

  @override
  String toString() =>
      'MultipartPart($name${filename == null ? '' : ', file=$filename'}, '
      '${bytes.length} bytes)';
}

/// Parses [body] as `multipart/form-data` with the boundary named in
/// [contentType]. Throws [FormatException] on a missing boundary or a body
/// that does not follow the delimiter grammar.
List<MultipartPart> parseMultipart(Uint8List body, String contentType) {
  final boundary = _boundaryOf(contentType);
  if (boundary == null) {
    throw FormatException('not multipart/form-data: $contentType');
  }
  final delimiter = ascii.encode('--$boundary');
  final parts = <MultipartPart>[];
  var pos = _indexOf(body, delimiter, 0);
  if (pos < 0) {
    throw const FormatException('multipart: no opening boundary');
  }
  pos += delimiter.length;
  while (true) {
    // After a delimiter: `--` ends the body, CRLF starts a part.
    if (pos + 1 < body.length && body[pos] == 0x2d && body[pos + 1] == 0x2d) {
      return parts;
    }
    pos = _skipCrlf(body, pos);
    final headEnd = _indexOf(body, _crlfCrlf, pos);
    if (headEnd < 0) {
      throw const FormatException('multipart: unterminated part');
    }
    final headers = _parseHeaders(ascii.decode(body.sublist(pos, headEnd)));
    final dataStart = headEnd + 4;
    final next = _indexOf(body, delimiter, dataStart);
    if (next < 0) {
      throw const FormatException('multipart: no closing boundary');
    }
    // The CRLF before the delimiter belongs to the delimiter, not the data.
    final dataEnd = next >= 2 && body[next - 2] == 13 && body[next - 1] == 10
        ? next - 2
        : next;
    final disposition = headers['content-disposition'] ?? '';
    final name = _param(disposition, 'name');
    if (name == null) {
      throw const FormatException('multipart: part without a name');
    }
    parts.add(
      MultipartPart(
        name: name,
        filename: _param(disposition, 'filename'),
        contentType: headers['content-type'],
        bytes: Uint8List.sublistView(body, dataStart, dataEnd),
      ),
    );
    pos = next + delimiter.length;
  }
}

final _crlfCrlf = Uint8List.fromList([13, 10, 13, 10]);

String? _boundaryOf(String contentType) {
  final lower = contentType.toLowerCase();
  if (!lower.startsWith('multipart/form-data')) return null;
  return _param(contentType, 'boundary');
}

/// `key=value` or `key="value"` inside a `;`-separated header value.
String? _param(String header, String key) {
  for (final piece in header.split(';').skip(1)) {
    final eq = piece.indexOf('=');
    if (eq < 0) continue;
    if (piece.substring(0, eq).trim().toLowerCase() != key) continue;
    var value = piece.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }
  return null;
}

Map<String, String> _parseHeaders(String head) {
  final out = <String, String>{};
  for (final line in head.split('\r\n')) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    out[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  return out;
}

int _skipCrlf(Uint8List body, int pos) {
  if (pos + 1 < body.length && body[pos] == 13 && body[pos + 1] == 10) {
    return pos + 2;
  }
  throw const FormatException('multipart: expected CRLF after boundary');
}

int _indexOf(Uint8List hay, List<int> needle, int from) {
  final last = hay.length - needle.length;
  outer:
  for (var i = from; i <= last; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
