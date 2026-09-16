// Node.js http side for compare.dart — serves the same routes, byte-identical,
// so the same client can assert and benchmark Node alongside nitro/go/shelf/
// dart:io. Started by compare.dart via `node`; prints "LISTENING <port>" then
// serves. WebSocket is not implemented here (stdlib has no WS); compare.dart
// leaves Node out of the WS cases, exactly as it does shelf and Go.
//
// Multi-core parity: like Go's GOMAXPROCS (pinned by compare.dart), Node forks
// NODE_PROCS cluster workers that share one listening socket (round-robin), so
// a CPU case like /work is a same-budget comparison instead of a single event
// loop against Go's/nitro's core pool. NODE_PROCS=1 runs a single process.
//
// Byte-exactness notes (the client compares response bodies):
//   * JSON is built by hand so key order and Dart's double formatting
//     (whole doubles print as "N.0") match jsonEncode.
//   * /work's records use the literal name "item-$i" (Dart's source escapes
//     the '$'), the same for every record.
'use strict';

const cluster = require('cluster');
const http = require('http');
const os = require('os');

const batch = process.argv.includes('--batch-events');

const helloBody = Buffer.from('hello world!');
const jsonBody = Buffer.from('{"id":42,"name":"nitro","tags":["a","b","c"]}');

// 200 records {id,name,tags,score} in that order, score = i*1.5 with Dart's
// double formatting (whole -> "N.0", otherwise the shortest form, which for
// these X.5 values is what JS String() already produces).
function buildWork() {
  let s = '[';
  for (let i = 0; i < 200; i++) {
    if (i > 0) s += ',';
    const score = i * 1.5;
    const scoreStr = Number.isInteger(score) ? score + '.0' : String(score);
    s += '{"id":' + i + ',"name":"item-$i","tags":["a","b"],"score":' + scoreStr + '}';
  }
  return Buffer.from(s + ']');
}
const workBody = buildWork();

const fileBody = Buffer.alloc(64 * 1024);
for (let i = 0; i < fileBody.length; i++) fileBody[i] = (i * 31) & 0xff;

const eventChunks = [];
let eventsAll = '';
for (let i = 0; i < 20; i++) {
  const c = 'data: ' + i + '\n\n';
  eventChunks.push(Buffer.from(c));
  eventsAll += c;
}
const eventsAllBuf = Buffer.from(eventsAll);

function jsonString(str) {
  let out = '"';
  for (const ch of str) {
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else out += ch;
  }
  return out + '"';
}

// Encodes a query string as Dart's jsonEncode(queryParameters) does: a JSON
// object in the query's field order, '+' as space, percent-decoded.
function queryJSON(raw) {
  let out = '{';
  let first = true;
  for (const pair of raw.split('&')) {
    if (pair === '') continue;
    const idx = pair.indexOf('=');
    const k = idx < 0 ? pair : pair.slice(0, idx);
    const v = idx < 0 ? '' : pair.slice(idx + 1);
    const kd = decodeURIComponent(k.replace(/\+/g, ' '));
    const vd = decodeURIComponent(v.replace(/\+/g, ' '));
    if (!first) out += ',';
    first = false;
    out += jsonString(kd) + ':' + jsonString(vd);
  }
  return out + '}';
}

function writeBytes(res, body, contentType) {
  if (contentType) res.setHeader('Content-Type', contentType);
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function handler(req, res) {
  const qi = req.url.indexOf('?');
  const path = qi < 0 ? req.url : req.url.slice(0, qi);
  const rawQuery = qi < 0 ? '' : req.url.slice(qi + 1);

  if (req.method === 'POST' && path === '/echo') {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () =>
      writeBytes(res, Buffer.concat(chunks), 'application/octet-stream'));
    return;
  }
  if (path === '/events') {
    res.setHeader('Content-Type', 'text/event-stream');
    if (batch) {
      writeBytes(res, eventsAllBuf, 'text/event-stream');
    } else {
      for (const c of eventChunks) res.write(c);
      res.end();
    }
    return;
  }
  if (path.startsWith('/users/')) {
    return writeBytes(res, Buffer.from('user ' + path.slice(7)), 'text/plain');
  }
  if (path.startsWith('/files/')) {
    return writeBytes(res, Buffer.from('wild:' + path), 'text/plain');
  }
  if (path === '/q') {
    return writeBytes(res, Buffer.from(queryJSON(rawQuery)), 'application/json');
  }
  if (path === '/mw' || path === '/static' || path === '/hello') {
    return writeBytes(res, helloBody, 'text/plain');
  }
  if (path === '/json') return writeBytes(res, jsonBody, 'application/json');
  if (path === '/work') return writeBytes(res, workBody, 'application/json');
  if (path === '/file') return writeBytes(res, fileBody, 'application/octet-stream');
  res.statusCode = 404;
  res.end('not found');
}

const nWorkers = parseInt(process.env.NODE_PROCS || String(os.cpus().length), 10);

if (cluster.isPrimary && nWorkers > 1) {
  process.stderr.write('node NODE_PROCS=' + nWorkers + '\n');
  let announced = false;
  for (let i = 0; i < nWorkers; i++) {
    const w = cluster.fork();
    w.on('message', (msg) => {
      if (msg && msg.port && !announced) {
        announced = true;
        process.stdout.write('LISTENING ' + msg.port + '\n');
      }
    });
  }
} else {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1', () => {
    const port = server.address().port;
    if (process.send) process.send({ port });
    else process.stdout.write('LISTENING ' + port + '\n');
  });
}
