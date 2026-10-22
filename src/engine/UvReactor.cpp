#include "UvReactor.h"
#include <ctime>

#ifdef NITRO_SERVER_LIBUV

#ifdef _WIN32
// Winsock has no SO_REUSEPORT, so the multi-listener model doesn't apply here;
// on Windows the reactor binds a single libuv listener (see start()). These
// headers cover the address helpers (inet_pton / htons / sockaddr_*), which
// Winsock provides the same way.
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>

#include "WsCodec.h"

#ifdef NITRO_SERVER_HTTP2
#include "Http2Session.h"
#endif

#ifdef NITRO_SERVER_TLS
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#endif

namespace nitroserver {
namespace {

using Clock = std::chrono::steady_clock;

// App-level port exclusivity: SO_REUSEPORT (needed so a reactor's loops share
// one port) also lets a *second* server bind the same port, which callers do
// not expect. This registry rejects that at start().
std::mutex& boundPortsMutex() {
  static std::mutex m;
  return m;
}
std::set<int>& boundPorts() {
  static std::set<int> s;
  return s;
}


// Fills [ss] for [host]:[port]; returns the address family. A host that is
// neither a v4 nor v6 literal falls back to IPv4 loopback.
int uvBuildAddr(const std::string& host, int port, sockaddr_storage& ss,
                socklen_t& len) {
  std::memset(&ss, 0, sizeof(ss));
  in6_addr a6;
  if (inet_pton(AF_INET6, host.c_str(), &a6) == 1) {
    auto* s = reinterpret_cast<sockaddr_in6*>(&ss);
    s->sin6_family = AF_INET6;
    s->sin6_addr = a6;
    s->sin6_port = htons((uint16_t)port);
    len = sizeof(sockaddr_in6);
    return AF_INET6;
  }
  in_addr a4;
  if (inet_pton(AF_INET, host.c_str(), &a4) != 1)
    return -1;  // neither an IPv4 nor an IPv6 literal → caller reports BindFailed
  auto* s = reinterpret_cast<sockaddr_in*>(&ss);
  s->sin_family = AF_INET;
  s->sin_addr = a4;
  s->sin_port = htons((uint16_t)port);
  len = sizeof(sockaddr_in);
  return AF_INET;
}

int uvPortOf(const sockaddr_storage& ss) {
  return ss.ss_family == AF_INET6
             ? ntohs(reinterpret_cast<const sockaddr_in6*>(&ss)->sin6_port)
             : ntohs(reinterpret_cast<const sockaddr_in*>(&ss)->sin_port);
}

#ifdef NITRO_SERVER_TLS
// ALPN: the server's preference list. With HTTP/2 built in, offer `h2` ahead of
// `http/1.1` (SSL_select_next_proto walks the server list in order, picking the
// first the client also offers); otherwise only `http/1.1`. A client that offers
// neither gets no selection and falls back to HTTP/1.1.
int reactorAlpnSelect(SSL*, const unsigned char** out, unsigned char* outlen,
                      const unsigned char* in, unsigned int inlen,
                      [[maybe_unused]] void* arg) {
  static const unsigned char h11[] = {8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
  const unsigned char* prefs = h11;
  unsigned int prefsLen = sizeof(h11);
#ifdef NITRO_SERVER_HTTP2
  // `arg` points at the reactor's runtime http2 flag (cfg_.http2). Offer `h2`
  // ahead of `http/1.1` only while it is on, so a server can disable HTTP/2 at
  // runtime (clients then negotiate http/1.1). SSL_select_next_proto walks the
  // server list in order, picking the first the client also offers.
  static const unsigned char both[] = {2,   'h', '2', 8,   'h', 't',
                                        't', 'p', '/', '1', '.', '1'};
  if (arg && *static_cast<const bool*>(arg)) {
    prefs = both;
    prefsLen = sizeof(both);
  }
#endif
  if (SSL_select_next_proto((unsigned char**)out, outlen, prefs, prefsLen, in,
                            inlen) == OPENSSL_NPN_NEGOTIATED) {
    return SSL_TLSEXT_ERR_OK;
  }
  return SSL_TLSEXT_ERR_NOACK;
}
#endif

// ── Small HTTP helpers (self-contained; the live engine keeps its own copies
// until the reactor replaces it, at which point these are the survivors). ─────

const Header* uvFindHeader(const std::vector<Header>& hs, const char* name) {
  for (const auto& h : hs) {
    if (h.name.size() == std::strlen(name)) {
      bool eq = true;
      for (size_t i = 0; i < h.name.size(); i++) {
        char a = h.name[i], b = name[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) { eq = false; break; }
      }
      if (eq) return &h;
    }
  }
  return nullptr;
}

bool uvIequals(const std::string& a, const char* b) {
  if (a.size() != std::strlen(b)) return false;
  for (size_t i = 0; i < a.size(); i++) {
    char x = a[i], y = b[i];
    if (x >= 'A' && x <= 'Z') x += 32;
    if (y >= 'A' && y <= 'Z') y += 32;
    if (x != y) return false;
  }
  return true;
}

std::string uvTrim(const std::string& s) {
  size_t a = 0, b = s.size();
  while (a < b && (s[a] == ' ' || s[a] == '\t')) a++;
  while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) b--;
  return s.substr(a, b - a);
}

// RFC 9110 §5.1 token: tchar / 1*tchar — the only legal field-name alphabet.
bool uvIsToken(const std::string& name) {
  if (name.empty()) return false;
  for (const unsigned char ch : name) {
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9'))
      continue;
    switch (ch) {
      case '!': case '#': case '$': case '%': case '&': case '\'': case '*':
      case '+': case '-': case '.': case '^': case '_': case '`': case '|':
      case '~': continue;
      default: return false;
    }
  }
  return true;
}

// A field value the head may carry verbatim: no CR / LF / NUL / other control
// byte (HTAB excepted). A value that fails this could split the response.
bool uvIsSafeValue(const std::string& value) {
  for (const unsigned char ch : value)
    if ((ch < 0x20 && ch != '\t') || ch == 0x7f) return false;
  return true;
}

// Hop-by-hop and framing fields are the engine's to set (RFC 9110 §7.6.1); a
// handler-supplied one would desynchronise the connection.
bool uvIsEngineOwnedHeader(const std::string& name) {
  static const char* const owned[] = {"content-length", "connection",
                                      "transfer-encoding", "keep-alive",
                                      "upgrade", "trailer", "te"};
  for (const char* o : owned)
    if (uvIequals(name, o)) return true;
  if (name.size() > 6) {  // Proxy-Connection, Proxy-Authenticate, …
    std::string lead = name.substr(0, 6);
    for (char& ch : lead)
      if (ch >= 'A' && ch <= 'Z') ch += 32;
    if (lead == "proxy-") return true;
  }
  return false;
}

// RFC 9110 §6.6.1: an origin server with a clock MUST send Date. Formatted
// once per second per loop thread; every head in that second reuses it.
const std::string& uvDateHeader() {
  static thread_local std::time_t cachedSec = 0;
  static thread_local std::string cached;
  const std::time_t now = std::time(nullptr);
  if (now != cachedSec || cached.empty()) {
    char buf[40];
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &now);
#else
    gmtime_r(&now, &tm);
#endif
    const size_t n = std::strftime(buf, sizeof buf, "%a, %d %b %Y %H:%M:%S GMT", &tm);
    cached.assign("Date: ").append(buf, n).append("\r\n");
    cachedSec = now;
  }
  return cached;
}

// Response head with engine framing (Content-Length + Connection + Date);
// caller headers ride ahead — minus anything the engine owns, and minus any
// field whose name is not a token or whose value carries a control byte (the
// Dart runner already refuses those with a 500; this is the last line).
std::string uvBuildHead(int64_t status, const std::vector<Header>& headers,
                      int64_t contentLength, bool keepAlive,
                      int64_t keepAliveSecs) {
  std::string out;
  out.reserve(192);
  out.append("HTTP/1.1 ");
  out.append(std::to_string(status));
  out.push_back(' ');
  out.append(reasonPhrase(status));
  out.append("\r\n");
  out.append(uvDateHeader());
  for (const auto& h : headers) {
    if (uvIsEngineOwnedHeader(h.name)) continue;
    if (!uvIsToken(h.name) || !uvIsSafeValue(h.value)) continue;
    out.append(h.name);
    out.append(": ");
    out.append(h.value);
    out.append("\r\n");
  }
  // RFC 9110 §8.6: no Content-Length on 1xx / 204 (and none needed on 304, a
  // body-less answer whose length describes the entity, not this message).
  const bool bodyless =
      status == 204 || status == 304 || (status >= 100 && status < 200);
  if (!bodyless) {
    out.append("Content-Length: ");
    out.append(std::to_string(contentLength));
    out.append("\r\n");
  }
  if (keepAlive) {
    out.append("Connection: keep-alive\r\nKeep-Alive: timeout=");
    out.append(std::to_string(keepAliveSecs));
    out.append("\r\n\r\n");
  } else {
    out.append("Connection: close\r\n\r\n");
  }
  return out;
}

// The chunked-stream head: the same filtered caller headers and Date as a
// one-shot head, framed with Transfer-Encoding: chunked instead of a length.
std::string uvBuildStreamHead(int64_t status, const std::vector<Header>& headers,
                              bool keepAlive, int64_t keepAliveSecs) {
  std::string out;
  out.reserve(192);
  out.append("HTTP/1.1 ");
  out.append(std::to_string(status));
  out.push_back(' ');
  out.append(reasonPhrase(status));
  out.append("\r\n");
  out.append(uvDateHeader());
  for (const auto& h : headers) {
    if (uvIsEngineOwnedHeader(h.name)) continue;
    if (!uvIsToken(h.name) || !uvIsSafeValue(h.value)) continue;
    out.append(h.name);
    out.append(": ");
    out.append(h.value);
    out.append("\r\n");
  }
  out.append("Transfer-Encoding: chunked\r\n");
  if (keepAlive) {
    out.append("Connection: keep-alive\r\nKeep-Alive: timeout=");
    out.append(std::to_string(keepAliveSecs));
    out.append("\r\n\r\n");
  } else {
    out.append("Connection: close\r\n\r\n");
  }
  return out;
}

// A WebSocket upgrade attempt: Upgrade: websocket + Connection: upgrade.
bool uvIsWebSocketUpgrade(const ParsedHead& head) {
  const Header* up = uvFindHeader(head.headers, "upgrade");
  const Header* cn = uvFindHeader(head.headers, "connection");
  if (!up || !cn) return false;
  auto icontains = [](const std::string& s, const char* needle) {
    std::string ls = s;
    for (char& ch : ls)
      if (ch >= 'A' && ch <= 'Z') ch += 32;
    return ls.find(needle) != std::string::npos;
  };
  return icontains(up->value, "websocket") && icontains(cn->value, "upgrade");
}

// HTTP/1.1 keeps alive unless the client said close; HTTP/1.0 only on request.
bool uvClientWantsKeepAlive(const ParsedHead& head) {
  const Header* conn = uvFindHeader(head.headers, "connection");
  const bool http10 = head.version == "HTTP/1.0";
  if (conn) {
    // RFC 9110 §7.6.1: Connection is a comma-separated list of case-
    // insensitive tokens — matched whole, so `CLOSE` closes and `enclose`
    // does not.
    bool close = false, keep = false;
    size_t pos = 0;
    const std::string& v = conn->value;
    while (pos <= v.size()) {
      size_t comma = v.find(',', pos);
      if (comma == std::string::npos) comma = v.size();
      const std::string tok = uvTrim(v.substr(pos, comma - pos));
      if (uvIequals(tok, "close")) close = true;
      else if (uvIequals(tok, "keep-alive")) keep = true;
      pos = comma + 1;
    }
    if (close) return false;
    if (keep) return true;
  }
  return !http10;
}

// A short text/plain error answer (Connection: close), with a body.
std::string uvErrorResponse(int64_t status, const char* msg,
                            const std::vector<Header>& extra = {}) {
  std::vector<Header> h = extra;
  h.push_back({"Content-Type", "text/plain"});
  std::string out = uvBuildHead(status, h, (int64_t)std::strlen(msg), false, 0);
  out.append(msg);
  return out;
}


// Request-smuggling defense (RFC 9112 §6.1/§6.3.3/§3.2): reject conflicting or
// duplicated Content-Length, Content-Length with Transfer-Encoding, and a
// missing or duplicated Host on HTTP/1.1. Transfer-Encoding is parsed as the
// comma-separated, case-insensitive token list it is: the only coding this
// server implements is `chunked`, which must be the sole (hence final) coding;
// any other coding is answered 501 (§6.1), a duplicated field, an empty list,
// a repeated `chunked`, or TE on HTTP/1.0 is a 400. Returns {0, nullptr} when
// the framing is sound; `chunked` reports whether the body is chunked.
struct FramingVerdict {
  int status;          // 0 = ok, else the status to answer with
  const char* reason;  // why (diagnostics only)
};
FramingVerdict uvFraming(const ParsedHead& head, bool& chunked) {
  chunked = false;
  const std::string* cl = nullptr;
  const std::string* te = nullptr;
  bool hasHost = false, dupHost = false, dupCl = false, dupTe = false;
  for (const auto& h : head.headers) {
    if (uvIequals(h.name, "content-length")) {
      if (cl && uvTrim(*cl) != uvTrim(h.value)) return {400, "conflicting content-length"};
      if (cl) dupCl = true;
      cl = &h.value;
    } else if (uvIequals(h.name, "transfer-encoding")) {
      if (te) dupTe = true;
      te = &h.value;
    } else if (uvIequals(h.name, "host")) {
      dupHost = dupHost || hasHost;
      hasHost = true;
    }
  }
  if (dupCl) return {400, "duplicate content-length"};
  if (dupTe) return {400, "duplicate transfer-encoding"};
  if (cl && te) return {400, "content-length with transfer-encoding"};
  if (te) {
    if (head.version == "HTTP/1.0") return {400, "transfer-encoding on http/1.0"};
    int codings = 0, chunkedAt = -1;  // every coding matched whole, any case
    size_t pos = 0;
    while (pos <= te->size()) {
      size_t comma = te->find(',', pos);
      if (comma == std::string::npos) comma = te->size();
      const std::string tok = uvTrim(te->substr(pos, comma - pos));
      pos = comma + 1;
      if (tok.empty()) continue;
      ++codings;
      if (uvIequals(tok, "chunked")) {
        if (chunkedAt >= 0) return {400, "repeated chunked coding"};
        chunkedAt = codings;
      } else {
        return {501, "unsupported transfer coding"};
      }
    }
    if (codings == 0) return {400, "empty transfer-encoding"};
    chunked = true;  // exactly one coding, and it is chunked
  }
  if (cl) {  // RFC 9110 §8.6: 1*DIGIT — no sign, no space, no hex
    if (cl->empty() || cl->size() > 18) return {400, "bad content-length"};
    for (const char ch : *cl)
      if (ch < '0' || ch > '9') return {400, "bad content-length"};
  }
  if (head.version == "HTTP/1.1") {
    if (!hasHost) return {400, "missing host header"};
    if (dupHost) return {400, "duplicate host header"};
  }
  return {0, nullptr};
}

// RFC 9112 §7.1 chunk-size: 1*HEXDIG then optional `;` extensions, ending at
// the CRLF at [eol]. Returns the size, or -1 for anything else — a sign, a
// non-hex tail (`4zz`), an empty size, or more digits than an int64 holds
// (an overflow would wrap into a small, accepted size).
int64_t uvChunkSize(const std::string& buf, size_t pos, size_t eol) {
  int64_t size = 0;
  size_t digits = 0;
  while (pos < eol) {
    const char ch = buf[pos];
    int d;
    if (ch >= '0' && ch <= '9') d = ch - '0';
    else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
    else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
    else break;
    if (++digits > 15) return -1;  // 60 bits: far past any body cap
    size = (size << 4) | d;
    ++pos;
  }
  if (digits == 0) return -1;
  if (pos < eol) {  // optional chunk extensions `;name[=value]` … to the CRLF
    if (buf[pos] != ';') return -1;
    for (size_t i = pos; i < eol; ++i)
      if ((unsigned char)buf[i] < 0x20) return -1;
  }
  return size;
}

// Trailer section budget (RFC 9112 §7.1.2): bounded so an endless stream of
// trailer lines cannot park the connection or grow the buffer unbounded.
constexpr size_t kMaxTrailerBytes = 8 * 1024;
constexpr int kMaxTrailerLines = 32;

// Decodes a chunked request body from [buf] starting at [start].
// Returns: 1 complete (out = body, end = offset past the terminating CRLF),
// 0 incomplete (need more bytes), -1 malformed or over [maxBody].
// Returns 1 complete, 0 need more, -1 malformed (→400), -2 over the cap
// (→413). The cap is enforced on both the declared chunk size and the raw
// bytes buffered while waiting, so an ever-growing size line can't stall.
int decodeChunked(const std::string& buf, size_t start, int64_t maxBody,
                  std::string& out, size_t& end) {
  size_t pos = start;
  out.clear();
  // Slack over the cap for chunk framing (size lines, CRLFs, a trailer).
  const auto overCap = [&]() {
    return (int64_t)(buf.size() - start) > maxBody + 1024;
  };
  while (true) {
    const size_t eol = buf.find("\r\n", pos);
    if (eol == std::string::npos)  // size line not fully buffered
      return overCap() ? -2 : 0;
    const int64_t sz = uvChunkSize(buf, pos, eol);
    if (sz < 0) return -1;  // malformed size line
    pos = eol + 2;
    if (sz == 0) {  // terminal chunk: consume trailers to the blank line
      size_t t = pos;
      int lines = 0;
      while (true) {
        const size_t e2 = buf.find("\r\n", t);
        if (e2 == std::string::npos) {
          if (buf.size() - pos > kMaxTrailerBytes) return -1;
          return overCap() ? -2 : 0;
        }
        if (e2 == t) {
          end = t + 2;
          return 1;
        }
        if (++lines > kMaxTrailerLines || e2 - pos > kMaxTrailerBytes) return -1;
        t = e2 + 2;  // skip one trailer line
      }
    }
    if ((int64_t)out.size() + sz > maxBody) return -2;  // declared over the cap
    if (buf.size() < pos + (size_t)sz + 2)  // data + CRLF not in yet
      return overCap() ? -2 : 0;
    // The data MUST be followed by CRLF (§7.1); anything else is desync.
    if (buf[pos + (size_t)sz] != '\r' || buf[pos + (size_t)sz + 1] != '\n') return -1;
    out.append(buf, pos, (size_t)sz);
    pos += (size_t)sz + 2;
  }
}

}  // namespace

