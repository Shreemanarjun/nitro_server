/// Static file serving on top of [ResponseContext.file]: the engine sends
/// the bytes with `sendfile`; this handler does the HTTP around it.
library;

import 'dart:io';

import 'context.dart';

/// Content types by file extension for [staticFiles].
const defaultContentTypes = <String, String>{
  'html': 'text/html; charset=utf-8',
  'htm': 'text/html; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'js': 'application/javascript; charset=utf-8',
  'mjs': 'application/javascript; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
  'md': 'text/markdown; charset=utf-8',
  'xml': 'application/xml; charset=utf-8',
  'svg': 'image/svg+xml',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'ico': 'image/x-icon',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'wasm': 'application/wasm',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mp3': 'audio/mpeg',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
};

/// Serves the files under [root]. Mount it on a wildcard route; the part
/// of the path after the wildcard's prefix names the file:
///
/// ```dart
/// await server.get('/assets/*', staticFiles('web/assets'));
/// await server.get('/*', staticFiles('public')); // with index.html
/// ```
///
/// Each answer is a [ResponseContext.file] (sent natively, never through
/// the Dart heap) with `content-type` by extension ([contentTypes]),
/// `last-modified`, a weak `etag`, `accept-ranges: bytes`, and
/// `cache-control: max-age` when [maxAge] is set. `If-None-Match` and
/// `If-Modified-Since` answer 304; a single `Range` answers 206 with
/// `content-range`, an unsatisfiable one 416. Directories serve [index].
/// Paths that escape [root] (`..`) and anything else missing answer 404.
RequestHandler staticFiles(
  String root, {
  String index = 'index.html',
  Map<String, String> contentTypes = defaultContentTypes,
  Duration? maxAge,
}) {
  final base = Directory(root).absolute.path;
  return (request) {
    final relative = _relativePath(request);
    if (relative == null) return const ResponseContext(status: 404);
    var file = File(relative.isEmpty ? '$base/$index' : '$base/$relative');
    var stat = file.statSync();
    if (stat.type == FileSystemEntityType.directory) {
      file = File('${file.path}/$index');
      stat = file.statSync();
    }
    if (stat.type != FileSystemEntityType.file) {
      return const ResponseContext(status: 404);
    }
    final size = stat.size;
    final modified = stat.modified.toUtc();
    final etag =
        'W/"${size.toRadixString(16)}-'
        '${modified.millisecondsSinceEpoch.toRadixString(16)}"';
    final headers = <String, String>{
      'etag': etag,
      'last-modified': httpDate(modified),
      'accept-ranges': 'bytes',
      if (maxAge != null) 'cache-control': 'max-age=${maxAge.inSeconds}',
    };
    if (_notModified(request, etag, modified)) {
      return ResponseContext(status: 304, headers: headers);
    }
    final dot = file.path.lastIndexOf('.');
    final slash = file.path.lastIndexOf('/');
    final ext = dot > slash ? file.path.substring(dot + 1).toLowerCase() : '';
    final contentType = contentTypes[ext] ?? 'application/octet-stream';
    final range = _parseRange(request.header('range'), size);
    if (range == _unsatisfiable) {
      return ResponseContext(
        status: 416,
        headers: {...headers, 'content-range': 'bytes */$size'},
      );
    }
    if (range != null) {
      final (start, end) = range;
      return ResponseContext.file(
        file.path,
        status: 206,
        contentType: contentType,
        headers: {...headers, 'content-range': 'bytes $start-$end/$size'},
        offset: start,
        length: end - start + 1,
      );
    }
    return ResponseContext.file(
      file.path,
      contentType: contentType,
      headers: headers,
    );
  };
}

/// The request path relative to the route's wildcard mount point, with
/// `..` and empty segments rejected. Null when the path escapes.
String? _relativePath(RequestContext request) {
  final pattern = request.routePattern;
  var path = request.path;
  if (pattern.endsWith('*')) {
    final prefix = pattern.substring(0, pattern.length - 1);
    if (path.startsWith(prefix)) path = path.substring(prefix.length);
  }
  final segments = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..' || segment.contains('\\')) return null;
    segments.add(Uri.decodeComponent(segment));
  }
  return segments.join('/');
}

bool _notModified(RequestContext request, String etag, DateTime modified) {
  final ifNoneMatch = request.header('if-none-match');
  if (ifNoneMatch != null) {
    return ifNoneMatch.split(',').map((e) => e.trim()).contains(etag) ||
        ifNoneMatch.trim() == '*';
  }
  final since = request.header('if-modified-since');
  if (since != null) {
    final parsed = _parseHttpDate(since);
    // HTTP dates have second precision.
    return parsed != null &&
        !modified.isAfter(parsed.add(const Duration(seconds: 1)));
  }
  return false;
}

const _unsatisfiable = (-1, -1);

/// A single `bytes=` range as (first, last) inclusive; null for no or an
/// ignorable header; [_unsatisfiable] when it lies outside the file.
(int, int)? _parseRange(String? header, int size) {
  if (header == null || !header.startsWith('bytes=')) return null;
  final spec = header.substring(6).trim();
  if (spec.contains(',')) return null; // Multi-range: serve whole, allowed.
  final dash = spec.indexOf('-');
  if (dash < 0) return null;
  final startText = spec.substring(0, dash).trim();
  final endText = spec.substring(dash + 1).trim();
  int start, end;
  if (startText.isEmpty) {
    final suffix = int.tryParse(endText);
    if (suffix == null || suffix <= 0) return null;
    if (size == 0) return _unsatisfiable;
    start = suffix >= size ? 0 : size - suffix;
    end = size - 1;
  } else {
    final s = int.tryParse(startText);
    if (s == null) return null;
    start = s;
    end = endText.isEmpty ? size - 1 : (int.tryParse(endText) ?? -1);
    if (end < 0) return null;
    if (end >= size) end = size - 1;
  }
  if (start >= size || start > end) return _unsatisfiable;
  return (start, end);
}

DateTime? _parseHttpDate(String text) {
  try {
    return HttpDate.parse(text);
  } on Exception {
    return null;
  }
}
