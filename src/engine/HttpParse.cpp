// HTTP request-head parser, shared by the engine and the fuzz target. Extracted
// from the retired ServerInstance so parseRequestHead survives its deletion.
#include "EngineTypes.h"

#include <string>
#include <string_view>

#include "Common.h"

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
  const size_t lineEnd = head.find("\r\n");
  if (lineEnd == std::string_view::npos) return p;
  const std::string_view requestLine = head.substr(0, lineEnd);
  const size_t sp1 = requestLine.find(' ');
  const size_t sp2 = sp1 == std::string_view::npos
                         ? std::string_view::npos
                         : requestLine.find(' ', sp1 + 1);
  if (sp1 == std::string_view::npos || sp2 == std::string_view::npos) return p;
  p.method = parseMethod(requestLine.substr(0, sp1), p.customMethod);
  const std::string_view target = requestLine.substr(sp1 + 1, sp2 - sp1 - 1);
  p.target.assign(target.data(), target.size());
  const std::string_view version = trimSv(requestLine.substr(sp2 + 1));
  p.version.assign(version.data(), version.size());
  // The head slice excludes the terminal \r\n\r\n, so the LAST header line has
  // no line ending — a loop that required one silently dropped it.
  size_t pos = lineEnd + 2;
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
    const size_t colon = line.find(':');
    if (colon == std::string_view::npos) return p;
    const std::string_view name = trimSv(line.substr(0, colon));
    const std::string_view value = trimSv(line.substr(colon + 1));
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