// ── Per-connection state (heap-owned; loop thread owns it) ───────────────────
struct UvReactor::Conn {
  uv_tcp_t handle{};
  Loop* lp = nullptr;
  int64_t id = 0;
  std::string buf;   // accumulated request bytes
  bool busy = false;  // a request is awaiting its answer (ordered per conn)
  bool closing = false;
  bool counted = false;    // admitted: liveConns_ (+ per-IP) incremented for it
  std::string peerIp;      // remote IP, for the per-IP cap (empty = not counted)
  std::string clientIp;    // remote IP, always set, reported to handlers
  int64_t served = 0;  // completed requests (header vs keep-alive timeout)
  int64_t reqIdInFlight = -1;  // dispatched handler awaiting respond (for 408)
  bool continueSent = false;   // sent 100 Continue for the current request
  // streamBody: the head dispatched, body bytes streamed as they arrive.
  bool streamingBody = false;
  bool streamChunked = false;  // body is chunked (decode incrementally)
  int64_t streamReqId = 0;
  Emitter* streamEmitter = nullptr;
  int64_t bodyRemaining = 0;    // Content-Length bytes still to stream
  int64_t chunkRemaining = 0;   // bytes left in the current chunk (chunked)
  bool chunkNeedCrlf = false;   // consume the CRLF after a chunk's data next
  int64_t streamMaxBody = -1;   // body cap for the streaming upload (-1 = none)
  int64_t streamBodyTotal = 0;  // decoded body bytes streamed so far (cap check)
#ifdef NITRO_SERVER_HTTP2
  // Set once this connection negotiated HTTP/2 (ALPN `h2`, or the h2c prior-
  // knowledge preface). When present, inbound bytes feed it and the HTTP/1.1
  // parser is bypassed; freed with the Conn.
  std::unique_ptr<Http2Session> h2;
#endif
  // A file answer in progress (loop thread): the next chunk is read from
  // [fileFd] at [fileOffset] once the previous write has drained, so one
  // slow reader costs one chunk of memory, never the file.
  int fileFd = -1;
  int64_t fileOffset = 0;
  int64_t fileRemaining = 0;
  bool fileKeepAlive = false;
  int64_t writePending = 0;     // bytes queued to the socket, not yet written
  std::chrono::steady_clock::time_point writeStartedAt;  // oldest pending write
  std::chrono::steady_clock::time_point lastActive;   // idle-timeout anchor
  // Streaming response (SSE / chunked / file) in progress: set by the first
  // answer byte, cleared when the answer finishes. `lastWriteAt` anchors
  // streamIdleTimeout — a stream the handler stopped feeding is closed.
  bool responseStarted = false;
  std::chrono::steady_clock::time_point lastWriteAt;
  std::chrono::steady_clock::time_point openedAt;     // accepted (max age)
  std::chrono::steady_clock::time_point reqDeadline;  // valid while busy+handler
  bool hasDeadline = false;
  bool bodyPending = false;  // head parsed, body still arriving (stall window)
  bool headPending = false;  // first byte of a request head seen, head not complete
  std::chrono::steady_clock::time_point headStartedAt;  // anchors headerTimeout
  bool proxyDone = false;    // PROXY protocol header consumed (cfg.proxyProtocol)
  std::string proxyBuf;      // bytes held until the PROXY header is complete
  bool ageExpired = false;   // past maxConnectionAge: next answer closes
  bool wsPingSent = false;   // liveness ping out, no frame back yet
  // WebSocket state (set after a successful upgrade).
  bool ws = false;
  Emitter* wsEmitter = nullptr;  // the sink this session's messages go to
  std::string wsMsg;      // reassembly buffer for a fragmented message
  int wsMsgOpcode = -1;   // opcode being reassembled; -1 = no message in flight
  bool wsMsgCompressed = false;  // the message's first frame had RSV1 (deflate)
  bool wsClosing = false;  // a close frame was sent; drop further frames
  bool deflate = false;    // permessage-deflate negotiated on this session
#ifdef NITRO_SERVER_TLS
  SSL* ssl = nullptr;        // null on a plaintext connection
  BIO* rbio = nullptr;       // ciphertext in  (socket → SSL)
  BIO* wbio = nullptr;       // ciphertext out (SSL → socket)
  bool tlsHandshakeDone = false;
#endif
};

UvReactor::~UvReactor() { stop(); }

StatusResult UvReactor::registerRoute(const RouteEntry& e) {
  if (!router_.add(e)) return {ErrorKind::BadRequest, "invalid route", 0};
  return {};
}

StatusResult UvReactor::registerStaticRoute(const RouteEntry& e) {
  if (!router_.add(e)) return {ErrorKind::BadRequest, "invalid route", 0};
  return {};
}

StatusResult UvReactor::registerRoute(Method method,
                                      const std::string& customMethod,
                                      const std::string& pattern,
                                      int64_t timeoutMs, bool isWebSocket,
                                      bool streamBody, int64_t maxBodyBytes,
                                      const std::string& wsProtocols) {
  RouteEntry e;
  e.method = method;
  e.customMethod = customMethod;
  e.pattern = pattern;
  e.timeoutMs = timeoutMs;
  e.isWebSocket = isWebSocket;
  e.streamBody = streamBody;
  e.maxBodyBytes = maxBodyBytes;
  for (size_t b = 0; b <= wsProtocols.size();) {  // comma-separated, trimmed
    size_t c = wsProtocols.find(',', b);
    if (c == std::string::npos) c = wsProtocols.size();
    size_t s = b, en = c;
    while (s < en && wsProtocols[s] == ' ') s++;
    while (en > s && wsProtocols[en - 1] == ' ') en--;
    if (en > s) e.wsProtocols.emplace_back(wsProtocols.substr(s, en - s));
    b = c + 1;
  }
  return registerRoute(e);
}

StatusResult UvReactor::registerStaticRoute(
    Method method, const std::string& customMethod, const std::string& pattern,
    int64_t status, const std::vector<Header>& headers, const uint8_t* body,
    size_t bodyLen) {
  RouteEntry e;
  e.method = method;
  e.customMethod = customMethod;
  e.pattern = pattern;
  auto sr = std::make_shared<StaticResponse>();
  sr->status = status;
  sr->headers = headers;
  if (body && bodyLen) sr->body.assign((const char*)body, bodyLen);
  e.staticResponse = std::move(sr);
  return registerStaticRoute(e);
}

StatusResult UvReactor::unregisterRoute(Method method,
                                        const std::string& customMethod,
                                        const std::string& pattern) {
  if (!router_.remove(method, customMethod, pattern))
    return {ErrorKind::RouteNotFound, "no such route: " + pattern, 0};
  return {};
}

void UvReactor::setEmitter(Emitter* e) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  emitters_.clear();
  if (e) emitters_.push_back(e);
}

void UvReactor::addEmitter(Emitter* e) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  for (Emitter* x : emitters_)
    if (x == e) return;
  emitters_.push_back(e);
}

bool UvReactor::removeEmitter(Emitter* e) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  const size_t before = emitters_.size();
  emitters_.erase(std::remove(emitters_.begin(), emitters_.end(), e),
                  emitters_.end());
  return emitters_.size() != before;
}

size_t UvReactor::emitterCountForTesting() {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  return emitters_.size();
}

Emitter* UvReactor::nextEmitter() {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  if (emitters_.empty()) return nullptr;
  size_t w = dispatchWidth_.load(std::memory_order_relaxed);
  if (w == 0 || w > emitters_.size()) w = emitters_.size();
  const uint64_t i = emitterRr_.fetch_add(1);
  // Dispatch across the MOST-RECENTLY-registered `w` emitters, not the first
  // `w`. Emitters are appended in registration order, so the current
  // incarnation's sinks are always at the back. A hot restart reuses a server
  // key and re-resolves an instance whose predecessor's (now-dead) emitter is
  // still registered at the front until its bridge is finalized; selecting from
  // the front (`i % w`) could hand a request to that dead isolate, which never
  // responds (the client then hangs to its timeout). Selecting from the back
  // keeps the live sink; when every emitter is current (w == size, the common
  // case) this is identical to round-robining the whole list.
  return emitters_[emitters_.size() - w + (i % w)];
}

void UvReactor::broadcastEvent(ServerEventKind kind, int64_t requestId,
                               const std::string& message) {
  std::lock_guard<std::mutex> lk(emitterMutex_);
  for (Emitter* e : emitters_) e->emitEvent(kind, requestId, message);
}

// Read on the caller's thread (fine — not a loop thread), answer like a body.
// Loop thread: read the next chunk of a file answer and write it; the last
// chunk finishes the response. A read failure mid-body breaks the framing,
// so the connection is closed rather than left desynchronised.
void UvReactor::continueFileSend(Conn* c) {
  if (c->fileFd < 0 || c->closing) return;
  constexpr int64_t kChunk = 256 * 1024;
  const int64_t want = std::min<int64_t>(kChunk, c->fileRemaining);
  std::string chunk((size_t)want, '\0');
  uv_buf_t buf = uv_buf_init(chunk.data(), (unsigned)want);
  uv_fs_t req;
  const int got = uv_fs_read(nullptr, &req, c->fileFd, &buf, 1, c->fileOffset, nullptr);
  uv_fs_req_cleanup(&req);
  if (got <= 0) {  // EOF before the promised length, or an I/O error
    uv_fs_t closeReq;
    uv_fs_close(nullptr, &closeReq, c->fileFd, nullptr);
    uv_fs_req_cleanup(&closeReq);
    c->fileFd = -1;
    broadcastEvent(ServerEventKind::ClientError, c->id, "file answer truncated");
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  chunk.resize((size_t)got);
  c->fileOffset += got;
  c->fileRemaining -= got;
  const bool last = c->fileRemaining <= 0;
  if (last) {
    uv_fs_t closeReq;
    uv_fs_close(nullptr, &closeReq, c->fileFd, nullptr);
    uv_fs_req_cleanup(&closeReq);
    c->fileFd = -1;
  }
  writeAnswer(c, std::move(chunk), c->fileKeepAlive, /*finish=*/last);
}

// Any thread: answer with a byte range of a regular file. The head goes out
// with the exact Content-Length; the bytes follow in 256 KiB chunks read on
// the connection's loop thread as each write drains (see continueFileSend),
// so a slow reader never holds more than one chunk and a file larger than
// memory is fine. Anything that is not a regular file is a 404.
void UvReactor::respondFile(int64_t id, int64_t status,
                            const std::vector<Header>& headers,
                            const std::string& path, int64_t offset,
                            int64_t length) {
  if (!running_.load()) return;  // no-op after stop() (see respond)
  auto notFound = [&]() {
    static const char msg[] = "not found";
    std::vector<Header> h{{"Content-Type", "text/plain"}};
    respond(id, 404, h, (const uint8_t*)msg, sizeof(msg) - 1);
  };
  uv_fs_t openReq;
  const int fd = uv_fs_open(nullptr, &openReq, path.c_str(), UV_FS_O_RDONLY, 0, nullptr);
  uv_fs_req_cleanup(&openReq);
  if (fd < 0) {
    notFound();
    return;
  }
  auto closeFd = [&]() {
    uv_fs_t closeReq;
    uv_fs_close(nullptr, &closeReq, fd, nullptr);
    uv_fs_req_cleanup(&closeReq);
  };
  uv_fs_t statReq;
  if (uv_fs_fstat(nullptr, &statReq, fd, nullptr) != 0 ||
      (statReq.statbuf.st_mode & S_IFMT) != S_IFREG) {  // a directory, FIFO, device
    uv_fs_req_cleanup(&statReq);
    closeFd();
    notFound();
    return;
  }
  const int64_t size = (int64_t)statReq.statbuf.st_size;
  uv_fs_req_cleanup(&statReq);
  if (offset < 0) offset = 0;
  if (offset > size) {  // a range that starts past the end has no bytes → 404
    closeFd();
    notFound();
    return;
  }
  const int64_t end = length < 0 ? size : std::min<int64_t>(size, offset + length);
  const int64_t n = end > offset ? end - offset : 0;
  ReqLoc loc;
  if (!lookupReq(id, loc, /*erase=*/false)) {
    closeFd();
    return;  // unknown / already answered
  }
  // HEAD, an empty range, or an h2 stream (whose session wants the body
  // whole: h2 responses are buffered per stream, see doc/http2.md): hand the
  // bytes to respond() — bounded by the range the handler asked for.
  if (loc.isHead || n == 0 || loc.isH2) {
    std::string body;
    if (!loc.isHead && n > 0) {
      body.assign((size_t)n, '\0');
      uv_buf_t buf = uv_buf_init(body.data(), (unsigned)n);
      uv_fs_t readReq;
      const int got = uv_fs_read(nullptr, &readReq, fd, &buf, 1, offset, nullptr);
      uv_fs_req_cleanup(&readReq);
      if (got != n) body.clear();
    }
    closeFd();
    // respond() frames Content-Length from bodyLen; for HEAD that is the
    // entity length with no bytes appended.
    respond(id, status, headers, (const uint8_t*)body.data(),
            loc.isHead ? (size_t)n : body.size());
    return;
  }
  if (!lookupReq(id, loc, /*erase=*/true)) {
    closeFd();
    return;
  }
  completions_.fetch_add(1, std::memory_order_release);
  const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
  Loop* lp = loops_[loc.loopIdx].get();
  Loop::Pending p;
  p.connId = loc.connId;
  p.bytes = uvBuildHead(status, headers, n, loc.keepAlive, kaSecs);
  p.keepAlive = loc.keepAlive;
  p.finish = false;
  p.fileFd = fd;
  p.fileOffset = offset;
  p.fileRemaining = n;
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back(std::move(p));
  }
  uv_async_send(&lp->async);
}

