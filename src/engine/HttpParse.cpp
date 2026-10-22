// HTTP request-head parser, shared by the engine and the fuzz target. Extracted
// from the retired ServerInstance so parseRequestHead survives its deletion.
#include "EngineTypes.h"

#include <string>
#include <string_view>

#include "Common.h"
#include "WsCodec.h"  // validUtf8

namespace nitroserver {
namespace {

std::string_view trimSv(std::string_view s) {
  const size_t b = s.find_first_not_of(" \t");
  if (b == std::string_view::npos) return {};
  const size_t e = s.find_last_not_of(" \t");
  return s.substr(b, e - b + 1);
}

ParsedHead parseHead(const std::string& raw, size_t headEnd) {
  ParsedHead p;
  // Zero-copy: every slice below is a view into `raw`. Only the fields that
  // outlive the parse (target halves, header names/values, custom method) are
  // copied into owning strings. Views never escape.
  const std::string_view head(raw.data(), headEnd);
  // The head slice excludes the terminal \r\n\r\n: a request with no header
  // lines at all (legal HTTP/1.0) is just the request line.
  const size_t lineEnd = head.find("\r\n");
  const std::string_view requestLine =
      lineEnd == std::string_view::npos ? head : head.substr(0, lineEnd);
  // RFC 9112 §3: the request line is visible ASCII separated by single
  // spaces — a control byte, DEL or a byte >= 0x80 is a parse failure (400),
  // never something to forward to a handler or a log line.
  for (const char ch : requestLine) {
    const unsigned char u = (unsigned char)ch;
    if (u < 0x21 && ch != ' ') return p;
    if (u >= 0x7f) return p;
  }
  const size_t sp1 = requestLine.find(' ');
  const size_t sp2 = sp1 == std::string_view::npos
                         ? std::string_view::npos
                         : requestLine.find(' ', sp1 + 1);
  if (sp1 == std::string_view::npos || sp2 == std::string_view::npos) return p;
  if (sp1 == 0 || sp2 == sp1 + 1) return p;  // empty method / target
  p.method = parseMethod(requestLine.substr(0, sp1), p.customMethod);
  std::string_view target = requestLine.substr(sp1 + 1, sp2 - sp1 - 1);
  const std::string_view version = requestLine.substr(sp2 + 1);
  // Only HTTP/1.0 and HTTP/1.1 are spoken here (RFC 9110 §15.6.6: 505).
  if (version != "HTTP/1.1" && version != "HTTP/1.0") {
    p.badVersion = true;
    return p;
  }
  p.version.assign(version.data(), version.size());
  // Target forms (RFC 9112 §3.2): origin-form `/path`, asterisk-form `*`, or
  // absolute-form `http[s]://authority/path` (a server MUST accept it) —
  // reduced to its path here; the Host header still governs the request.
  if (target.size() > 7 &&
      (target.substr(0, 7) == "http://" || target.substr(0, 8) == "https://")) {
    const size_t scheme = target.find("://") + 3;
    const size_t slash = target.find('/', scheme);
    target = slash == std::string_view::npos ? std::string_view("/")
                                             : target.substr(slash);
  } else if (target.front() != '/' && target != "*") {
    return p;
  }
  p.target.assign(target.data(), target.size());
  size_t pos = lineEnd == std::string_view::npos ? head.size() + 1 : lineEnd + 2;
  p.headers.reserve(8);
  while (pos <= head.size()) {
    const size_t eol = head.find("\r\n", pos);
    std::string_view line;
    if (eol == std::string_view::npos) {
      line = head.substr(pos);
      pos = head.size() + 1;
    } else {
      if (eol == pos) break;
      line = head.substr(pos, eol - pos);
      pos = eol + 2;
    }
    if (line.empty()) break;
    // RFC 9112 §5.1-5.2: a bare CR/LF, NUL or any other control byte inside a
    // field line is invalid — it is how a value smuggles a second field past a
    // peer that splits on LF (response splitting through a reflected header).
    // HTAB is the one permitted control. obs-fold (a line starting with SP /
    // HTAB) and whitespace between the field name and the colon are rejected
    // outright rather than repaired, as the RFC requires of a server.
    for (const char ch : line)
      if ((unsigned char)ch < 0x20 && ch != '\t') return p;
    if (line.front() == ' ' || line.front() == '\t') return p;
    const size_t colon = line.find(':');
    if (colon == std::string_view::npos || colon == 0) return p;
    if (line[colon - 1] == ' ' || line[colon - 1] == '\t') return p;
    const std::string_view name = line.substr(0, colon);
    const std::string_view value = trimSv(line.substr(colon + 1));
    // Field values are forwarded to Dart as strings: bytes >= 0x80 must form
    // valid UTF-8 (obs-text that is not — a Latin-1 User-Agent — would fail
    // the bridge's decoder and strand the request until its deadline).
    if (!ws::validUtf8((const uint8_t*)value.data(), value.size())) return p;
    for (const char ch : name)
      if ((unsigned char)ch >= 0x80) return p;
    p.headers.push_back({std::string(name), std::string(value)});
  }
  p.ok = true;
  return p;
}

}  // namespace

ParsedHead parseRequestHead(const std::string& raw, size_t headEnd) {
  return parseHead(raw, headEnd);
}

}  // namespace nitroserver
