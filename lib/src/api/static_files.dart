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
/// Each answer is a [ResponseContext.file] (sent by the engine in chunks,
/// never through the Dart heap) with `content-type` by extension ([contentTypes]),
/// `last-modified`, a weak `etag`, `accept-ranges: bytes`, and
/// `cache-control: max-age` when [maxAge] is set. `If-None-Match` and
/// `If-Modified-Since` answer 304; a single `Range` answers 206 with
/// `content-range`, an unsatisfiable one 416. Directories serve [index].
///
/// Containment: every path segment is percent-decoded exactly once and then
/// checked, so `..`, `%2e%2e`, `..%2f`, `%5c` and NUL cannot escape; the
/// answered file's real path (symlinks resolved) must sit under the canonical
/// [root], and that resolved path is what is served. Anything that escapes,
/// and anything missing, answers 404. [dotfiles] (default off) refuses any
/// segment starting with `.` — turn it on to serve e.g. `.well-known/`.
/// [followSymlinks] (default on) allows links that resolve inside [root];
/// off, a symlinked file is a 404 even when it points inside.
RequestHandler staticFiles(
  String root, {
  String index = 'index.html',
  Map<String, String> contentTypes = defaultContentTypes,
  Duration? maxAge,
  bool dotfiles = false,
  bool followSymlinks = true,
}) {
  final base = Directory(root).absolute.path;
  // The containment boundary: the root with its own symlinks resolved (on
  // macOS `/tmp` is one), computed once rather than per request.
  final canonicalBase = _realPath(base) ?? base;
  return (request) {
    final relative = _relativePath(request, dotfiles: dotfiles);
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
    // Resolve, then contain: the real file must live under the canonical
    // root. Serving the resolved path (not the request's) also closes the
    // window in which a link could be swapped between this check and the
    // engine's sendfile.
    final real = _realPath(file.path);
    if (real == null || !_isUnder(canonicalBase, real)) {
      return const ResponseContext(status: 404);
    }
    if (!followSymlinks &&
        _slashes(real) !=
            _slashes(canonicalBase + file.path.substring(base.length))) {
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
    final dot = real.lastIndexOf('.');
    final slash = real.lastIndexOf('/');
    final ext = dot > slash ? real.substring(dot + 1).toLowerCase() : '';
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
        real,
        status: 206,
        contentType: contentType,
        headers: {...headers, 'content-range': 'bytes $start-$end/$size'},
        offset: start,
        length: end - start + 1,
      );
    }
    return ResponseContext.file(
      real,
      contentType: contentType,
      headers: headers,
    );
  };
}

/// The request path relative to the route's wildcard mount point: each
/// segment percent-decoded once, then refused if it is `..`, carries a
/// separator (`/`, `\`) or NUL — i.e. anything that could step outside the
/// root after decoding — or, unless [dotfiles], starts with `.`. Null when
/// the path is refused.
String? _relativePath(RequestContext request, {required bool dotfiles}) {
  final pattern = request.routePattern;
  var path = request.path;
  if (pattern.endsWith('*')) {
    final prefix = pattern.substring(0, pattern.length - 1);
    if (path.startsWith(prefix)) path = path.substring(prefix.length);
  }
  final segments = <String>[];
  for (final raw in path.split('/')) {
    if (raw.isEmpty) continue;
    final String segment;
    try {
      segment = Uri.decodeComponent(raw);
    } on ArgumentError {
      return null; // malformed percent-encoding
    }
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..' ||
        segment.contains('/') ||
        segment.contains('\\') ||
        segment.contains('\u0000')) {
      return null;
    }
    if (!dotfiles && segment.startsWith('.')) return null;
    segments.add(segment);
  }
  return segments.join('/');
}

/// [path] with every symlink resolved, or null when it does not exist.
String? _realPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
}

String _slashes(String path) => path.replaceAll('\\', '/');

/// Whether [path] is [root] or lies beneath it (separator-aware, so `/root2`
/// is not under `/root`).
bool _isUnder(String root, String path) {
  final r = _slashes(root), p = _slashes(path);
  return p == r || p.startsWith(r.endsWith('/') ? r : '$r/');
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
