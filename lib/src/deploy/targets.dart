/// `nitro deploy <target>`: renders everything a hosting target needs to run
/// (Docker, Cloudflare Containers) or to front (Netlify, Vercel) a
/// nitro_server app, so one command prepares a deployment.
///
/// Only container hosts can run the server: it is a native process with its
/// own sockets. Netlify and Vercel host a static site and proxy API and
/// WebSocket paths to a backend URL, which is why those targets require
/// [DeployOptions.backend].
library;

import 'dart:convert';

enum DeployTarget {
  /// A Dockerfile that builds the app with the prebuilt engine.
  docker,

  /// Dockerfile + Worker + `wrangler.jsonc` for Cloudflare Containers.
  cloudflare,

  /// `netlify.toml`: static site, API paths proxied to [DeployOptions.backend].
  netlify,

  /// `vercel.json`: static site, API paths rewritten to [DeployOptions.backend].
  vercel;

  static DeployTarget? parse(String name) {
    for (final t in values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// What the renderers need. Defaults suit `bin/server.dart` on port 8080.
class DeployOptions {
  const DeployOptions({
    this.name = 'nitro-app',
    this.entry = 'bin/server.dart',
    this.port = 8080,
    this.healthPath = '/readyz',
    this.instanceType = 'basic',
    this.instances = 3,
    this.sleepAfter = '15m',
    this.backend,
    this.apiPrefix = '/api',
    this.publishDir = 'public',
    this.platform = 'linux/amd64',
    this.assets = const [],
  });

  /// Image / Worker name (`[a-z0-9-]`).
  final String name;

  /// The Dart entrypoint compiled into the image.
  final String entry;

  /// Port the server listens on inside the container (`PORT`).
  final int port;

  /// Path the container HEALTHCHECK probes.
  final String healthPath;

  /// Cloudflare instance type (`lite`, `basic`, `standard-1`…).
  final String instanceType;

  /// Cloudflare: instances the Worker spreads requests over.
  final int instances;

  /// Cloudflare: idle time before an instance sleeps.
  final String sleepAfter;

  /// Netlify / Vercel: the deployed nitro_server URL to proxy to.
  final String? backend;

  /// Netlify / Vercel: the path prefix proxied to [backend].
  final String apiPrefix;

  /// Netlify: the static directory to publish.
  final String publishDir;

  /// Docker: the image platform (`linux/amd64` for the hosts that run it;
  /// `host` builds for the machine you are on, e.g. a local check on Apple
  /// Silicon).
  final String platform;

  /// Docker: directories (relative to the project) copied into the runtime
  /// image next to the executable, so `staticFiles('public')` and
  /// `ResponseContext.file('public/...')` find them. The CLI fills this with
  /// whichever of `public`, `assets`, `web` exist.
  final List<String> assets;

  /// The executable `dart build cli` produces for [entry].
  String get exeName =>
      entry.split('/').last.replaceAll(RegExp(r'\.dart$'), '');
}

/// True for targets that only front a server running elsewhere.
bool needsBackend(DeployTarget target) =>
    target == DeployTarget.netlify || target == DeployTarget.vercel;

/// A problem with [options] for [target], or null when they are usable.
String? validateDeploy(DeployTarget target, DeployOptions o) {
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(o.name)) {
    return 'name must be lowercase letters, digits and dashes: "${o.name}"';
  }
  if (o.port < 1 || o.port > 65535) {
    return 'port out of range: ${o.port}';
  }
  if (o.instances < 1) {
    return 'instances must be at least 1';
  }
  if (!o.entry.endsWith('.dart')) {
    return 'entry must be a .dart file: ${o.entry}';
  }
  if (!o.healthPath.startsWith('/')) {
    return 'health path must start with /';
  }
  for (final a in o.assets) {
    if (a.isEmpty ||
        a.contains('..') ||
        !RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(a)) {
      return 'asset directory must be a relative path inside the project: "$a"';
    }
  }
  if (needsBackend(target)) {
    final b = o.backend;
    final uri = b == null ? null : Uri.tryParse(b);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '${target.name} proxies to a running nitro_server: pass '
          '--backend https://your-api.example.com';
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      return 'backend must be an http(s) URL: $b';
    }
    if (!o.apiPrefix.startsWith('/')) {
      return 'api prefix must start with /';
    }
  }
  return null;
}

/// Files for [target]: path (relative to the project root) -> contents.
Map<String, String> renderDeploy(DeployTarget target, DeployOptions o) =>
    switch (target) {
      DeployTarget.docker => {
        'Dockerfile': renderDockerfile(o),
        '.dockerignore': renderDockerignore(),
      },
      DeployTarget.cloudflare => {
        'Dockerfile': renderDockerfile(o),
        '.dockerignore': renderDockerignore(),
        'wrangler.jsonc': renderWrangler(o),
        'worker.js': renderWorker(o),
        'package.json': renderPackageJson(o),
      },
      DeployTarget.netlify => {'netlify.toml': renderNetlify(o)},
      DeployTarget.vercel => {'vercel.json': renderVercel(o)},
    };

/// The commands that finish the deployment (what `nitro deploy --run` runs).
List<List<String>> deployCommands(DeployTarget target, DeployOptions o) =>
    switch (target) {
      DeployTarget.docker => [
        [
          'docker',
          'build',
          if (o.platform != 'host') ...['--platform', o.platform],
          '-t',
          o.name,
          '.',
        ],
      ],
      DeployTarget.cloudflare => [
        ['npm', 'install'],
        ['npx', 'wrangler', 'deploy'],
      ],
      DeployTarget.netlify => [
        ['npx', 'netlify', 'deploy', '--prod', '--dir', o.publishDir],
      ],
      DeployTarget.vercel => [
        ['npx', 'vercel', '--prod'],
      ],
    };

/// A two-stage image: the build stage runs `dart build cli`, whose hook
/// downloads the signed, lock-verified prebuilt engine for the image's
/// platform (no cmake, no system libraries); the runtime stage is slim and
/// non-root. Pub only resolves a package carrying a `flutter.plugin` block
/// when a Flutter SDK is present, so the build stage points `FLUTTER_ROOT`
/// at a stub holding the one file pub reads (`bin/cache/flutter.version.json`).
String renderDockerfile(DeployOptions o) =>
    '''
# Generated by `nitro deploy`. Builds ${o.entry} as a self-contained AOT bundle.
# The nitro_server build hook fetches the signed prebuilt engine for this
# platform and verifies it against the lock shipped in the package; the
# runtime stage needs only libc.
FROM dart:stable AS build
# nitro_server is also a Flutter FFI plugin, so pub refuses to resolve it
# unless a Flutter SDK is visible. The server is plain Dart and uses nothing
# from Flutter; this stub only satisfies pub's version check.
RUN mkdir -p /opt/flutter-stub/bin/cache \\
 && echo '{"flutterVersion":"3.47.5"}' > /opt/flutter-stub/bin/cache/flutter.version.json
ENV FLUTTER_ROOT=/opt/flutter-stub
WORKDIR /app
COPY pubspec.yaml pubspec.loc[k] ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart build cli -t ${o.entry} -o /app/out

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \\
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/out/bundle/ /app/
${o.assets.map((d) => 'COPY --from=build /app/$d/ /app/$d/\n').join()}ENV HOST=0.0.0.0 \\
    PORT=${o.port}
EXPOSE ${o.port}
RUN useradd --system --uid 10001 nitro
USER nitro
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \\
  CMD curl -fsS "http://127.0.0.1:\${PORT}${o.healthPath}" || exit 1
ENTRYPOINT ["/app/bin/${o.exeName}"]
''';

String renderDockerignore() => '''
build/
.dart_tool/
.git/
node_modules/
coverage/
''';

/// Strict JSON (Wrangler reads `.jsonc` as a superset), so it is machine-checkable.
String renderWrangler(DeployOptions o) => _json({
  'name': o.name,
  'main': 'worker.js',
  'compatibility_date': '2026-04-13',
  'containers': [
    {
      'class_name': 'NitroContainer',
      'image': './Dockerfile',
      'instance_type': o.instanceType,
      'max_instances': o.instances,
    },
  ],
  'durable_objects': {
    'bindings': [
      {'name': 'NITRO', 'class_name': 'NitroContainer'},
    ],
  },
  'exports': {
    'NitroContainer': {'type': 'durable-object', 'storage': 'sqlite'},
  },
});

/// The ingress Worker: forwards every request to one of [DeployOptions.instances]
/// container instances. TLS, HTTP/2 and HTTP/3 end at Cloudflare's edge; the
/// container receives HTTP/1.1. WebSockets pass through `fetch()`.
String renderWorker(DeployOptions o) =>
    '''
// Generated by `nitro deploy cloudflare`.
// The Worker is the ingress: every request is forwarded to one of
// ${o.instances} container instance(s) running the nitro_server image.
// TLS / HTTP/2 / HTTP/3 terminate at Cloudflare; the container speaks
// HTTP/1.1 on port ${o.port}. WebSockets pass through fetch() (not containerFetch()).
import { Container } from "@cloudflare/containers";

export class NitroContainer extends Container {
  defaultPort = ${o.port};
  sleepAfter = "${o.sleepAfter}";
  envVars = { HOST: "0.0.0.0", PORT: "${o.port}" };
}

const INSTANCES = ${o.instances};

export default {
  async fetch(request, env) {
    // A stateless pool. For sticky routing, derive the key from a session id
    // instead of a random slot.
    const key = `nitro-\${Math.floor(Math.random() * INSTANCES)}`;
    const instance = env.NITRO.getByName(key);
    let res = await instance.fetch(request);
    // A cold instance can drop the very first connection right after its port
    // opens; the helper reports that as a 500. Retry bodyless requests once.
    if (res.status === 500 && !request.body && (await coldStartDrop(res.clone()))) {
      res = await instance.fetch(request);
    }
    return res;
  },
};

async function coldStartDrop(res) {
  const text = await res.text();
  return (
    text.startsWith("Error proxying request to container") ||
    text.startsWith("Container suddenly disconnected")
  );
}
''';

String renderPackageJson(DeployOptions o) => _json({
  'name': o.name,
  'private': true,
  'type': 'module',
  'dependencies': {'@cloudflare/containers': 'latest'},
  'devDependencies': {'wrangler': 'latest'},
});

/// Static site on Netlify; API paths proxied to the backend. Netlify's proxy
/// does not carry WebSocket upgrades and cuts proxied requests after 26 s, so
/// WebSocket and long-lived SSE clients connect to the backend URL directly.
String renderNetlify(DeployOptions o) {
  final backend = _trimSlash(o.backend!);
  final prefix = _trimSlash(o.apiPrefix);
  return '''
# Generated by `nitro deploy netlify`. Netlify hosts the static site in
# "${o.publishDir}"; nitro_server runs elsewhere (a container host) and this
# rule proxies API traffic to it (status 200 = transparent proxy).
# Netlify's proxy does not carry WebSocket upgrades and ends proxied requests
# after 26 s: point WebSocket and long-lived SSE clients at the backend URL.
[build]
  publish = "${o.publishDir}"

[[redirects]]
  from = "$prefix/*"
  to = "$backend$prefix/:splat"
  status = 200
  force = true
''';
}

/// Static site on Vercel; API paths rewritten to the backend. Vercel rewrites
/// do not carry WebSocket upgrades: connect WebSocket clients to the backend
/// URL directly.
String renderVercel(DeployOptions o) {
  final backend = _trimSlash(o.backend!);
  final prefix = _trimSlash(o.apiPrefix);
  return _json({
    'rewrites': [
      {'source': '$prefix/:path*', 'destination': '$backend$prefix/:path*'},
    ],
  });
}

String _trimSlash(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;

String _json(Object value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';
