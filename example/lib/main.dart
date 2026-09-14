import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nitro_server/nitro_server.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nitro_server Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const _DemoPage(),
    );
  }
}

class _LogEntry {
  _LogEntry(this.method, this.path, this.status, this.elapsed);
  final String method;
  final String path;
  final int status;
  final Duration elapsed;

  @override
  String toString() => '$method $path → $status (${elapsed.inMilliseconds}ms)';
}

class _DemoPage extends StatefulWidget {
  const _DemoPage();
  @override
  State<_DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<_DemoPage> with WidgetsBindingObserver {
  NitroServer? _server;
  bool _busy = false;
  String? _error;
  final List<_LogEntry> _log = [];
  final List<ServerEvent> _events = [];
  StreamSubscription<ServerEvent>? _eventsSub;
  String? _probeResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventsSub?.cancel();
    _server?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS suspends listener sockets in the background. Rather than letting
    // the server silently die, surface it: the user restarts it in the
    // foreground. Android needs a foreground service for the same reason —
    // the engine cannot keep the process alive by itself.
    if (state != AppLifecycleState.resumed && _server != null) {
      _eventsSub?.cancel();
      _server?.close();
      setState(() {
        _server = null;
        _error = 'Server stopped: app left the foreground. Tap Start again.';
      });
    }
  }

  RequestHandler _logged(String name, RequestHandler inner) {
    return (request) async {
      final stopwatch = Stopwatch()..start();
      try {
        final response = await inner(request);
        stopwatch.stop();
        _appendLog(request, response.status, stopwatch.elapsed);
        return response;
      } catch (_) {
        stopwatch.stop();
        _appendLog(request, 500, stopwatch.elapsed);
        rethrow;
      }
    };
  }

  void _appendLog(RequestContext request, int status, Duration elapsed) {
    final method = request.method == HttpMethod.custom
        ? request.customMethod
        : request.method.token;
    setState(() {
      _log.insert(0, _LogEntry(method, request.path, status, elapsed));
      if (_log.length > 100) _log.removeLast();
    });
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final server = await NitroServer.bind();
      await server.route(
        HttpMethod.get,
        '/hello',
        _logged('hello', (_) async => ResponseContext.text('hi 👋')),
      );
      await server.route(
        HttpMethod.get,
        '/users/:id',
        _logged(
          'user',
          (request) async =>
              ResponseContext.json(jsonEncode({'id': request.param('id')})),
        ),
      );
      await server.route(
        HttpMethod.post,
        '/echo',
        _logged('echo', (request) async {
          return ResponseContext.bytes(request.body);
        }),
      );
      // Deliberately slower than its timeout: proves the per-route deadline
      // answers 408 without wedging the other routes.
      await server.route(
        HttpMethod.get,
        '/slow',
        _logged('slow', (_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return ResponseContext.text('too late');
        }),
        timeout: const Duration(seconds: 1),
      );
      _eventsSub = server.events.listen((event) {
        setState(() {
          _events.insert(0, event);
          if (_events.length > 50) _events.removeLast();
        });
      });
      setState(() => _server = server);
    } on NitroServerException catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    await _eventsSub?.cancel();
    await _server?.close();
    setState(() {
      _server = null;
      _busy = false;
      _probeResult = null;
    });
  }

  Future<void> _probe(
    String label,
    String path, {
    String method = 'GET',
  }) async {
    final server = _server;
    if (server == null) return;
    setState(() {
      _busy = true;
      _probeResult = null;
    });
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (label == 'POST /echo') {
        request.add(utf8.encode('echo-me'));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      setState(() => _probeResult = '$label → ${response.statusCode} $body');
    } catch (e) {
      setState(() => _probeResult = '$label → error: $e');
    } finally {
      client.close(force: true);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    return Scaffold(
      appBar: AppBar(title: const Text('nitro_server Demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  server == null ? Icons.circle_outlined : Icons.circle,
                  color: server == null ? Colors.grey : Colors.green,
                  size: 14,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    server == null
                        ? 'Stopped'
                        : 'Listening on http://127.0.0.1:${server.port}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                if (_busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (server == null)
                  ElevatedButton(onPressed: _start, child: const Text('Start'))
                else
                  OutlinedButton(onPressed: _stop, child: const Text('Stop')),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 12),
            if (server != null) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: const Text('GET /hello'),
                    onPressed: () => _probe('GET /hello', '/hello'),
                  ),
                  ActionChip(
                    label: const Text('GET /users/42'),
                    onPressed: () => _probe('GET /users/42', '/users/42'),
                  ),
                  ActionChip(
                    label: const Text('POST /echo'),
                    onPressed: () =>
                        _probe('POST /echo', '/echo', method: 'POST'),
                  ),
                  ActionChip(
                    label: const Text('GET /slow (→ 408)'),
                    onPressed: () => _probe('GET /slow', '/slow'),
                  ),
                ],
              ),
              if (_probeResult != null) ...[
                const SizedBox(height: 8),
                SelectableText(_probeResult!),
              ],
              const SizedBox(height: 8),
              const Text('Or from a terminal:'),
              SelectableText(
                'curl http://127.0.0.1:${server.port}/users/42',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(text: 'Requests'),
                        Tab(text: 'Events'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _log.isEmpty
                              ? const Center(child: Text('No requests yet.'))
                              : ListView.builder(
                                  itemCount: _log.length,
                                  itemBuilder: (_, i) {
                                    final entry = _log[i];
                                    return ListTile(
                                      dense: true,
                                      leading: Text(
                                        entry.status.toString(),
                                        style: TextStyle(
                                          color: entry.status < 400
                                              ? Colors.green
                                              : Colors.red,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      title: Text(
                                        '${entry.method} ${entry.path}',
                                      ),
                                      trailing: Text(
                                        '${entry.elapsed.inMilliseconds}ms',
                                      ),
                                    );
                                  },
                                ),
                          _events.isEmpty
                              ? const Center(child: Text('No events yet.'))
                              : ListView.builder(
                                  itemCount: _events.length,
                                  itemBuilder: (_, i) {
                                    final event = _events[i];
                                    return ListTile(
                                      dense: true,
                                      title: Text(event.kind.name),
                                      subtitle: Text(event.message),
                                    );
                                  },
                                ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
