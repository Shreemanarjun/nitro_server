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
/// that does not follow the delimiter grammar. A part's `filename` is the
/// client's string verbatim (`../x` included): take its basename before
/// touching the filesystem.
///
/// Resource limits (each a [FormatException] when crossed, so a hostile body
/// is refused rather than walked): the boundary must be 1–70 `bchars`
/// (RFC 2046 §5.1.1), at most [maxParts] parts, and each part's header block
/// at most [maxPartHeaderBytes]. Part bodies are views into [body] (bounded by
/// the server's `maxBodyBytes`); the boundary scan is linear in the body.
List<MultipartPart> parseMultipart(
  Uint8List body,
  String contentType, {
  int maxParts = 1000,
  int maxPartHeaderBytes = 8 * 1024,
}) {
  final boundary = _boundaryOf(contentType);
  if (boundary == null) {
    throw FormatException('not multipart/form-data: $contentType');
  }
  if (boundary.isEmpty || boundary.length > 70 || !_bchars.hasMatch(boundary)) {
    throw const FormatException('multipart: invalid boundary');
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
    if (parts.length >= maxParts) {
      throw FormatException('multipart: more than $maxParts parts');
    }
    final headEnd = _indexOf(body, _crlfCrlf, pos);
    if (headEnd < 0) {
      throw const FormatException('multipart: unterminated part');
    }
    if (headEnd - pos > maxPartHeaderBytes) {
      throw FormatException(
        'multipart: part headers exceed $maxPartHeaderBytes bytes',
      );
    }
    // Part headers are what browsers send: raw UTF-8 in `filename=` (RFC 7578
    // §5.1.3 says so), so decode as UTF-8 and never throw on a stray byte.
    final headers = _parseHeaders(
      utf8.decode(body.sublist(pos, headEnd), allowMalformed: true),
    );
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

/// RFC 2046 §5.1.1 `bchars`: digits, letters, `'()+_,-./:=?` and space (not
/// trailing). Anything else cannot be a boundary and is refused.
final _bchars = RegExp(r"^[0-9A-Za-z'()+_,\-./:=? ]*[0-9A-Za-z'()+_,\-./:=?]$");

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

/// First index of [needle] in [hay] at or after [from]. Jumps between
/// candidates with the native first-byte search, then verifies; with the
/// boundary bounded to 72 bytes this is linear in [hay] for any input.
int _indexOf(Uint8List hay, List<int> needle, int from) {
  final last = hay.length - needle.length;
  final first = needle[0];
  var i = from;
  while (i <= last) {
    i = hay.indexOf(first, i);
    if (i < 0 || i > last) return -1;
    var j = 1;
    while (j < needle.length && hay[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return i;
    i++;
  }
  return -1;
}
