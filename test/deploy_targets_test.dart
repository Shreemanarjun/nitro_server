/// `nitro deploy` renderers: every target produces parseable, option-driven
/// files and the right follow-up commands; bad options are refused.
library;

import 'dart:convert';

import 'package:nitro_server/src/deploy/targets.dart';
import 'package:test/test.dart';

void main() {
  const o = DeployOptions(
    name: 'shop-api',
    entry: 'bin/shop.dart',
    port: 9090,
    healthPath: '/healthz',
    instanceType: 'standard-1',
    instances: 4,
    sleepAfter: '30m',
    backend: 'https://api.example.com/',
    apiPrefix: '/api/',
    publishDir: 'dist',
  );

  test('targets parse by name and know whether they need a backend', () {
    expect(DeployTarget.parse('cloudflare'), DeployTarget.cloudflare);
    expect(DeployTarget.parse('heroku'), isNull);
    expect(needsBackend(DeployTarget.netlify), isTrue);
    expect(needsBackend(DeployTarget.vercel), isTrue);
    expect(needsBackend(DeployTarget.docker), isFalse);
    expect(needsBackend(DeployTarget.cloudflare), isFalse);
    expect(o.exeName, 'shop');
  });

  test('docker: Dockerfile builds the entry and probes the health path', () {
    final files = renderDeploy(DeployTarget.docker, o);
    expect(files.keys, containsAll(['Dockerfile', '.dockerignore']));
    final d = files['Dockerfile']!;
    expect(d, contains('dart build cli -t bin/shop.dart'));
    expect(d, contains('ENV FLUTTER_ROOT=/opt/flutter-stub'));
    expect(d, contains('flutter.version.json'));
    expect(d, contains('PORT=9090'));
    expect(d, contains('EXPOSE 9090'));
    expect(d, contains(r'http://127.0.0.1:${PORT}/healthz'));
    expect(d, contains('ENTRYPOINT ["/app/bin/shop"]'));
    expect(d, isNot(contains('/app/public/')), reason: 'no assets by default');
    final withAssets = renderDockerfile(
      const DeployOptions(assets: ['public', 'web']),
    );
    expect(withAssets, contains('COPY --from=build /app/public/ /app/public/'));
    expect(withAssets, contains('COPY --from=build /app/web/ /app/web/'));
    expect(
      validateDeploy(
        DeployTarget.docker,
        const DeployOptions(assets: ['../x']),
      ),
      contains('asset'),
    );
    expect(d, contains('USER nitro'));
    expect(files['.dockerignore'], contains('.dart_tool/'));
    expect(
      deployCommands(DeployTarget.docker, o).single,
      contains('linux/amd64'),
    );
    expect(deployCommands(DeployTarget.docker, o).single, contains('shop-api'));
  });

  test(
    'cloudflare: wrangler config and package.json are strict JSON, worker carries the options',
    () {
      final files = renderDeploy(DeployTarget.cloudflare, o);
      expect(
        files.keys,
        containsAll([
          'Dockerfile',
          'wrangler.jsonc',
          'worker.js',
          'package.json',
        ]),
      );
      final w = jsonDecode(files['wrangler.jsonc']!) as Map<String, Object?>;
      expect(w['name'], 'shop-api');
      final container = (w['containers'] as List).single as Map;
      expect(container['instance_type'], 'standard-1');
      expect(container['max_instances'], 4);
      expect(container['class_name'], 'NitroContainer');
      expect((w['exports'] as Map).keys, contains('NitroContainer'));
      final pkg = jsonDecode(files['package.json']!) as Map<String, Object?>;
      expect(
        (pkg['dependencies'] as Map).keys,
        contains('@cloudflare/containers'),
      );
      final js = files['worker.js']!;
      expect(js, contains('defaultPort = 9090;'));
      expect(js, contains('sleepAfter = "30m";'));
      expect(js, contains('const INSTANCES = 4;'));
      expect(js, contains('env.NITRO.getByName(key)'));
      expect(
        js,
        contains('coldStartDrop(res.clone())'),
      ); // one retry on a cold-start drop
      expect(deployCommands(DeployTarget.cloudflare, o).last, [
        'npx',
        'wrangler',
        'deploy',
      ]);
    },
  );

  test('netlify: proxies the API prefix to the backend, no WebSocket rule', () {
    final toml = renderDeploy(DeployTarget.netlify, o)['netlify.toml']!;
    expect(toml, contains('publish = "dist"'));
    expect(toml, contains('from = "/api/*"'));
    expect(toml, contains('to = "https://api.example.com/api/:splat"'));
    expect(toml, contains('status = 200'));
    // Netlify's proxy does not carry WebSocket upgrades: no wss:// rule.
    expect(toml, isNot(contains('wss://')));
    expect(
      deployCommands(DeployTarget.netlify, o).single,
      containsAllInOrder(['netlify', 'deploy', '--prod', '--dir', 'dist']),
    );
  });

  test('vercel: rewrites the API prefix to the backend', () {
    final v =
        jsonDecode(renderDeploy(DeployTarget.vercel, o)['vercel.json']!)
            as Map<String, Object?>;
    final rule = (v['rewrites'] as List).single as Map;
    expect(rule['source'], '/api/:path*');
    expect(rule['destination'], 'https://api.example.com/api/:path*');
    expect(deployCommands(DeployTarget.vercel, o).single, contains('vercel'));
  });

  test('validation refuses what the targets cannot use', () {
    expect(validateDeploy(DeployTarget.docker, o), isNull);
    expect(validateDeploy(DeployTarget.netlify, o), isNull);
    expect(
      validateDeploy(
        DeployTarget.docker,
        const DeployOptions(name: 'Bad Name'),
      ),
      contains('name'),
    );
    expect(
      validateDeploy(DeployTarget.docker, const DeployOptions(port: 0)),
      contains('port'),
    );
    expect(
      validateDeploy(DeployTarget.docker, const DeployOptions(instances: 0)),
      contains('instances'),
    );
    expect(
      validateDeploy(DeployTarget.docker, const DeployOptions(entry: 'bin/x')),
      contains('entry'),
    );
    expect(
      validateDeploy(
        DeployTarget.docker,
        const DeployOptions(healthPath: 'ready'),
      ),
      contains('health'),
    );
    expect(
      validateDeploy(DeployTarget.netlify, const DeployOptions()),
      contains('--backend'),
    );
    expect(
      validateDeploy(
        DeployTarget.vercel,
        const DeployOptions(backend: 'not a url'),
      ),
      contains('--backend'),
    );
    expect(
      validateDeploy(
        DeployTarget.vercel,
        const DeployOptions(backend: 'ftp://api.example.com'),
      ),
      contains('http(s)'),
    );
    expect(
      validateDeploy(
        DeployTarget.vercel,
        const DeployOptions(
          backend: 'https://api.example.com',
          apiPrefix: 'api',
        ),
      ),
      contains('prefix'),
    );
  });

  test('docker: --platform host drops the platform flag', () {
    final cmd = deployCommands(
      DeployTarget.docker,
      const DeployOptions(platform: 'host'),
    ).single;
    expect(cmd, isNot(contains('--platform')));
    expect(
      cmd,
      containsAllInOrder(['docker', 'build', '-t', 'nitro-app', '.']),
    );
  });
}