MatchResult UvReactor::match(Method m, const std::string& custom,
                             const std::string& path) const {
  return router_.match(m, custom, path);
}

StatusResult UvReactor::start(int loops) {
  if (running_.exchange(true)) return {ErrorKind::AlreadyRunning, "running", 0};
#ifdef NITRO_SERVER_TLS
  if (cfg_.tlsRequested) {
    const StatusResult r = setupTls();
    if (r.kind != ErrorKind::None) {
      running_.store(false);
      return r;
    }
  }
#endif
  unsigned cores = std::thread::hardware_concurrency();
  int n = loops > 0 ? loops : (cores == 0 ? 4 : (int)cores);
  // A positive ServerConfig.workerThreads caps the number of event loops below
  // the core count (0 = one loop per core, the default); an explicit
  // start(loops) still wins. More loops than cores only oversubscribes, so the
  // cap is one-directional.
  if (loops <= 0 && cfg_.workerThreads > 0 && (int)cfg_.workerThreads < n)
    n = (int)cfg_.workerThreads;
  // Manual override: pin the dispatch width and disable the adaptive
  // controller (for benchmarking a fixed width). Otherwise the controller
  // starts concentrated (width 1, so its first measurement is a valid
  // single-isolate reading) and sets the width at runtime from there.
  if (const char* dw = std::getenv("NITRO_DISPATCH")) {
    const long v = std::strtol(dw, nullptr, 10);
    if (v >= 0) {
      dispatchWidth_.store((size_t)v, std::memory_order_relaxed);
      ctlEnabled_.store(false, std::memory_order_relaxed);
    }
  } else {
    dispatchWidth_.store(1, std::memory_order_relaxed);
  }
  boundPort_.store(cfg_.port);
  const int backlog = cfg_.backlog > 0 ? (int)cfg_.backlog : 128;

  // Reserve a fixed port up front so a second server on it fails (SO_REUSEPORT
  // would otherwise let both bind). Port 0 is reserved after the OS assigns it.
  if (cfg_.port != 0) {
    std::lock_guard<std::mutex> lk(boundPortsMutex());
    if (!boundPorts().insert((int)cfg_.port).second) {
      running_.store(false);
      return {ErrorKind::BindFailed, "port already in use", 0};
    }
    reservedPort_ = (int)cfg_.port;
  }

#ifndef _WIN32
  auto releaseAndFail = [&](std::vector<int>& fds,
                            const char* msg) -> StatusResult {
    for (int fd : fds) close(fd);
    if (reservedPort_ != 0) {
      std::lock_guard<std::mutex> lk(boundPortsMutex());
      boundPorts().erase(reservedPort_);
      reservedPort_ = 0;
    }
    running_.store(false);
    return {ErrorKind::BindFailed, msg, 0};
  };
#endif

#ifdef _WIN32
  // Windows has no SO_REUSEPORT, so the "N listeners sharing one port" model
  // doesn't apply: bind a single libuv listener on one loop. libuv (IOCP)
  // initializes Winsock and owns the accept socket, so there is no raw socket
  // to open. Loses the per-core listener fan-out, but is correct and keeps the
  // rest of the reactor (per-conn handling, TLS, WebSocket) unchanged.
  (void)n;
  {
    auto lp = std::make_unique<Loop>();
    lp->owner = this;
    uv_loop_init(&lp->loop);
    lp->async.data = lp.get();
    uv_async_init(&lp->loop, &lp->async, &UvReactor::onAsync);
    lp->sweep.data = lp.get();
    uv_timer_init(&lp->loop, &lp->sweep);
    uv_timer_start(&lp->sweep, &UvReactor::onSweep, 100, 100);
    lp->server.data = lp.get();
    uv_tcp_init(&lp->loop, &lp->server);
    auto winFail = [&](const char* msg) -> StatusResult {
      uv_close((uv_handle_t*)&lp->server, nullptr);
      uv_close((uv_handle_t*)&lp->async, nullptr);
      uv_close((uv_handle_t*)&lp->sweep, nullptr);
      uv_run(&lp->loop, UV_RUN_DEFAULT);
      uv_loop_close(&lp->loop);
      if (reservedPort_ != 0) {
        std::lock_guard<std::mutex> lk(boundPortsMutex());
        boundPorts().erase(reservedPort_);
        reservedPort_ = 0;
      }
      running_.store(false);
      return {ErrorKind::BindFailed, msg, 0};
    };
    sockaddr_storage ss;
    socklen_t sslen;
    if (uvBuildAddr(cfg_.host, (int)cfg_.port, ss, sslen) < 0)
      return winFail("invalid host");
    if (uv_tcp_bind(&lp->server, (const sockaddr*)&ss, 0) != 0)
      return winFail("bind failed");
    sockaddr_storage bound{};
    int bl = (int)sizeof(bound);
    uv_tcp_getsockname(&lp->server, (sockaddr*)&bound, &bl);
    boundPort_.store(uvPortOf(bound));
    cfg_.port = boundPort_.load();
    if (reservedPort_ == 0) {
      std::lock_guard<std::mutex> lk(boundPortsMutex());
      boundPorts().insert((int)boundPort_.load());
      reservedPort_ = (int)boundPort_.load();
    }
    if (uv_listen((uv_stream_t*)&lp->server, backlog, &UvReactor::onConnection) != 0)
      return winFail("listen failed");
    loops_.push_back(std::move(lp));
  }
#else
  // Phase one: bind every listener socket. A failure here cleans up with no
  // libuv resources yet created.
  std::vector<int> fds;
  for (int i = 0; i < n; i++) {
    sockaddr_storage ss;
    socklen_t sslen;
    const int family = uvBuildAddr(cfg_.host, (int)cfg_.port, ss, sslen);
    if (family < 0) return releaseAndFail(fds, "invalid host");
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return releaseAndFail(fds, "socket failed");
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    if (bind(fd, (sockaddr*)&ss, sslen) != 0) {
      close(fd);
      return releaseAndFail(fds, "bind failed");
    }
    if (i == 0) {  // read the OS-assigned port; pin it for the rest
      sockaddr_storage bound;
      socklen_t bl = sizeof(bound);
      getsockname(fd, (sockaddr*)&bound, &bl);
      boundPort_.store(uvPortOf(bound));
      cfg_.port = boundPort_.load();
      if (reservedPort_ == 0) {
        std::lock_guard<std::mutex> lk(boundPortsMutex());
        boundPorts().insert((int)boundPort_.load());
        reservedPort_ = (int)boundPort_.load();
      }
    }
    if (listen(fd, backlog) != 0) {
      close(fd);
      return releaseAndFail(fds, "listen failed");
    }
    fds.push_back(fd);
  }

  // Phase two: one libuv loop per bound socket, then run each on its thread.
  for (int i = 0; i < n; i++) {
    auto lp = std::make_unique<Loop>();
    lp->owner = this;
    uv_loop_init(&lp->loop);
    lp->async.data = lp.get();
    uv_async_init(&lp->loop, &lp->async, &UvReactor::onAsync);
    lp->sweep.data = lp.get();
    uv_timer_init(&lp->loop, &lp->sweep);
    uv_timer_start(&lp->sweep, &UvReactor::onSweep, 100, 100);
    lp->fd = fds[i];
    lp->server.data = lp.get();
    uv_tcp_init(&lp->loop, &lp->server);
    uv_tcp_open(&lp->server, fds[i]);
    uv_listen((uv_stream_t*)&lp->server, backlog, &UvReactor::onConnection);
    loops_.push_back(std::move(lp));
  }
#endif  // _WIN32
  for (auto& lp : loops_) {
    Loop* raw = lp.get();
    raw->thread = std::thread([this, raw] { runLoop(raw); });
  }
  return {ErrorKind::None, "", boundPort_.load()};  // Dart reads the bound port
}

void UvReactor::runLoop(Loop* lp) { uv_run(&lp->loop, UV_RUN_DEFAULT); }

