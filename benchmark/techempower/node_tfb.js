// TechEmpower-style TFB server — Node.js http + cluster. /json + /plaintext.
// One worker per core (shared listening socket), keep-alive default.
'use strict';
const cluster = require('cluster');
const http = require('http');
const os = require('os');

const plaintext = Buffer.from('Hello, World!');

function handler(req, res) {
  if (req.url === '/plaintext') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(plaintext);
  } else if (req.url === '/json') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    // Serialize per request (TFB /json is a serialization test).
    res.end(JSON.stringify({ message: 'Hello, World!' }));
  } else {
    res.statusCode = 404;
    res.end();
  }
}

const nWorkers = os.cpus().length;
if (cluster.isPrimary) {
  for (let i = 0; i < nWorkers; i++) cluster.fork();
  console.log('PORT 8080');
} else {
  http.createServer(handler).listen(8080, '127.0.0.1');
}
