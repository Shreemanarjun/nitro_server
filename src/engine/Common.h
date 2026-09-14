// ─────────────────────────────────────────────────────────────────────────────
// nitro_server — shared engine types.
//
// Everything here is transport-independent: the day the accept loop moves to
// oat++'s HttpConnectionHandler, this file, Router and PendingTable move over
// unchanged. Only ServerInstance (sockets + threads) is transport.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace nitroserver {

// Must match RawServerMethod in nitro_server.native.dart.
enum class Method : int64_t {
  Get = 0,
  Head = 1,
  Post = 2,
  Put = 3,
  Delete = 4,
  Patch = 5,
  Options = 6,
  Trace = 7,
  All = 8,
  Custom = 9,
};

// Must match RawServerErrorKind in nitro_server.native.dart.
enum class ErrorKind : int64_t {
  None = 0,
  AlreadyRunning = 1,
  NotRunning = 2,
  BindFailed = 3,
  TlsError = 4,
  RouteNotFound = 5,
  HandlerTimeout = 6,
  RequestTooLarge = 7,
  ResponseTooLarge = 8,
  Io = 9,
  BadRequest = 10,
  Unknown = 11,
};

// Must match RawBodyKind in nitro_server.native.dart.
enum class BodyKind : int64_t {
  Data = 0,
  End = 1,
  Error = 2,
};

// Must match RawServerEventKind in nitro_server.native.dart.
enum class ServerEventKind : int64_t {
  Started = 0,
  Stopped = 1,
  HandlerTimeout = 2,
  ClientError = 3,
  Notice = 4,
};

struct Header {
  std::string name;
  std::string value;
};

struct RouteParam {
  std::string name;
  std::string value;
};

/// Parses an HTTP method token in place (no allocation on the hot path).
/// Unknown tokens become Custom.
inline Method parseMethod(std::string_view token, std::string& customOut) {
  if (token == "GET") return Method::Get;
  if (token == "HEAD") return Method::Head;
  if (token == "POST") return Method::Post;
  if (token == "PUT") return Method::Put;
  if (token == "DELETE") return Method::Delete;
  if (token == "PATCH") return Method::Patch;
  if (token == "OPTIONS") return Method::Options;
  if (token == "TRACE") return Method::Trace;
  customOut.assign(token.data(), token.size());
  return Method::Custom;
}

inline const char* reasonPhrase(int64_t status) {
  switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 408: return "Request Timeout";
    case 413: return "Content Too Large";
    case 426: return "Upgrade Required";
    case 500: return "Internal Server Error";
    case 503: return "Service Unavailable";
    default: return "Unknown";
  }
}

}  // namespace nitroserver