void UvReactor::onConnection(uv_stream_t* server, int status) {
  if (status < 0) return;
  Loop* lp = (Loop*)server->data;
  UvReactor* self = lp->owner;
  Conn* c = new Conn();
  c->lp = lp;
  c->id = self->nextId_.fetch_add(1);
  c->handle.data = c;
  uv_tcp_init(&lp->loop, &c->handle);
  if (uv_accept(server, (uv_stream_t*)&c->handle) != 0) {
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  // Peer IP, for the per-IP cap.
  std::string peerIp;
  {
    sockaddr_storage ss;
    int nl = (int)sizeof(ss);
    if (uv_tcp_getpeername(&c->handle, (sockaddr*)&ss, &nl) == 0) {
      char ip[64] = {0};
      if (ss.ss_family == AF_INET6)
        uv_ip6_name(reinterpret_cast<const sockaddr_in6*>(&ss), ip, sizeof(ip));
      else
        uv_ip4_name(reinterpret_cast<const sockaddr_in*>(&ss), ip, sizeof(ip));
      peerIp = ip;
      // A dual-stack listener (`::`) reports IPv4 peers as `::ffff:a.b.c.d`;
      // present them as IPv4 so per-IP caps, trusted-proxy CIDRs and logs
      // see one address family.
      if (peerIp.size() > 7 && peerIp.compare(0, 7, "::ffff:") == 0 &&
          peerIp.find('.') != std::string::npos)
        peerIp.erase(0, 7);
    }
  }
  c->clientIp = peerIp;  // reported to handlers; independent of the per-IP cap
  // Admit or refuse: over the global cap, while draining, or over the per-IP
  // cap, accept then close so the backlog drains instead of wedging. Counting
  // happens here (guarded — accepts land on every loop thread) and is released
  // in onCloseConn iff `counted`, so every refuse path stays symmetric.
  const int64_t maxConn = self->cfg_.maxConnections;
  const int64_t maxPerIp = self->cfg_.maxConnectionsPerIp;
  bool refuse = self->draining_.load() ||
                (maxConn > 0 && self->liveConns_.load() >= maxConn);
  if (!refuse && maxPerIp > 0 && !peerIp.empty()) {
    std::lock_guard<std::mutex> lk(self->ipMutex_);
    if (self->ipCounts_[peerIp] >= maxPerIp) {
      refuse = true;
    } else {
      self->ipCounts_[peerIp] += 1;
      c->peerIp = peerIp;  // marks the per-IP slot to release on close
    }
  }
  if (refuse) {
    c->closing = true;
    // While draining, answer the accepted backlog with a clean 503 (and
    // `Connection: close`) so clients get a real response instead of a bare
    // FIN. Plain sockets only — pre-handshake TLS cannot carry a plaintext
    // reply, so a TLS drain just closes. The write callback frees the request
    // and closes the connection.
    if (self->draining_.load() &&
        self->sslCtx_.load(std::memory_order_acquire) == nullptr) {
      static const std::string k503 =
          "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n"
          "Content-Length: 0\r\n\r\n";
      auto* req = new uv_write_t;
      req->data = c;
      uv_buf_t b = uv_buf_init(const_cast<char*>(k503.data()), k503.size());
      const int rc = uv_write(
          req, (uv_stream_t*)&c->handle, &b, 1, [](uv_write_t* w, int) {
            auto* cc = static_cast<Conn*>(w->data);
            delete w;
            uv_close((uv_handle_t*)&cc->handle, &UvReactor::onCloseConn);
          });
      if (rc != 0) {
        delete req;
        uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      }
      return;
    }
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  c->counted = true;
  self->liveConns_.fetch_add(1);
  uv_tcp_nodelay(&c->handle, 1);
  c->lastActive = Clock::now();
  c->openedAt = c->lastActive;
#ifdef NITRO_SERVER_TLS
  if (self->sslCtx_.load(std::memory_order_acquire) && !self->tlsInit(c)) {
    c->closing = true;
    uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
#endif
  lp->conns[c->id] = c;
  uv_read_start((uv_stream_t*)&c->handle, &UvReactor::allocCb,
                &UvReactor::readCb);
}

void UvReactor::allocCb(uv_handle_t* h, size_t suggested, uv_buf_t* b) {
  (void)h;
  static thread_local std::vector<char> scratch;
  if (scratch.size() < suggested) scratch.resize(suggested < 65536 ? 65536 : suggested);
  *b = uv_buf_init(scratch.data(), (unsigned)scratch.size());
}

// Release a connection's admission accounting (global + per-IP). Idempotent:
// clears the markers so a later onCloseConn won't double-release. Called early
// when a peer half-closes, and again at teardown.
void UvReactor::releaseAdmission(Conn* c) {
  if (c->counted) {
    liveConns_.fetch_sub(1);
    c->counted = false;
  }
  if (!c->peerIp.empty()) {
    std::lock_guard<std::mutex> lk(ipMutex_);
    auto it = ipCounts_.find(c->peerIp);
    if (it != ipCounts_.end() && --it->second <= 0) ipCounts_.erase(it);
    c->peerIp.clear();
  }
}

void UvReactor::onCloseConn(uv_handle_t* h) {
  Conn* c = (Conn*)h;
  if (c->fileFd >= 0) {  // a file answer cut short by the peer
    uv_fs_t closeReq;
    uv_fs_close(nullptr, &closeReq, c->fileFd, nullptr);
    uv_fs_req_cleanup(&closeReq);
    c->fileFd = -1;
  }
  if (c->lp) {
    UvReactor* self = c->lp->owner;
    c->lp->conns.erase(c->id);
    self->releaseAdmission(c);  // global + per-IP (no-op if already released)
    if (c->ws) {
      {
        std::lock_guard<std::mutex> lk(self->reqMutex_);
        self->wsConnLoop_.erase(c->id);
      }
      self->pending_.dropPayloads(c->id);  // free un-acked WS message payloads
    } else {
      // A connection closing with in-flight request state — a long streaming
      // response, an h2 stream, or a handler yet to answer — must not strand
      // its reqLoc_ / h2 accumulator entries: a client that disconnects
      // mid-stream would otherwise leak them until the reactor is destroyed
      // (an h1 stream's id leaves reqIdInFlight once startStream opens, and an
      // h2 conn carries several stream ids, so scan by connId).
      // ponytail: O(reqLoc_) per close; add a connId->ids index if
      // streaming-connection churn ever makes this hot.
      std::vector<int64_t> dropped;
      {
        std::lock_guard<std::mutex> lk(self->reqMutex_);
        for (auto it = self->reqLoc_.begin(); it != self->reqLoc_.end();) {
          if (it->second.connId == c->id) {
            dropped.push_back(it->first);
#ifdef NITRO_SERVER_HTTP2
            self->h2StreamAccum_.erase(it->first);
#endif
            it = self->reqLoc_.erase(it);
          } else {
            ++it;
          }
        }
      }
      // Tell the Dart runner each in-flight request's client is gone so it
      // cancels the handler's outbound stream subscription — an indefinite
      // source (an SSE `Stream.periodic`) would otherwise produce forever.
      // Broadcast outside reqMutex_ (broadcastEvent fans out to the emitters).
      for (const int64_t rid : dropped)
        self->broadcastEvent(ServerEventKind::ClientDisconnect, rid, "");
    }
  }
#ifdef NITRO_SERVER_TLS
  if (c->ssl) SSL_free(c->ssl);  // frees the attached rbio + wbio too
#endif
  delete c;
}

// HAProxy PROXY protocol, v1 (text) and v2 (binary). Returns 1 with [used]
// bytes consumed and [ip] set to the client address the header names (empty
// for LOCAL / UNKNOWN: keep the socket peer), 0 when more bytes are needed,
// -1 for anything that is not a well-formed header.
static int uvParseProxyHeader(const std::string& buf, std::string& ip,
                              size_t& used) {
  static const char kV2Sig[12] = {'\r', '\n', '\r', '\n', 0, '\r', '\n',
                                  'Q', 'U', 'I', 'T', '\n'};
  ip.clear();
  used = 0;
  const size_t n = buf.size();
  // v2: 12-byte signature, version/command, family, 2-byte length, addresses.
  if (n >= 12 && std::memcmp(buf.data(), kV2Sig, 12) == 0) {
    if (n < 16) return 0;
    const unsigned char verCmd = (unsigned char)buf[12];
    const unsigned char fam = (unsigned char)buf[13];
    const size_t len = ((size_t)(unsigned char)buf[14] << 8) | (unsigned char)buf[15];
    if ((verCmd & 0xF0) != 0x20) return -1;
    if (n < 16 + len) return 0;
    used = 16 + len;
    const unsigned char cmd = verCmd & 0x0F;
    if (cmd == 0x0) return 1;  // LOCAL: health check from the proxy itself
    if (cmd != 0x1) return -1;
    const unsigned char af = fam >> 4;
    const unsigned char* a = (const unsigned char*)buf.data() + 16;
    char text[INET6_ADDRSTRLEN] = {0};
    if (af == 0x1) {  // AF_INET: src(4) dst(4) sport(2) dport(2)
      if (len < 12 || !inet_ntop(AF_INET, a, text, sizeof text)) return -1;
      ip = text;
    } else if (af == 0x2) {  // AF_INET6: src(16) dst(16) sport dport
      if (len < 36 || !inet_ntop(AF_INET6, a, text, sizeof text)) return -1;
      ip = text;
    } else if (af != 0x0) {  // AF_UNIX / unknown: no usable address
      return -1;
    }
    return 1;
  }
  // v1: "PROXY TCP4|TCP6|UNKNOWN src dst sport dport\r\n", at most 107 bytes.
  static const char kV1[6] = {'P', 'R', 'O', 'X', 'Y', ' '};
  const size_t cmp = n < 6 ? n : 6;
  if (std::memcmp(buf.data(), kV1, cmp) != 0) {
    // Could still be the first bytes of a v2 signature.
    if (n < 12 && std::memcmp(buf.data(), kV2Sig, n) == 0) return 0;
    return -1;
  }
  const size_t eol = buf.find("\r\n");
  if (eol == std::string::npos) return n >= 108 ? -1 : 0;
  if (eol > 106) return -1;
  used = eol + 2;
  std::vector<std::string> tok;
  size_t pos = 6;
  while (pos <= eol) {
    size_t sp = buf.find(' ', pos);
    if (sp == std::string::npos || sp > eol) sp = eol;
    tok.push_back(buf.substr(pos, sp - pos));
    pos = sp + 1;
  }
  if (tok.empty()) return -1;
  if (tok[0] == "UNKNOWN") return 1;  // keep the socket peer
  if (tok.size() != 5) return -1;
  const int af = tok[0] == "TCP4" ? AF_INET : tok[0] == "TCP6" ? AF_INET6 : -1;
  if (af < 0) return -1;
  unsigned char raw[16];
  if (inet_pton(af, tok[1].c_str(), raw) != 1 ||
      inet_pton(af, tok[2].c_str(), raw) != 1)
    return -1;
  for (int i = 3; i < 5; i++) {
    if (tok[i].empty() || tok[i].size() > 5) return -1;
    for (const char ch : tok[i])
      if (ch < '0' || ch > '9') return -1;
    if (std::stoi(tok[i]) > 65535) return -1;
  }
  ip = tok[1];
  return 1;
}

void UvReactor::readCb(uv_stream_t* s, ssize_t nread, const uv_buf_t* b) {
  Conn* c = (Conn*)s;
  if (nread < 0) {
    // A head buffered with an incomplete body at EOF is a truncated request:
    // answer 400 before closing (plaintext only; TLS just closes).
    bool tls = false;
#ifdef NITRO_SERVER_TLS
    tls = c->ssl != nullptr;
#endif
    if (!c->busy && !c->ws && !c->closing && !tls &&
        c->buf.find("\r\n\r\n") != std::string::npos) {
      c->lp->owner->writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
      return;
    }
    c->closing = true;
    uv_close((uv_handle_t*)s, &UvReactor::onCloseConn);
    return;
  }
  if (nread == 0) return;
  // Progress on the wire — a body still arriving, a WebSocket frame or pong —
  // is activity: the stall/idle windows restart from here.
  c->lastActive = Clock::now();
  c->wsPingSent = false;
  const char* data = b->base;
  size_t len = (size_t)nread;
  std::string carry;
  // PROXY protocol: the very first bytes name the real client; they precede
  // the TLS handshake and the HTTP/2 preface alike, so they are consumed here
  // before either path sees the stream.
  UvReactor* self = c->lp->owner;
  if (self->cfg_.proxyProtocol && !c->proxyDone) {
    c->proxyBuf.append(data, len);
    std::string ip;
    size_t used = 0;
    const int r = uvParseProxyHeader(c->proxyBuf, ip, used);
    if (r == 0) {
      // v2 is 16 bytes + a 16-bit length (TLVs included): 65551 at most.
      if (c->proxyBuf.size() > 16 + 65535) {
        c->closing = true;
        uv_close((uv_handle_t*)s, &UvReactor::onCloseConn);
      }
      return;
    }
    if (r < 0) {
      self->broadcastEvent(ServerEventKind::ClientError, c->id,
                           "invalid PROXY protocol header");
      c->closing = true;
      uv_close((uv_handle_t*)s, &UvReactor::onCloseConn);
      return;
    }
    c->proxyDone = true;
    if (!ip.empty()) {
      c->clientIp = ip;
      // The per-IP cap counted the socket peer (the proxy) at accept; move
      // the slot to the client the header names so the cap means clients,
      // not the balancer. Over the cap for that client: refuse now.
      if (self->cfg_.maxConnectionsPerIp > 0 && ip != c->peerIp) {
        bool over = false;
        {
          std::lock_guard<std::mutex> lk(self->ipMutex_);
          if (!c->peerIp.empty()) {
            auto it = self->ipCounts_.find(c->peerIp);
            if (it != self->ipCounts_.end() && --it->second <= 0)
              self->ipCounts_.erase(it);
            c->peerIp.clear();
          }
          auto& count = self->ipCounts_[ip];
          if (count >= self->cfg_.maxConnectionsPerIp) {
            over = true;
            if (count == 0) self->ipCounts_.erase(ip);
          } else {
            count += 1;
            c->peerIp = ip;
          }
        }
        if (over) {
          c->closing = true;
          uv_close((uv_handle_t*)s, &UvReactor::onCloseConn);
          return;
        }
      }
    }
    carry.assign(c->proxyBuf, used, std::string::npos);
    c->proxyBuf.clear();
    c->proxyBuf.shrink_to_fit();
    if (carry.empty()) return;
    data = carry.data();
    len = carry.size();
  }
#ifdef NITRO_SERVER_TLS
  if (c->ssl) {
    self->tlsOnRead(c, data, len);  // decrypts + processes
    return;
  }
#endif
  c->buf.append(data, len);
  if (self->overBusyBuffer(c)) return;
  if (c->streamingBody) {
    if (c->streamChunked) c->lp->owner->emitStreamChunked(c);
    else c->lp->owner->emitStreamBytes(c);
  } else if (c->ws) {
    c->lp->owner->wsProcess(c);
  } else {
    c->lp->owner->processConn(c);
  }
}

// Loop thread: stream buffered body bytes to a streamBody handler, ending the
// stream when the Content-Length is exhausted.
void UvReactor::emitStreamBytes(Conn* c) {
  const size_t avail =
      std::min<size_t>(c->buf.size(), (size_t)c->bodyRemaining);
  if (avail > 0 && c->streamEmitter) {
    auto* payload = (uint8_t*)std::malloc(avail);
    if (payload) {
      std::memcpy(payload, c->buf.data(), avail);
      pending_.trackPayload(c->streamReqId, payload);
      c->streamEmitter->emitBodyData(c->streamReqId, payload, avail);
    }
    c->buf.erase(0, avail);
    c->bodyRemaining -= (int64_t)avail;
  }
  if (c->bodyRemaining == 0) {
    if (c->streamEmitter) c->streamEmitter->emitBodyEnd(c->streamReqId);
    c->streamingBody = false;  // stays busy until respond() lands
  }
}

// Loop thread: incrementally decode a chunked streamBody upload, streaming
// partial chunk data as it arrives (a chunk may be larger than one read) and
// ending on the terminal 0-chunk. chunkRemaining/chunkNeedCrlf persist across
// reads.
void UvReactor::emitStreamChunked(Conn* c) {
  std::string out;
  bool done = false, malformed = false;
  while (true) {
    if (c->chunkNeedCrlf) {  // trailing CRLF after a chunk's data
      if (c->buf.size() < 2) break;
      if (c->buf[0] != '\r' || c->buf[1] != '\n') { malformed = true; break; }
      c->buf.erase(0, 2);
      c->chunkNeedCrlf = false;
    }
    if (c->chunkRemaining == 0) {  // read the next size line
      const size_t eol = c->buf.find("\r\n");
      if (eol == std::string::npos) {
        if (c->buf.size() > kMaxTrailerBytes) malformed = true;  // endless size line
        break;
      }
      const int64_t sz = uvChunkSize(c->buf, 0, eol);
      if (sz < 0) { malformed = true; break; }
      if (sz == 0) {  // terminal: consume the size line + trailers to a blank line
        size_t t = eol + 2;
        bool ok = false;
        int lines = 0;
        while (true) {
          const size_t e2 = c->buf.find("\r\n", t);
          if (e2 == std::string::npos) {
            if (c->buf.size() - (eol + 2) > kMaxTrailerBytes) malformed = true;
            break;
          }
          if (e2 == t) { c->buf.erase(0, t + 2); ok = true; break; }
          if (++lines > kMaxTrailerLines) { malformed = true; break; }
          t = e2 + 2;
        }
        if (ok) done = true;
        break;
      }
      c->buf.erase(0, eol + 2);  // consume the size line
      c->chunkRemaining = sz;
    }
    if (c->chunkRemaining > 0) {  // stream whatever chunk data is buffered
      const size_t take =
          std::min<size_t>(c->buf.size(), (size_t)c->chunkRemaining);
      if (take == 0) break;
      out.append(c->buf, 0, take);
      c->buf.erase(0, take);
      c->chunkRemaining -= (int64_t)take;
      if (c->chunkRemaining == 0) c->chunkNeedCrlf = true;
      c->streamBodyTotal += (int64_t)take;
      if (c->streamMaxBody >= 0 && c->streamBodyTotal > c->streamMaxBody) {
        abortStreamTooLarge(c);  // 413 + error the handler's stream, then close
        return;
      }
    }
  }
  if (malformed) {
    c->streamingBody = false;
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  if (!out.empty() && c->streamEmitter) {
    auto* payload = (uint8_t*)std::malloc(out.size());
    if (payload) {
      std::memcpy(payload, out.data(), out.size());
      pending_.trackPayload(c->streamReqId, payload);
      c->streamEmitter->emitBodyData(c->streamReqId, payload, out.size());
    }
  }
  if (done) {
    if (c->streamEmitter) c->streamEmitter->emitBodyEnd(c->streamReqId);
    c->streamingBody = false;
  }
}

// Loop thread: a chunked streamBody upload exceeded its body cap. The head was
// already dispatched, so (unlike the non-stream path's pre-dispatch 413) we
// fail the handler's body stream with a terminal error, then answer 413 and
// close. The reqLoc is dropped first so the handler's late respond() no-ops.
void UvReactor::abortStreamTooLarge(Conn* c) {
  const int64_t reqId = c->streamReqId;
  c->streamingBody = false;
  ReqLoc loc;
  lookupReq(reqId, loc, /*erase=*/true);
  if (c->streamEmitter) {
    static const char kMsg[] = "request body too large";
    const size_t n = sizeof(kMsg) - 1;
    auto* payload = (uint8_t*)std::malloc(n);
    if (payload) {
      std::memcpy(payload, kMsg, n);
      pending_.trackPayload(reqId, payload);
      c->streamEmitter->emitBodyError(reqId, payload, n,
                                      ErrorKind::RequestTooLarge);
    }
  }
  writeAnswer(c, uvBuildHead(413, {}, 0, false, 0), false, true);
}

#ifdef NITRO_SERVER_HTTP2
int UvReactor::loopIndexOf(const Conn* c) const {
  for (size_t i = 0; i < loops_.size(); i++)
    if (loops_[i].get() == c->lp) return (int)i;
  return 0;
}

// Loop thread: attach an Http2Session to a connection that negotiated h2 (ALPN
// or the h2c preface). The write-sink routes outbound frames through writeRaw
// (which encrypts when the conn is TLS); the injected id allocator pulls from
// the reactor's shared counter and registers reqLoc_ with isH2 so a Dart
// respond() routes back to this session on this loop. pump() sends the server
// SETTINGS preface immediately. All on the loop thread — nghttp2 is never
// touched off it (respond() hops here via onAsync).
void UvReactor::createH2Session(Conn* c) {
  const int loopIdx = loopIndexOf(c);
  const int64_t cid = c->id;
  const int64_t cap = cfg_.maxBodyBytes;
  Emitter* em = nextEmitter();
  c->h2 = std::make_unique<Http2Session>(
      em, router_,
      [this, c](const uint8_t* d, size_t n) {
        writeRaw(c, std::string((const char*)d, n));
      },
      c->clientIp, cap,
      [this, cid, loopIdx]() -> int64_t {
        const int64_t id = nextId_.fetch_add(1);
        std::lock_guard<std::mutex> lk(reqMutex_);
        reqLoc_[id] = ReqLoc{loopIdx, cid, false, false, true};
        return id;
      },
      cfg_.defaultTimeoutMs, [this]() { return !overInFlightBudget(); },
      cfg_.maxBufferedBodyBytes);
  c->h2->pump();  // flush the server connection preface (SETTINGS)
}

// Loop thread: hand buffered inbound bytes to the h2 session; close on a fatal
// protocol error, or once the session is finished. Returns false on a fatal
// error (the connection is being torn down).
bool UvReactor::feedH2(Conn* c) {
  bool fatal = false;
  if (!c->buf.empty()) {
    c->lastActive = Clock::now();  // h2 inbound resets the idle timer (as h1)
    if (!c->h2->feed((const uint8_t*)c->buf.data(), c->buf.size())) fatal = true;
    c->buf.clear();
  }
  // Close once the session is finished: nghttp2 wants neither read nor write
  // after it terminates the connection (GOAWAY on a protocol error, or the
  // peer's GOAWAY). Leaving the socket half-open makes a conformant peer wait
  // for a close that never comes (h2spec "expected connection closed"). A
  // healthy keep-alive h2 connection always still wants to read, so this never
  // closes one mid-serve. feed() already pumped any GOAWAY out before this.
  // "Done" = the session wants neither read nor write AND has no request
  // stream still awaiting its answer. The last clause matters: between a
  // request completing and its async respond() landing, nghttp2 (notably 1.59)
  // can momentarily report neither want-read nor want-write; without the guard
  // the reactor tears the connection down in that window and the in-flight
  // response is lost (an h2c reset a fast peer sees before any bytes).
  const bool done = !c->h2->wantRead() && !c->h2->wantWrite() &&
                    !c->h2->hasOpenStreams();
  if ((fatal || done) && !c->closing) {
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
  }
  return !fatal;
}
#endif  // NITRO_SERVER_HTTP2

// Loop thread: dispatch complete buffered requests until one is in flight.
void UvReactor::processConn(Conn* c) {
  if (c->streamingBody) return;  // a streamBody upload owns the buffer
#ifdef NITRO_SERVER_HTTP2
  if (c->h2) { feedH2(c); return; }  // already h2: all inbound feeds the session
  // h2c prior-knowledge: a fresh PLAINTEXT connection whose first bytes are the
  // HTTP/2 connection preface. (TLS h2 is negotiated via ALPN in tlsOnRead.)
  {
#ifdef NITRO_SERVER_TLS
    const bool plaintext = (c->ssl == nullptr);
#else
    const bool plaintext = true;
#endif
    if (cfg_.http2 && plaintext && c->served == 0 && !c->busy &&
        !c->buf.empty()) {
      static const char kH2Preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
      const size_t pn = sizeof(kH2Preface) - 1;  // 24
      const size_t have = c->buf.size() < pn ? c->buf.size() : pn;
      if (std::memcmp(c->buf.data(), kH2Preface, have) == 0) {
        if (c->buf.size() < pn) return;  // partial preface: await the rest
        createH2Session(c);
        feedH2(c);
        return;
      }
    }
  }
#endif
  while (!c->busy && !c->closing) {
    const size_t headEnd = c->buf.find("\r\n\r\n");
    if (headEnd == std::string::npos) {
      if (c->buf.size() > 64 * 1024) {  // header flood
        c->closing = true;
        uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
        return;
      }
      // A head has started arriving: headerTimeout is an absolute deadline
      // from this moment (a byte trickle does not extend it).
      if (!c->buf.empty() && !c->headPending) {
        c->headPending = true;
        c->headStartedAt = Clock::now();
      }
      return;
    }
    c->headPending = false;
    ParsedHead head = parseRequestHead(c->buf, headEnd);
    if (!head.ok) {
      writeAnswer(c, uvBuildHead(head.badVersion ? 505 : 400, {}, 0, false, 0),
                  false, true);
      return;
    }
    bool chunked = false;
    if (const FramingVerdict fv = uvFraming(head, chunked); fv.status != 0) {
      // request-smuggling / bad framing → 400 (501 for a transfer coding this
      // server does not implement), close.
      writeAnswer(c, uvBuildHead(fv.status, {}, 0, false, 0), false, true);
      return;
    }
    // Body: Content-Length or Transfer-Encoding: chunked (the validated
    // framing decides which; nothing re-inspects the header). Either is read
    // whole into the connection buffer, then emitted (head → chunk → end).
    int64_t clen = 0;
    if (const Header* cl = uvFindHeader(head.headers, "content-length"))
      clen = std::strtoll(cl->value.c_str(), nullptr, 10);
    if (clen < 0) {  // malformed Content-Length
      writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
      return;
    }
    // Route match up front: the body cap is per-route (falling back to the
    // server cap), so the route must be known before the body is read.
    std::string path = head.target;
    std::string query;
    {
      const size_t q = path.find('?');
      if (q != std::string::npos) { query = path.substr(q + 1); path = path.substr(0, q); }
      if (path.empty()) path = "/";
    }
    const MatchResult m = match(head.method, head.customMethod, path);
    const int64_t serverMax = cfg_.maxBodyBytes > 0 ? cfg_.maxBodyBytes : (10 << 20);
    const int64_t maxBody = (m.matched && m.route->maxBodyBytes >= 0)
                                ? m.route->maxBodyBytes
                                : serverMax;
    if (!chunked && clen > maxBody) {  // over the cap: refuse before buffering
      writeAnswer(c, uvBuildHead(413, {}, 0, false, 0), false, true);
      return;
    }
    // 100-continue: the client waits for it before sending the body.
    if ((clen > 0 || chunked) && !c->continueSent) {
      if (const Header* ex = uvFindHeader(head.headers, "expect")) {
        if (ex->value.find("100-continue") != std::string::npos ||
            ex->value.find("100-Continue") != std::string::npos) {
          writeRaw(c, "HTTP/1.1 100 Continue\r\n\r\n");
        }
      }
      c->continueSent = true;
    }

    // streamBody route: dispatch the head now and stream the body (Content-
    // Length or chunked) to the handler as it arrives.
    if (clen > 0 || chunked) {
      if (m.matched && m.route->streamBody &&
          !(m.route->maxBodyBytes >= 0 && clen > m.route->maxBodyBytes)) {
        const int64_t reqId = nextId_.fetch_add(1);
        int loopIdx = 0;
        for (size_t i = 0; i < loops_.size(); i++)
          if (loops_[i].get() == c->lp) { loopIdx = (int)i; break; }
        if (overInFlightBudget()) {  // global budget: refuse before dispatch
          writeAnswer(c, uvErrorResponse(503, "server busy", {{"Retry-After", "1"}}),
                      false, true);
          return;
        }
        const bool ka = uvClientWantsKeepAlive(head) &&
                        cfg_.keepAliveTimeoutMs > 0 && !draining_.load() &&
                        !c->ageExpired &&
                        (cfg_.maxRequestsPerConn <= 0 ||
                         c->served + 1 < cfg_.maxRequestsPerConn);
        {
          std::lock_guard<std::mutex> lk(reqMutex_);
          reqLoc_[reqId] = {loopIdx, c->id, head.method == Method::Head, ka};
        }
        c->busy = true;
        c->reqIdInFlight = reqId;
        const int64_t timeoutMs =
            m.route->timeoutMs >= 0 ? m.route->timeoutMs : cfg_.defaultTimeoutMs;
        if (timeoutMs > 0) {
          c->reqDeadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
          c->hasDeadline = true;
        }
        Emitter* em = nextEmitter();
        if (em)
          em->emitHead(reqId, head.method, head.customMethod, path, query,
                       head.headers, clen, /*hasBody=*/true,
                       /*bodyComplete=*/false, m.route->pattern, m.params,
                       c->clientIp);
        c->streamingBody = true;
        c->streamChunked = chunked;
        c->streamReqId = reqId;
        c->streamEmitter = em;
        c->bodyRemaining = chunked ? 0 : clen;
        // A chunked upload carries no Content-Length, so the cap is enforced as
        // the decoded body accrues (see emitStreamChunked); a Content-Length
        // upload was already refused above if it declared more than the cap.
        c->streamMaxBody = maxBody;
        c->streamBodyTotal = 0;
        c->buf.erase(0, headEnd + 4);  // drop the head; the rest is body
        c->lastActive = Clock::now();
        if (chunked) emitStreamChunked(c); else emitStreamBytes(c);
        return;
      }
    }

    std::string bodyBytes;
    size_t reqEnd;
    if (chunked) {
      size_t end = 0;
      const int r = decodeChunked(c->buf, headEnd + 4, maxBody, bodyBytes, end);
      if (r == 0) {  // await the rest of the chunked body
        c->bodyPending = true;
        return;
      }
      if (r == -1) {       // malformed framing
        writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
        return;
      }
      if (r == -2) {       // body (or its framing) over the cap
        writeAnswer(c, uvBuildHead(413, {}, 0, false, 0), false, true);
        return;
      }
      reqEnd = end;
      clen = (int64_t)bodyBytes.size();  // the head reports the decoded length
    } else {
      reqEnd = headEnd + 4 + (size_t)clen;
      if (c->buf.size() < reqEnd) {  // await the rest of the body
        c->bodyPending = true;
        return;
      }
      if (clen > 0) bodyBytes = c->buf.substr(headEnd + 4, (size_t)clen);
    }

    const bool underBudget =
        cfg_.maxRequestsPerConn <= 0 || c->served + 1 < cfg_.maxRequestsPerConn;
    const bool keepAlive = uvClientWantsKeepAlive(head) &&
                           cfg_.keepAliveTimeoutMs > 0 && !draining_.load() &&
                           underBudget && !c->ageExpired;
    const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
    c->buf.erase(0, reqEnd);  // consume this request
    c->bodyPending = false;
    c->lastActive = Clock::now();

    const bool wsUpgrade = uvIsWebSocketUpgrade(head);
    if (!m.matched) {
      // A handshake-shaped request with no route is refused honestly (426),
      // not a misleading 404.
      if (wsUpgrade) {
        writeAnswer(c, uvErrorResponse(426, "websocket not supported", {{"Sec-WebSocket-Version", "13"}}), false, true);
        continue;
      }
      // RFC 9110 §15.5.6: a path that exists for other methods is 405 with
      // Allow, not a misleading 404. Only computed on a miss (never hot).
      const std::vector<std::string> allowed = router_.allowedMethods(path);
      if (!allowed.empty()) {
        std::string allow;
        for (const auto& t : allowed) allow += (allow.empty() ? "" : ", ") + t;
        writeAnswer(c, uvBuildHead(405, {{"Allow", allow}}, 0, keepAlive, kaSecs),
                    keepAlive, true);
      } else {
        writeAnswer(c, uvBuildHead(404, {}, 0, keepAlive, kaSecs), keepAlive, true);
      }
      continue;
    }
    if (m.route->isWebSocket) {
      // A non-upgrade request on a WS route is 426, not dispatched to the
      // handshake (which would misreport a missing key as 400).
      if (!wsUpgrade) {
        writeAnswer(c, uvErrorResponse(426, "websocket not supported",
                                       {{"Sec-WebSocket-Version", "13"}}),
                    false, true);
        continue;
      }
      // An upgrade must carry no body and no trailing bytes: pipelined or
      // smuggled data after the handshake head is a framing error (400).
      if (!bodyBytes.empty() || !c->buf.empty()) {
        writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
        return;
      }
      wsHandshake(c, head, m, path, query);
      return;  // upgraded (or refused + closed); never serves HTTP again
    }
    // A WS upgrade aimed at a plain HTTP route: refuse with 426, never dispatch.
    if (wsUpgrade) {
      writeAnswer(c, uvErrorResponse(426, "websocket not supported",
                                     {{"Sec-WebSocket-Version", "13"}}),
                  false, true);
      continue;
    }
    if (m.route->staticResponse) {
      const StaticResponse& sr = *m.route->staticResponse;
      // A fixed route has no reader for a request body: if one came with the
      // request, answer then close so the read bytes can't confuse framing.
      const bool ka = keepAlive && bodyBytes.empty();
      std::string out = uvBuildHead(sr.status, sr.headers,
                                  (int64_t)sr.body.size(), ka, kaSecs);
      if (head.method != Method::Head) out.append(sr.body);
      writeAnswer(c, std::move(out), ka, true);
      continue;
    }
    if (overInFlightBudget()) {  // global budget: refuse before dispatch
      writeAnswer(c, uvErrorResponse(503, "server busy", {{"Retry-After", "1"}}),
                  false, true);
      continue;
    }
    // Handler route: dispatch to Dart, one in flight, answered via respond().
    const int64_t reqId = nextId_.fetch_add(1);
    int loopIdx = 0;
    for (size_t i = 0; i < loops_.size(); i++)
      if (loops_[i].get() == c->lp) { loopIdx = (int)i; break; }
    {
      std::lock_guard<std::mutex> lk(reqMutex_);
      reqLoc_[reqId] = {loopIdx, c->id, head.method == Method::Head, keepAlive};
    }
    c->busy = true;
    c->reqIdInFlight = reqId;
    {
      const int64_t timeoutMs =
          m.route->timeoutMs >= 0 ? m.route->timeoutMs : cfg_.defaultTimeoutMs;
      if (timeoutMs > 0) {
        c->reqDeadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
        c->hasDeadline = true;
      }
    }
    if (Emitter* em = nextEmitter()) {
      const bool hasBody = clen > 0;
      // Head first (bodyComplete=false when a body follows), then the body as
      // one chunk, then the end marker — the runner accumulates until end,
      // robust to head/chunk stream ordering. (No inline "chunk-then-complete-
      // head" form: it races the two streams and can dispatch an empty body.)
      em->emitHead(reqId, head.method, head.customMethod, path, query,
                   head.headers, clen, hasBody, /*bodyComplete=*/!hasBody,
                   m.route->pattern, m.params, c->clientIp);
      if (hasBody) {
        auto* payload = (uint8_t*)std::malloc(bodyBytes.size());
        if (payload) {
          std::memcpy(payload, bodyBytes.data(), bodyBytes.size());
          pending_.trackPayload(reqId, payload);
          em->emitBodyData(reqId, payload, bodyBytes.size());
        }
        em->emitBodyEnd(reqId);
      }
    }
    return;  // wait for respond()
  }
}

// Loop thread: write bytes; when it lands, resume/close only if `finish`.
void UvReactor::writeAnswer(Conn* c, std::string bytes, bool keepAlive,
                            bool finish) {
  c->busy = true;
  // The route timeout bounds time-to-first-byte only (see ResponseContext docs):
  // once any answer byte is on the way — a full response, or a streamed head —
  // the handler has responded, so the sweep must not later splice a 408 into a
  // long streaming body. Clearing on the first write makes this TTFB-only.
  c->hasDeadline = false;
  c->responseStarted = true;
  c->lastWriteAt = Clock::now();
  std::string* payload;
#ifdef NITRO_SERVER_TLS
  if (c->ssl) {
    // Encrypt the plaintext. SSL_MODE_ENABLE_PARTIAL_WRITE means SSL_write can
    // return after a single record (~16 KiB), so loop until it is all in; the
    // memory write-BIO is unbounded, so the ciphertext then drains in full.
    size_t off = 0;
    while (off < bytes.size()) {
      const int w = SSL_write(c->ssl, bytes.data() + off, (int)(bytes.size() - off));
      if (w <= 0) break;
      off += (size_t)w;
    }
    payload = new std::string(tlsDrain(c));
  } else
#endif
  {
    payload = new std::string(std::move(bytes));
  }
  if (c->writePending == 0) c->writeStartedAt = Clock::now();
  c->writePending += (int64_t)payload->size();
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, keepAlive, finish};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
  // A WebSocket session that outruns its reader past the buffer cap is closed
  // with 1009 (message too big / backpressure).
  if (c->ws && !c->wsClosing && cfg_.wsMaxBufferBytes > 0 &&
      c->writePending > cfg_.wsMaxBufferBytes) {
    wsCloseConn(c, 1009);
  } else if (!c->ws && !finish && cfg_.streamMaxBufferBytes > 0 &&
             c->writePending > cfg_.streamMaxBufferBytes && !c->closing) {
    // A streaming response (SSE / chunked) whose reader has fallen behind by
    // more than the cap: the queue would otherwise grow with the handler's
    // output. Drop the connection; the handler's later chunks are no-ops.
    broadcastEvent(ServerEventKind::ClientError, c->id,
                   "stream buffer limit exceeded");
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
  }
}

// Loop thread: write bytes without changing request state (finish=false).
void UvReactor::writeRaw(Conn* c, std::string bytes) {
#ifdef NITRO_SERVER_TLS
  if (c->ssl) {
    size_t off = 0;  // partial-write mode: loop until all plaintext is in
    while (off < bytes.size()) {
      const int w = SSL_write(c->ssl, bytes.data() + off, (int)(bytes.size() - off));
      if (w <= 0) break;
      off += (size_t)w;
    }
    bytes = tlsDrain(c);
  }
#endif
  if (bytes.empty()) return;
  auto* payload = new std::string(std::move(bytes));
  if (c->writePending == 0) c->writeStartedAt = Clock::now();
  c->writePending += (int64_t)payload->size();
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, true, /*finish=*/false};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
}

void UvReactor::onWrite(uv_write_t* req, int status) {
  auto* ctx = (WriteCtx*)req->data;
  Conn* c = ctx->c;
  const bool keepAlive = ctx->keepAlive;
  const bool finish = ctx->finish;
  c->writePending -= (int64_t)ctx->payload->size();
  if (c->writePending < 0) c->writePending = 0;
  delete ctx->payload;
  delete ctx;
  delete req;
  if (status < 0) {
    if (!uv_is_closing((uv_handle_t*)&c->handle)) {
      c->closing = true;
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    }
    return;
  }
  if (!finish) {
    // A file answer reads its next chunk only now, once this write landed:
    // the socket's pace bounds the memory, not the file's size.
    if (c->fileFd >= 0 && c->writePending == 0) c->lp->owner->continueFileSend(c);
    return;  // a chunked stream continues; stay busy for the rest
  }
  c->served++;
  c->hasDeadline = false;
  c->responseStarted = false;
  c->reqIdInFlight = -1;
  c->continueSent = false;
  c->lastActive = Clock::now();
  if (!keepAlive || c->closing) {
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
    return;
  }
  c->busy = false;
  c->lp->owner->processConn(c);  // any pipelined request buffered already
}

bool UvReactor::lookupReq(int64_t id, ReqLoc& out, bool erase) {
  std::lock_guard<std::mutex> lk(reqMutex_);
  auto it = reqLoc_.find(id);
  if (it == reqLoc_.end()) return false;
  out = it->second;
  if (erase) reqLoc_.erase(it);
  return true;
}

void UvReactor::pushWrite(const ReqLoc& loc, std::string bytes, bool finish) {
  Loop* lp = loops_[loc.loopIdx].get();
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back({loc.connId, std::move(bytes), loc.keepAlive, finish});
  }
  uv_async_send(&lp->async);
}

// Any thread: build the whole answer and hand it to the connection's loop.
void UvReactor::respond(int64_t id, int64_t status,
                        const std::vector<Header>& headers, const uint8_t* body,
                        size_t bodyLen) {
  // After stop() the loops are torn down, so a late answer from Dart must be a
  // no-op. The higher layer stops dispatching before shutdown; this guard
  // hardens the narrow stop()-vs-respond() window (a late uv_async_send on a
  // closing async handle) rather than relying on that contract alone.
  if (!running_.load()) return;
  ReqLoc loc;
  if (!lookupReq(id, loc, /*erase=*/true)) return;  // unknown/already answered
  completions_.fetch_add(1, std::memory_order_release);  // controller throughput signal
#ifdef NITRO_SERVER_HTTP2
  if (loc.isH2) {  // hand the answer to the loop thread's Http2Session (onAsync)
    Loop* lp = loops_[loc.loopIdx].get();
    Loop::Pending p;
    p.connId = loc.connId;
    p.isH2 = true;
    p.h2ReqId = id;
    p.h2Status = (int)status;
    p.h2Headers = headers;
    if (body && bodyLen) p.bytes.assign((const char*)body, bodyLen);
    {
      std::lock_guard<std::mutex> lk(lp->qMutex);
      lp->queue.push_back(std::move(p));
    }
    uv_async_send(&lp->async);
    return;
  }
#endif
  const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
  std::string out = uvBuildHead(status, headers, (int64_t)bodyLen, loc.keepAlive,
                                kaSecs);
  // RFC 9110 §6.4.1: 1xx/204/304 have no content — a handler body is dropped
  // (the head already carries no Content-Length), never spliced into the next
  // response on the connection.
  const bool bodyless = status == 204 || status == 304 || (status >= 100 && status < 200);
  if (!loc.isHead && !bodyless && body && bodyLen) out.append((const char*)body, bodyLen);
  pushWrite(loc, std::move(out), /*finish=*/true);
}

// Any thread: chunked response head (Transfer-Encoding: chunked). The reqLoc
// stays until the terminal chunk (see sendStreamChunk).
void UvReactor::startStream(int64_t id, int64_t status,
                            const std::vector<Header>& headers) {
  if (!running_.load()) return;  // no-op after stop() (see respond)
  ReqLoc loc;
  if (!lookupReq(id, loc, /*erase=*/false)) return;
#ifdef NITRO_SERVER_HTTP2
  if (loc.isH2) {
    if (loc.isHead) {
      // HEAD: no body will stream, so answer headers-only now and release the
      // request (later sendStreamChunk calls then no-op) instead of buffering a
      // body the h2 session would only discard. Mirrors the HTTP/1.1 HEAD path,
      // and routes through onAsync like respond()'s h2 branch.
      {
        std::lock_guard<std::mutex> lk(reqMutex_);
        reqLoc_.erase(id);
      }
      completions_.fetch_add(1, std::memory_order_release);
      Loop* lp = loops_[loc.loopIdx].get();
      Loop::Pending p;
      p.connId = loc.connId;
      p.isH2 = true;
      p.h2ReqId = id;
      p.h2Status = (int)status;
      p.h2Headers = headers;
      {
        std::lock_guard<std::mutex> lk(lp->qMutex);
        lp->queue.push_back(std::move(p));
      }
      uv_async_send(&lp->async);
      return;
    }
    std::lock_guard<std::mutex> lk(reqMutex_);  // buffer; flush on terminal chunk
    h2StreamAccum_[id] = H2StreamAccum{(int)status, headers, {}};
    return;
  }
#endif
  const int64_t kaSecs = (cfg_.keepAliveTimeoutMs + 999) / 1000;
  std::string out = uvBuildStreamHead(status, headers, loc.keepAlive, kaSecs);
  // HEAD: headers only; the terminal chunk finishes it with no body.
  pushWrite(loc, std::move(out), /*finish=*/loc.isHead);
  if (loc.isHead) lookupReq(id, loc, /*erase=*/true);
}

// Any thread: one chunk frame; `last` appends the terminal chunk and finishes.
void UvReactor::sendStreamChunk(int64_t id, const uint8_t* chunk, size_t n,
                                bool last) {
  if (!running_.load()) return;  // no-op after stop() (see respond)
  if (chunk == nullptr) n = 0;
  if (n == 0 && !last) return;  // empty non-terminal chunk: nothing to send
  ReqLoc loc;
  if (!lookupReq(id, loc, /*erase=*/false)) return;  // peek; erase per protocol
#ifdef NITRO_SERVER_HTTP2
  if (loc.isH2) {  // accumulate; on the terminal chunk flush as one h2 response
    Loop::Pending p;
    bool flush = false;
    {
      std::lock_guard<std::mutex> lk(reqMutex_);
      auto it = h2StreamAccum_.find(id);
      if (it == h2StreamAccum_.end()) return;  // no startStream / already flushed
      const int64_t cap = cfg_.maxBodyBytes;
      if (cap > 0 && (int64_t)it->second.body.size() + (int64_t)n > cap) {
        // The buffered h2 response would exceed the body cap. An indefinite or
        // oversized stream must not grow the accumulator without bound (OOM).
        // Nothing has gone out yet — h2 streamed responses are flushed whole on
        // the terminal chunk — so discard the buffer and answer 503 instead.
        // ponytail: true incremental h2 DATA framing (nghttp2 deferred data
        // provider + resume) would actually stream these; buffering is the
        // documented simplification and this only bounds its worst case.
        p.connId = loc.connId;
        p.isH2 = true;
        p.h2ReqId = id;
        p.h2Status = 503;
        p.h2Headers = {{"content-type", "text/plain; charset=utf-8"}};
        p.bytes = "response exceeded the server buffer cap";
        h2StreamAccum_.erase(it);
        reqLoc_.erase(id);
        flush = true;
      } else {
        if (n > 0) it->second.body.append((const char*)chunk, n);
        if (last) {
          p.connId = loc.connId;
          p.isH2 = true;
          p.h2ReqId = id;
          p.h2Status = it->second.status;
          p.h2Headers = std::move(it->second.headers);
          p.bytes = std::move(it->second.body);
          h2StreamAccum_.erase(it);
          reqLoc_.erase(id);
          flush = true;
        }
      }
    }
    if (flush) {
      completions_.fetch_add(1, std::memory_order_release);
      Loop* lp = loops_[loc.loopIdx].get();
      {
        std::lock_guard<std::mutex> lk(lp->qMutex);
        lp->queue.push_back(std::move(p));
      }
      uv_async_send(&lp->async);
    }
    return;
  }
#endif
  if (last) {  // HTTP/1.1: release the request on the terminal chunk
    ReqLoc tmp;
    lookupReq(id, tmp, /*erase=*/true);
    completions_.fetch_add(1, std::memory_order_release);  // same signal as respond()
  }
  std::string out;
  if (n > 0) {
    char sz[32];
    int m = std::snprintf(sz, sizeof(sz), "%zx\r\n", n);
    out.append(sz, (size_t)m);
    out.append((const char*)chunk, n);
    out.append("\r\n");
  }
  if (last) out.append("0\r\n\r\n");
  pushWrite(loc, std::move(out), /*finish=*/last);
}

// Loop thread: drain queued answers, writing each to its (still-live) conn.
// When `stopping`, close every handle on this loop so uv_run returns cleanly.
void UvReactor::onAsync(uv_async_t* async) {
  Loop* lp = (Loop*)async->data;
  std::vector<Loop::Pending> batch;
  bool stopping;
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    batch.swap(lp->queue);
    stopping = lp->stopping;
  }
  // Coalesce consecutive entries for the same connection into one write: a
  // stream that bursts N chunks between loop wakes then costs one uv_write
  // (and one send syscall), not N. Merging stops at — and includes — the
  // entry that finishes the response, so keep-alive framing is unchanged.
  for (size_t i = 0; i < batch.size();) {
#ifdef NITRO_SERVER_HTTP2
    if (batch[i].isH2) {  // an h2 answer: respond on the loop thread, no merge
      auto hit = lp->conns.find(batch[i].connId);
      if (hit != lp->conns.end() && !hit->second->closing && hit->second->h2) {
        Conn* hc = hit->second;
        hc->h2->respond(batch[i].h2ReqId, batch[i].h2Status,
                        batch[i].h2Headers, std::move(batch[i].bytes));
        if (!hc->h2->wantRead() && !hc->h2->wantWrite()) {  // session finished
          hc->closing = true;
          if (!uv_is_closing((uv_handle_t*)&hc->handle))
            uv_close((uv_handle_t*)&hc->handle, &UvReactor::onCloseConn);
        }
      }
      ++i;
      continue;
    }
#endif
    if (batch[i].fileFd >= 0) {  // a file answer: head now, chunks as writes drain
      auto hit = lp->conns.find(batch[i].connId);
      if (hit == lp->conns.end() || hit->second->closing) {
        uv_fs_t closeReq;
        uv_fs_close(nullptr, &closeReq, batch[i].fileFd, nullptr);
        uv_fs_req_cleanup(&closeReq);
      } else {
        Conn* fc = hit->second;
        fc->fileFd = batch[i].fileFd;
        fc->fileOffset = batch[i].fileOffset;
        fc->fileRemaining = batch[i].fileRemaining;
        fc->fileKeepAlive = batch[i].keepAlive;
        lp->owner->writeAnswer(fc, std::move(batch[i].bytes), batch[i].keepAlive,
                               /*finish=*/false);
      }
      ++i;
      continue;
    }
    const int64_t cid = batch[i].connId;
    std::string merged = std::move(batch[i].bytes);
    bool keepAlive = batch[i].keepAlive;
    bool finish = batch[i].finish;
    size_t j = i + 1;
    while (!finish && j < batch.size() && batch[j].connId == cid &&
           !batch[j].isH2 && batch[j].fileFd < 0) {
      merged.append(batch[j].bytes);
      keepAlive = batch[j].keepAlive;
      finish = batch[j].finish;
      ++j;
    }
    i = j;
    auto it = lp->conns.find(cid);
    if (it == lp->conns.end()) continue;  // closed before the answer landed
    Conn* c = it->second;
    if (c->closing) continue;
    lp->owner->writeAnswer(c, std::move(merged), keepAlive, finish);
  }
  if (stopping) {
    if (!uv_is_closing((uv_handle_t*)&lp->server))
      uv_close((uv_handle_t*)&lp->server, nullptr);
    // Snapshot conns first: onCloseConn erases from the map.
    std::vector<Conn*> cs;
    cs.reserve(lp->conns.size());
    for (auto& kv : lp->conns) cs.push_back(kv.second);
    for (Conn* c : cs) {
      if (!uv_is_closing((uv_handle_t*)&c->handle)) {
        c->closing = true;
        uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      }
    }
    if (!uv_is_closing((uv_handle_t*)&lp->async))
      uv_close((uv_handle_t*)&lp->async, nullptr);
    if (!uv_is_closing((uv_handle_t*)&lp->sweep))
      uv_close((uv_handle_t*)&lp->sweep, nullptr);
    // uv_run returns once every handle's close callback has fired.
  }
}

