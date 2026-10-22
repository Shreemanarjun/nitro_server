// ─────────────────────────────────────────────────────────────────────────────
// nitro_server — shared engine types.
//
// Everything here is transport-independent: this file, Router and PendingTable
// are shared unchanged by the libuv reactor (UvReactor). Only the reactor
// itself (sockets + event loops) is transport.
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
  // A connection with an in-flight request closed (client disconnect): the
  // `requestId` names the dropped request so the Dart runner cancels its
  // outbound stream subscription. Crosses as an int64 (RawServerEvent.kind is
  // int), so the public Dart `ServerEventKind` must keep the same index 5.
  ClientDisconnect = 5,
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

/// The wire token of a known method (inverse of parseMethod); "" for Custom
/// (whose token lives beside it) and "*" for All.
inline const char* methodToken(Method m) {
  switch (m) {
    case Method::Get: return "GET";
    case Method::Head: return "HEAD";
    case Method::Post: return "POST";
    case Method::Put: return "PUT";
    case Method::Delete: return "DELETE";
    case Method::Patch: return "PATCH";
    case Method::Options: return "OPTIONS";
    case Method::Trace: return "TRACE";
    case Method::All: return "*";
    default: return "";
  }
}

inline const char* reasonPhrase(int64_t status) {
  switch (status) {
    case 100: return "Continue";
    case 101: return "Switching Protocols";
    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 204: return "No Content";
    case 206: return "Partial Content";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 303: return "See Other";
    case 304: return "Not Modified";
    case 307: return "Temporary Redirect";
    case 308: return "Permanent Redirect";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 406: return "Not Acceptable";
    case 408: return "Request Timeout";
    case 409: return "Conflict";
    case 410: return "Gone";
    case 411: return "Length Required";
    case 412: return "Precondition Failed";
    case 413: return "Content Too Large";
    case 414: return "URI Too Long";
    case 415: return "Unsupported Media Type";
    case 416: return "Range Not Satisfiable";
    case 417: return "Expectation Failed";
    case 422: return "Unprocessable Content";
    case 426: return "Upgrade Required";
    case 428: return "Precondition Required";
    case 429: return "Too Many Requests";
    case 431: return "Request Header Fields Too Large";
    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    case 505: return "HTTP Version Not Supported";
    default:
      // RFC 9112 §4: the reason phrase is informational; an unlisted code
      // still carries a valid status line (never the misleading "Unknown").
      return status >= 500 ? "Server Error" : status >= 400 ? "Client Error"
             : status >= 300 ? "Redirection" : status >= 200 ? "Success"
             : "Informational";
  }
}

}  // namespace nitroserver