// Loop[0] sweep: sample this tick's throughput and backlog, let the controller
// pick the dispatch width, and publish it for nextEmitter. Policy lives in
// DispatchController; this just gathers the signals.
void UvReactor::runDispatchController() {
  if (!ctlEnabled_.load(std::memory_order_acquire)) return;
  // acquire pairs with the release in respond()/stream completion, so this
  // sweep sees every answer counted before it samples the rate.
  const int64_t comp = completions_.load(std::memory_order_acquire);
  const double answers = (double)(comp - ctlLastCompletions_);
  ctlLastCompletions_ = comp;
  int64_t backlog;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    backlog = (int64_t)reqLoc_.size();
  }
  // Read the isolate count and publish the width together under emitterMutex_ —
  // the same lock nextEmitter() holds when it reads dispatchWidth_ — so a width
  // is never paired with a different emitter count, and the publish is ordered.
  std::lock_guard<std::mutex> lk(emitterMutex_);
  dispatchWidth_.store(dispatch_.tick(answers, backlog, emitters_.size()),
                       std::memory_order_relaxed);
}

// Loop thread: close idle keep-alive connections and time out slow handlers.
void UvReactor::onSweep(uv_timer_t* timer) {
  Loop* lp = (Loop*)timer->data;
  UvReactor* self = lp->owner;
  // The adaptive dispatch controller runs once per tick, on loop[0] only.
  if (!self->loops_.empty() && lp == self->loops_[0].get())
    self->runDispatchController();
  const auto now = Clock::now();
  const ServerConfig& cfg = self->cfg_;
  [[maybe_unused]] const bool draining = self->draining_.load();
  auto ms = [](int64_t v) { return std::chrono::milliseconds(v); };
  std::vector<Conn*> idle;     // closed silently (idle / expired / finished)
  std::vector<Conn*> stalled;  // a request body stopped arriving: 408 + close
  std::vector<Conn*> streamIdle;  // a streaming response went silent: close
  struct Expired {
    int64_t connId;
    ServerEventKind kind;
    const char* why;
  };
  std::vector<Expired> timedOut;  // a dispatched request past its deadline
  const int64_t writeMs =
      cfg.writeTimeoutMs > 0 ? cfg.writeTimeoutMs : 30000;
  // Window with no progress on a body in flight (head parsed, bytes still
  // arriving): readCb restarts it on every read.
  const int64_t bodyMs =
      cfg.bodyTimeoutMs > 0 ? cfg.bodyTimeoutMs : cfg.keepAliveTimeoutMs;
  for (auto& kv : lp->conns) {
    Conn* c = kv.second;
    if (c->closing) continue;
    // A peer that stopped reading: its write has been pending too long.
    if (c->writePending > 0 &&
        now - c->writeStartedAt >= ms(writeMs)) {
      c->closing = true;
      self->broadcastEvent(ServerEventKind::ClientError, c->id,
                           "write timed out");
      if (!uv_is_closing((uv_handle_t*)&c->handle))
        uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      continue;
    }
    // Hard lifetime: an HTTP/1.1 connection closes after its current answer
    // (or now, when idle); a WebSocket is told 1001 (going away); an h2
    // session gets GOAWAY and closes once its streams finish.
    if (cfg.maxConnectionAgeMs > 0 && !c->ageExpired &&
        now - c->openedAt >= ms(cfg.maxConnectionAgeMs)) {
      c->ageExpired = true;
#ifdef NITRO_SERVER_HTTP2
      if (c->h2) c->h2->goAway();
#endif
      if (c->ws) {
        self->wsCloseConn(c, 1001);
        continue;
      }
      // A request already dispatched carries its keep-alive decision in its
      // reqLoc (the answer is framed from it, off this thread): flip it so
      // the answer in flight says close.
      if (c->busy && c->reqIdInFlight >= 0) {
        std::lock_guard<std::mutex> lk(self->reqMutex_);
        auto it = self->reqLoc_.find(c->reqIdInFlight);
        if (it != self->reqLoc_.end()) it->second.keepAlive = false;
      }
    }
#ifdef NITRO_SERVER_HTTP2
    if (c->h2) {
      // Graceful drain (RFC 9113 §6.8): GOAWAY once; the peer opens no new
      // streams and the session reports "finished" when the open ones end.
      if (draining) c->h2->goAway();
      for (const int64_t reqId : c->h2->sweep(now, bodyMs)) {
        ReqLoc loc;
        if (self->lookupReq(reqId, loc, /*erase=*/true))
          self->broadcastEvent(ServerEventKind::HandlerTimeout, reqId,
                               "handler timed out");
      }
      if (!c->h2->wantRead() && !c->h2->wantWrite()) {  // GOAWAY completed
        idle.push_back(c);
        continue;
      }
      // An h2 connection serving one or more streams is actively busy even
      // though it never sets c->busy (that flag is the HTTP/1.1 one-request-
      // at-a-time gate). Don't idle-reap it mid-request.
      if (c->h2->hasOpenStreams()) continue;
      if (c->ageExpired) {
        idle.push_back(c);
        continue;
      }
    }
#endif
    if (c->ws) {
      // Liveness: ping a quiet peer at half the window; a peer still silent
      // at the full window (no pong, no frame) is gone — 1001 and close.
      if (cfg.wsIdleTimeoutMs > 0) {
        const auto quiet = now - c->lastActive;
        if (quiet >= ms(cfg.wsIdleTimeoutMs)) {
          self->broadcastEvent(ServerEventKind::ClientError, c->id,
                               "websocket idle timeout");
          self->wsCloseConn(c, 1001);
        } else if (!c->wsPingSent && quiet >= ms(cfg.wsIdleTimeoutMs / 2)) {
          std::vector<uint8_t> frame;
          ws::encodeFrame(ws::kPing, nullptr, 0, true, frame);
          self->writeAnswer(c, std::string(frame.begin(), frame.end()), true,
                            false);
          c->wsPingSent = true;
        }
      }
      continue;
    }
    if (c->busy) {
      if (c->hasDeadline && now >= c->reqDeadline && c->reqIdInFlight >= 0) {
        timedOut.push_back({c->id, ServerEventKind::HandlerTimeout,
                            "handler timed out"});
      } else if (c->streamingBody && c->reqIdInFlight >= 0 && bodyMs > 0 &&
                 now - c->lastActive >= ms(bodyMs)) {
        // A streamed upload that stopped arriving: the handler is waiting on
        // bytes that never come. Same retirement as a deadline miss.
        timedOut.push_back({c->id, ServerEventKind::ClientError,
                            "request body timed out"});
      } else if (c->responseStarted && c->reqIdInFlight >= 0 &&
                 c->writePending == 0 && cfg.streamIdleTimeoutMs > 0 &&
                 now - c->lastWriteAt >= ms(cfg.streamIdleTimeoutMs)) {
        // A streaming response the handler stopped feeding (no chunk for the
        // whole window, nothing queued): the stream is dead, close it. A live
        // stream sends heartbeats more often than this.
        streamIdle.push_back(c);
      }
      continue;
    }
    if (c->bodyPending) {  // head parsed, body still arriving: stall window
      if (bodyMs > 0 && now - c->lastActive >= ms(bodyMs)) stalled.push_back(c);
      continue;
    }
    // Slow-loris: a request head (or a TLS handshake) that has not completed
    // within headerTimeout of its first byte is dropped, however steadily
    // the bytes trickle in.
    if (cfg.headerTimeoutMs > 0) {
      bool handshaking = false;
#ifdef NITRO_SERVER_TLS
      handshaking = c->ssl != nullptr && !c->tlsHandshakeDone;
#endif
      if ((c->headPending && now - c->headStartedAt >= ms(cfg.headerTimeoutMs)) ||
          (handshaking && now - c->openedAt >= ms(cfg.headerTimeoutMs))) {
        self->broadcastEvent(ServerEventKind::ClientError, c->id,
                             "request head timed out");
        idle.push_back(c);
        continue;
      }
    }
    if (c->ageExpired) {
      idle.push_back(c);
      continue;
    }
    const int64_t idleMs =
        (c->served == 0 && cfg.headerTimeoutMs > 0)
            ? cfg.headerTimeoutMs
            : cfg.keepAliveTimeoutMs;
    if (idleMs > 0 && now - c->lastActive >= ms(idleMs)) idle.push_back(c);
  }
  for (Conn* c : idle) {
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
  }
  for (Conn* c : stalled) {
    self->broadcastEvent(ServerEventKind::ClientError, c->id,
                         "request body timed out");
    self->writeAnswer(c, uvBuildHead(408, {}, 0, false, 0), false, true);
  }
  for (Conn* c : streamIdle) {
    ReqLoc loc;
    const int64_t reqId = c->reqIdInFlight;
    self->lookupReq(reqId, loc, /*erase=*/true);  // later chunks are no-ops
    self->broadcastEvent(ServerEventKind::ClientError, reqId,
                         "stream idle timeout");
    c->reqIdInFlight = -1;
    c->responseStarted = false;
    c->closing = true;
    if (!uv_is_closing((uv_handle_t*)&c->handle))
      uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
  }
  for (const Expired& e : timedOut) {
    auto it = lp->conns.find(e.connId);
    if (it == lp->conns.end()) continue;
    Conn* c = it->second;
    ReqLoc loc;
    // Drop the reqLoc so the handler's late respond is a no-op, then 408+close.
    const int64_t reqId = c->reqIdInFlight;
    if (self->lookupReq(reqId, loc, /*erase=*/true)) {
      c->hasDeadline = false;
      c->reqIdInFlight = -1;
      c->streamingBody = false;
      self->writeAnswer(c, uvBuildHead(408, {}, 0, false, 0), false, true);
      self->broadcastEvent(e.kind, reqId, e.why);
    }
  }
}

// Stop accepting (onConnection refuses while draining) and mark later answers
// close (processConn's keepAlive checks draining_). In-flight requests finish;
// stop() reaps idle keep-alive connections.
void UvReactor::beginDrain() { draining_.store(true); }

StatusResult UvReactor::reloadTls(const std::string& certPem,
                                  const std::string& keyPem,
                                  const std::string& certFile,
                                  const std::string& keyFile) {
#ifdef NITRO_SERVER_TLS
  if (sslCtx_.load(std::memory_order_acquire) == nullptr) {
    return {ErrorKind::TlsError, "server was not started with TLS", 0};
  }
  void* fresh = nullptr;
  auto r = buildSslCtx(certPem, keyPem, certFile, keyFile, &fresh);
  if (r.kind != ErrorKind::None) return r;  // keep the live cert on failure
  void* old = sslCtx_.exchange(fresh, std::memory_order_acq_rel);
  // Existing connections' SSL objects hold a ref on `old`; this drops ours, so
  // the old ctx frees only once the last connection using it closes.
  if (old) SSL_CTX_free((SSL_CTX*)old);
  return {};
#else
  (void)certPem;
  (void)keyPem;
  (void)certFile;
  (void)keyFile;
  return {ErrorKind::TlsError, "engine built without TLS", 0};
#endif
}

int64_t UvReactor::inFlightRequests() {
  std::lock_guard<std::mutex> lk(reqMutex_);
  return (int64_t)reqLoc_.size();
}

// A connection whose request is being answered keeps reading (a pipelined
// request may follow), but what it may hold unprocessed is bounded: the head
// cap plus one body. Past that the peer is pumping bytes nobody will read
// (every byte would otherwise be kept until the handler answered) — 400 and
// close. Streaming uploads, WebSocket and h2 have their own bounds.
bool UvReactor::overBusyBuffer(Conn* c) {
  if (!c->busy || c->streamingBody || c->ws) return false;
#ifdef NITRO_SERVER_HTTP2
  if (c->h2) return false;
#endif
  const int64_t maxBody = cfg_.maxBodyBytes > 0 ? cfg_.maxBodyBytes : (10 << 20);
  if ((int64_t)c->buf.size() <= 64 * 1024 + maxBody) return false;
  broadcastEvent(ServerEventKind::ClientError, c->id,
                 "pipelined bytes exceed the buffer cap");
  c->buf.clear();
  c->buf.shrink_to_fit();
  writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
  return true;
}

bool UvReactor::overInFlightBudget() {
  if (cfg_.maxInFlightRequests <= 0) return false;
  std::lock_guard<std::mutex> lk(reqMutex_);
  return (int64_t)reqLoc_.size() >= cfg_.maxInFlightRequests;
}

// ── WebSocket ────────────────────────────────────────────────────────────────

// Loop thread: send a close frame with [code], then close the connection.
void UvReactor::wsCloseConn(Conn* c, int code) {
  if (c->wsClosing) return;
  c->wsClosing = true;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    wsConnLoop_.erase(c->id);
  }
  // Tell the runner the session closed with [code] so session.closeCode
  // resolves (a server-initiated 1002/1009 as well as a client close echo).
  if (c->wsEmitter) c->wsEmitter->emitWsMessage(c->id, nullptr, 0, ws::kClose, code);
  const int wire = code == 1005 ? 1000 : code;  // 1005 is not a wire code
  uint8_t cc[2] = {(uint8_t)((wire >> 8) & 0xff), (uint8_t)(wire & 0xff)};
  std::vector<uint8_t> frame;
  ws::encodeFrame(ws::kClose, cc, 2, true, frame);
  writeAnswer(c, std::string(frame.begin(), frame.end()), /*keepAlive=*/false,
              /*finish=*/true);  // closes once the frame lands
}

// Loop thread: validate the RFC 6455 upgrade, answer 101, switch to WS mode.
void UvReactor::wsHandshake(Conn* c, const ParsedHead& head,
                            const MatchResult& m, const std::string& path,
                            const std::string& query) {
  const Header* key = uvFindHeader(head.headers, "sec-websocket-key");
  const Header* ver = uvFindHeader(head.headers, "sec-websocket-version");
  // RFC 6455 §4.2.1: the key is 16 random bytes base64-encoded (24 chars,
  // `==` padding) and the version is exactly 13 — anything else is 400 / 426.
  auto validKey = [](const std::string& k) {
    if (k.size() != 24 || k[22] != '=' || k[23] != '=') return false;
    for (size_t i = 0; i < 22; i++) {
      const char ch = k[i];
      const bool b64 = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                       (ch >= '0' && ch <= '9') || ch == '+' || ch == '/';
      if (!b64) return false;
    }
    return true;
  };
  if (!key || !validKey(uvTrim(key->value))) {
    writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
    return;
  }
  if (!ver || uvTrim(ver->value) != "13") {
    writeAnswer(c, uvErrorResponse(426, "websocket not supported", {{"Sec-WebSocket-Version", "13"}}), false, true);
    return;
  }
  // Subprotocol negotiation: pick the first the route accepts that the client
  // offered. A client that offers protocols none of which overlap is refused
  // with 400; a client that offers none upgrades unselected (no header back).
  std::string protocol;
  if (!m.route->wsProtocols.empty()) {
    const Header* offer = uvFindHeader(head.headers, "sec-websocket-protocol");
    if (offer && !uvTrim(offer->value).empty()) {
      for (const std::string& want : m.route->wsProtocols) {
        // The offer is comma-separated; match on a trimmed token.
        size_t b = 0;
        while (b <= offer->value.size() && protocol.empty()) {
          size_t comma = offer->value.find(',', b);
          if (comma == std::string::npos) comma = offer->value.size();
          std::string tok = uvTrim(offer->value.substr(b, comma - b));
          if (tok == want) protocol = want;
          b = comma + 1;
        }
        if (!protocol.empty()) break;
      }
      if (protocol.empty()) {  // offered, but nothing the route accepts
        writeAnswer(c, uvBuildHead(400, {}, 0, false, 0), false, true);
        return;
      }
    }
  }
  // permessage-deflate (no context takeover): the Dart runner does the actual
  // deflate/inflate; the engine only negotiates it and moves the RSV1 bit.
  const Header* ext = uvFindHeader(head.headers, "sec-websocket-extensions");
  c->deflate = cfg_.wsCompression && ext &&
               ext->value.find("permessage-deflate") != std::string::npos;
  const std::string accept = ws::acceptKey(key->value);
  std::string shake =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
      "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n";
  if (c->deflate)
    shake += "Sec-WebSocket-Extensions: permessage-deflate; "
             "server_no_context_takeover; client_no_context_takeover\r\n";
  if (!protocol.empty())
    shake += "Sec-WebSocket-Protocol: " + protocol + "\r\n";
  shake += "\r\n";
  writeAnswer(c, std::move(shake), true, /*finish=*/false);  // stay open
  c->ws = true;
  int loopIdx = 0;
  for (size_t i = 0; i < loops_.size(); i++)
    if (loops_[i].get() == c->lp) { loopIdx = (int)i; break; }
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    wsConnLoop_[c->id] = loopIdx;
  }
  // Session open dispatches like any request head, carrying the handshake's
  // pattern, params, query and headers. The whole session stays on this sink.
  c->wsEmitter = nextEmitter();
  if (c->wsEmitter) {
    c->wsEmitter->emitHead(c->id, head.method, head.customMethod, path, query,
                           head.headers, 0, false, true, m.route->pattern,
                           m.params, c->clientIp);
  }
  wsProcess(c);  // handle any frames already buffered
}

// Loop thread: decode buffered WebSocket frames, reassemble, dispatch.
void UvReactor::wsProcess(Conn* c) {
  while (!c->closing && !c->wsClosing) {
    if (c->buf.size() < 2) return;  // header incomplete
    const uint8_t b0 = (uint8_t)c->buf[0];
    const int opcode = b0 & 0x0f;
    // RSV1 is a valid data-frame bit when permessage-deflate is negotiated.
    const bool badRsv = c->deflate ? ((b0 & 0x30) != 0) : ((b0 & 0x70) != 0);
    const bool badOp = opcode != 0 && opcode != 1 && opcode != 2 &&
                       opcode != 8 && opcode != 9 && opcode != 0xA;
    const bool masked = (c->buf[1] & 0x80) != 0;
    if (badRsv || badOp || !masked) {  // client frames MUST be masked
      wsCloseConn(c, 1002);
      return;
    }
    // RFC 6455 §5.5: a control frame is never fragmented and carries at most
    // 125 bytes. Judged from the first two bytes, before the header parser
    // (which treats such a frame as unparseable, i.e. "wait for more" —
    // leaving the connection hanging until the idle timeout).
    if (ws::isControl(opcode) &&
        (!(b0 & 0x80) || (c->buf[1] & 0x7f) > 125)) {
      wsCloseConn(c, 1002);
      return;
    }
    ws::FrameHeader h;
    if (!ws::parseHeader((const uint8_t*)c->buf.data(), c->buf.size(), h,
                         /*allowRsv1=*/c->deflate))
      return;  // header not fully buffered yet
    // A data frame whose declared length alone exceeds the message cap is
    // judged here, before waiting for a payload that may never arrive.
    const int64_t maxMsg = cfg_.maxBodyBytes > 0 ? cfg_.maxBodyBytes : (10 << 20);
    if (!ws::isControl(h.opcode) && (int64_t)h.length > maxMsg) {
      wsCloseConn(c, 1009);
      return;
    }
    if (c->buf.size() < h.headerSize + h.length) return;  // payload incomplete
    // Unmask the payload in place into a local buffer.
    std::string payload(c->buf.data() + h.headerSize, (size_t)h.length);
    for (size_t i = 0; i < payload.size(); i++)
      payload[i] = (char)((uint8_t)payload[i] ^ h.mask[i & 3]);
    c->buf.erase(0, h.headerSize + (size_t)h.length);

    if (h.opcode == ws::kPing) {
      std::vector<uint8_t> frame;
      ws::encodeFrame(ws::kPong, (const uint8_t*)payload.data(), payload.size(),
                      true, frame);
      writeAnswer(c, std::string(frame.begin(), frame.end()), true, false);
      continue;
    }
    if (h.opcode == ws::kPong) continue;
    if (h.opcode == ws::kClose) {
      // RFC 6455 §5.5.1 / §7.4: an empty payload means "no code" (echoed as
      // 1000); one byte is malformed; otherwise a valid code followed by a
      // UTF-8 reason. Violations are protocol errors (1002), a bad reason is
      // invalid data (1007).
      int code = 1005;
      if (payload.size() == 1) {
        wsCloseConn(c, 1002);
        return;
      }
      if (payload.size() >= 2) {
        code = ((uint8_t)payload[0] << 8) | (uint8_t)payload[1];
        if (!ws::validCloseCode(code)) {
          wsCloseConn(c, 1002);
          return;
        }
        if (!ws::validUtf8((const uint8_t*)payload.data() + 2,
                           payload.size() - 2)) {
          wsCloseConn(c, 1007);
          return;
        }
      }
      wsCloseConn(c, code);  // emits the close to the runner + echoes the frame
      return;
    }
    // Data frame or continuation: reassemble across fragments (RFC 6455 §5.4).
    if (h.opcode == ws::kText || h.opcode == ws::kBinary) {
      if (c->wsMsgOpcode >= 0) {  // a new message before the previous one's FIN
        wsCloseConn(c, 1002);
        return;
      }
      c->wsMsgOpcode = h.opcode;
      c->wsMsgCompressed = h.rsv1;  // deflate marker rides on the first frame
      c->wsMsg = std::move(payload);
    } else {  // continuation
      if (c->wsMsgOpcode < 0) {  // a continuation with nothing to continue
        wsCloseConn(c, 1002);
        return;
      }
      c->wsMsg.append(payload);
    }
    if ((int64_t)c->wsMsg.size() > maxMsg) {  // fragments summing past the cap
      wsCloseConn(c, 1009);
      return;
    }
    if (h.fin) {
      // Compressed text is validated after the runner inflates it, not here.
      if (c->wsMsgOpcode == ws::kText && !c->wsMsgCompressed &&
          !ws::validUtf8((const uint8_t*)c->wsMsg.data(), c->wsMsg.size())) {
        wsCloseConn(c, 1007);
        return;
      }
      auto* buf = (uint8_t*)std::malloc(c->wsMsg.size() ? c->wsMsg.size() : 1);
      if (buf) {
        if (!c->wsMsg.empty()) std::memcpy(buf, c->wsMsg.data(), c->wsMsg.size());
        pending_.trackPayload(c->id, buf);
        if (c->wsEmitter)
          c->wsEmitter->emitWsMessage(c->id, buf, c->wsMsg.size(),
                                      c->wsMsgOpcode, c->wsMsgCompressed ? 1 : 0);
      }
      c->wsMsg.clear();
      c->wsMsgOpcode = -1;  // ready for the next message
      c->wsMsgCompressed = false;
    }
  }
}

int64_t UvReactor::wsSend(int64_t connId, const uint8_t* payload, size_t n,
                          bool binary, bool compressed) {
  if (!running_.load()) return -1;  // no-op after stop() (see respond)
  int loopIdx;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    auto it = wsConnLoop_.find(connId);
    if (it == wsConnLoop_.end()) return -1;
    loopIdx = it->second;
  }
  std::vector<uint8_t> frame;
  ws::encodeFrame(binary ? ws::kBinary : ws::kText, payload, n, true, frame);
  if (compressed) frame[0] |= 0x40;  // RSV1: the runner already deflated
  Loop* lp = loops_[(size_t)loopIdx].get();
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back({connId, std::string(frame.begin(), frame.end()), true,
                         false});
  }
  uv_async_send(&lp->async);
  return 0;
}

void UvReactor::wsClose(int64_t connId, int code) {
  if (!running_.load()) return;  // no-op after stop() (see respond)
  int loopIdx;
  {
    std::lock_guard<std::mutex> lk(reqMutex_);
    auto it = wsConnLoop_.find(connId);
    if (it == wsConnLoop_.end()) return;
    loopIdx = it->second;
    wsConnLoop_.erase(it);
  }
  uint8_t cc[2] = {(uint8_t)((code >> 8) & 0xff), (uint8_t)(code & 0xff)};
  std::vector<uint8_t> frame;
  ws::encodeFrame(ws::kClose, cc, 2, true, frame);
  Loop* lp = loops_[(size_t)loopIdx].get();
  {
    std::lock_guard<std::mutex> lk(lp->qMutex);
    lp->queue.push_back({connId, std::string(frame.begin(), frame.end()), false,
                         true});  // finish=true, keepAlive=false → close after
  }
  uv_async_send(&lp->async);
}

#ifdef NITRO_SERVER_TLS
// ── TLS over libuv (OpenSSL memory BIOs) ─────────────────────────────────────

StatusResult UvReactor::buildSslCtx(const std::string& certPem,
                                    const std::string& keyPem,
                                    const std::string& certFile,
                                    const std::string& keyFile, void** out) {
  auto fail = [](const std::string& what) -> StatusResult {
    char buf[256] = {0};
    const unsigned long e = ERR_get_error();
    if (e) ERR_error_string_n(e, buf, sizeof(buf));
    return {ErrorKind::TlsError, e ? what + ": " + buf : what, 0};
  };
  SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) return fail("SSL_CTX_new failed");
  // Policy (cfg_): protocol floor, cipher lists, client-certificate anchors.
  if (cfg_.tlsMinVersion != 12 && cfg_.tlsMinVersion != 13) {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "tlsMinVersion must be 12 or 13", 0};
  }
  SSL_CTX_set_min_proto_version(
      ctx, cfg_.tlsMinVersion == 13 ? TLS1_3_VERSION : TLS1_2_VERSION);
  if (!cfg_.tlsCiphers.empty() &&
      SSL_CTX_set_cipher_list(ctx, cfg_.tlsCiphers.c_str()) != 1) {
    SSL_CTX_free(ctx);
    return fail("no usable TLS 1.2 cipher in tlsCiphers");
  }
  if (!cfg_.tlsCipherSuites.empty() &&
      SSL_CTX_set_ciphersuites(ctx, cfg_.tlsCipherSuites.c_str()) != 1) {
    SSL_CTX_free(ctx);
    return fail("no usable TLS 1.3 cipher suite in tlsCipherSuites");
  }
  if (!cfg_.tlsClientCaPem.empty() || !cfg_.tlsClientCaFile.empty()) {
    X509_STORE* store = SSL_CTX_get_cert_store(ctx);
    STACK_OF(X509_NAME)* names = sk_X509_NAME_new_null();
    int anchors = 0;
    if (!cfg_.tlsClientCaPem.empty()) {
      BIO* bio = BIO_new_mem_buf(cfg_.tlsClientCaPem.data(),
                                 (int)cfg_.tlsClientCaPem.size());
      X509* ca;
      while ((ca = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr)) != nullptr) {
        if (X509_STORE_add_cert(store, ca) == 1) {
          sk_X509_NAME_push(names, X509_NAME_dup(X509_get_subject_name(ca)));
          anchors++;
        }
        X509_free(ca);
      }
      BIO_free(bio);
    } else {
      if (SSL_CTX_load_verify_locations(ctx, cfg_.tlsClientCaFile.c_str(),
                                        nullptr) == 1) {
        STACK_OF(X509_NAME)* fromFile =
            SSL_load_client_CA_file(cfg_.tlsClientCaFile.c_str());
        if (fromFile) {
          while (sk_X509_NAME_num(fromFile) > 0)
            sk_X509_NAME_push(names, sk_X509_NAME_shift(fromFile));
          sk_X509_NAME_free(fromFile);
        }
        anchors = sk_X509_NAME_num(names);
      }
    }
    if (anchors == 0) {
      sk_X509_NAME_pop_free(names, X509_NAME_free);
      SSL_CTX_free(ctx);
      return fail("no client CA certificate could be loaded");
    }
    SSL_CTX_set_client_CA_list(ctx, names);  // takes ownership
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
                       nullptr);
  }
  SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE |
                            SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER |
                            SSL_MODE_AUTO_RETRY);
  SSL_CTX_set_options(ctx, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_TICKET);
  SSL_CTX_set_num_tickets(ctx, 0);
  // Pass the runtime http2 flag so the ALPN callback offers `h2` only while it
  // is enabled. cfg_ outlives every SSL_CTX built from it (set at configure,
  // before start/reload); the flag is read at negotiation time.
  SSL_CTX_set_alpn_select_cb(ctx, reactorAlpnSelect, &cfg_.http2);

  if (!certPem.empty()) {
    BIO* bio = BIO_new_mem_buf(certPem.data(), (int)certPem.size());
    X509* leaf = PEM_read_bio_X509_AUX(bio, nullptr, nullptr, nullptr);
    if (!leaf || SSL_CTX_use_certificate(ctx, leaf) != 1) {
      if (leaf) X509_free(leaf);
      BIO_free(bio);
      SSL_CTX_free(ctx);
      return fail("invalid TLS certificate PEM");
    }
    X509_free(leaf);
    SSL_CTX_clear_chain_certs(ctx);
    X509* ca;
    while ((ca = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr)) != nullptr)
      if (SSL_CTX_add0_chain_cert(ctx, ca) != 1) X509_free(ca);
    BIO_free(bio);
  } else if (!certFile.empty()) {
    if (SSL_CTX_use_certificate_chain_file(ctx, certFile.c_str()) != 1) {
      SSL_CTX_free(ctx);
      return fail("cannot load TLS certificate file");
    }
  } else {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "TLS requested without a certificate", 0};
  }

  if (!keyPem.empty()) {
    BIO* bio = BIO_new_mem_buf(keyPem.data(), (int)keyPem.size());
    EVP_PKEY* key = PEM_read_bio_PrivateKey(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!key || SSL_CTX_use_PrivateKey(ctx, key) != 1) {
      if (key) EVP_PKEY_free(key);
      SSL_CTX_free(ctx);
      return fail("invalid TLS private key PEM");
    }
    EVP_PKEY_free(key);
  } else if (!keyFile.empty()) {
    if (SSL_CTX_use_PrivateKey_file(ctx, keyFile.c_str(), SSL_FILETYPE_PEM) !=
        1) {
      SSL_CTX_free(ctx);
      return fail("cannot load TLS private key file");
    }
  } else {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "TLS requested without a private key", 0};
  }
  if (SSL_CTX_check_private_key(ctx) != 1) {
    SSL_CTX_free(ctx);
    return {ErrorKind::TlsError, "certificate and private key do not match", 0};
  }
  *out = ctx;
  return {};
}

StatusResult UvReactor::setupTls() {
  void* ctx = nullptr;
  auto r = buildSslCtx(cfg_.tlsCertPem, cfg_.tlsKeyPem, cfg_.tlsCertFile,
                       cfg_.tlsKeyFile, &ctx);
  if (r.kind != ErrorKind::None) return r;
  sslCtx_.store(ctx, std::memory_order_release);
  return {};
}

bool UvReactor::tlsInit(Conn* c) {
  c->ssl = SSL_new((SSL_CTX*)sslCtx_.load(std::memory_order_acquire));
  if (!c->ssl) return false;
  c->rbio = BIO_new(BIO_s_mem());
  c->wbio = BIO_new(BIO_s_mem());
  if (!c->rbio || !c->wbio) {
    SSL_free(c->ssl);  // frees any BIO already attached
    c->ssl = nullptr;
    return false;
  }
  SSL_set_bio(c->ssl, c->rbio, c->wbio);  // SSL owns the BIOs now
  SSL_set_accept_state(c->ssl);
  return true;
}

std::string UvReactor::tlsDrain(Conn* c) {
  std::string out;
  char b[16384];
  int r;
  while ((r = BIO_read(c->wbio, b, sizeof(b))) > 0) out.append(b, (size_t)r);
  return out;
}

void UvReactor::tlsRawWrite(Conn* c, std::string cipher) {
  if (cipher.empty()) return;
  auto* payload = new std::string(std::move(cipher));
  auto* req = new uv_write_t;
  req->data = new WriteCtx{c, payload, true, /*finish=*/false};
  uv_buf_t buf = uv_buf_init((char*)payload->data(), (unsigned)payload->size());
  uv_write(req, (uv_stream_t*)&c->handle, &buf, 1, &UvReactor::onWrite);
}

// Loop thread: feed ciphertext into the SSL engine, drive the handshake, then
// decrypt application data into the plaintext buffer and process it.
void UvReactor::tlsOnRead(Conn* c, const char* data, size_t n) {
  BIO_write(c->rbio, data, (int)n);
  if (!c->tlsHandshakeDone) {
    const int r = SSL_accept(c->ssl);
    const int e = (r == 1) ? 0 : SSL_get_error(c->ssl, r);
    tlsRawWrite(c, tlsDrain(c));  // ServerHello / handshake flight
    if (r != 1) {
      if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) {
        c->closing = true;
        if (!uv_is_closing((uv_handle_t*)&c->handle))
          uv_close((uv_handle_t*)&c->handle, &UvReactor::onCloseConn);
      }
      return;  // handshake needs more bytes
    }
    c->tlsHandshakeDone = true;
#ifdef NITRO_SERVER_HTTP2
    // ALPN picked h2: drive this connection through the Http2Session from here
    // on (processConn's `if (c->h2)` branch below feeds it the decrypted bytes).
    const unsigned char* proto = nullptr;
    unsigned int plen = 0;
    SSL_get0_alpn_selected(c->ssl, &proto, &plen);
    if (cfg_.http2 && proto && plen == 2 && std::memcmp(proto, "h2", 2) == 0)
      createH2Session(c);
#endif
  }
  char plain[16384];
  int r;
  while ((r = SSL_read(c->ssl, plain, sizeof(plain))) > 0)
    c->buf.append(plain, (size_t)r);
  tlsRawWrite(c, tlsDrain(c));  // anything SSL_read produced
  if (overBusyBuffer(c)) return;
  if (c->streamingBody) {
    if (c->streamChunked) emitStreamChunked(c); else emitStreamBytes(c);
  } else if (c->ws) {
    wsProcess(c);
  } else {
    processConn(c);
  }
}
#endif  // NITRO_SERVER_TLS

void UvReactor::stop() {
  if (!running_.exchange(false)) return;
  for (auto& lp : loops_) {
    {
      std::lock_guard<std::mutex> lk(lp->qMutex);
      lp->stopping = true;
    }
    uv_async_send(&lp->async);  // wakes the loop; onAsync closes handles
  }
  for (auto& lp : loops_) {
    if (lp->thread.joinable()) lp->thread.join();
    uv_loop_close(&lp->loop);
  }
  loops_.clear();
  if (reservedPort_ != 0) {
    std::lock_guard<std::mutex> lk(boundPortsMutex());
    boundPorts().erase(reservedPort_);
    reservedPort_ = 0;
  }
  // Loop threads are gone; free any body-chunk payloads the runner never
  // acked (frees leak-free in production, where ackBody would have).
  pending_.abortAll();
#ifdef NITRO_SERVER_TLS
  if (void* ctx = sslCtx_.exchange(nullptr, std::memory_order_acq_rel)) {
    SSL_CTX_free((SSL_CTX*)ctx);
  }
#endif
}

}  // namespace nitroserver

#endif  // NITRO_SERVER_LIBUV
