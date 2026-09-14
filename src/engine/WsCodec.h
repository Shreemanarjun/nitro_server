// ─────────────────────────────────────────────────────────────────────────────
// WsCodec — RFC 6455 handshake + wire frame helpers.
//
// Header-only (no build-list changes): SHA-1, base64, the accept-key
// derivation, frame parse/encode and a UTF-8 validator. The connection loop
// itself lives in ServerInstance, which owns the socket and the send mutex.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace nitroserver {
namespace ws {

/// The RFC 6455 magic GUID concatenated with the client key before hashing.
inline const char* handshakeGuid() {
  return "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
}

inline uint32_t rol32(uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }

/// SHA-1 (FIPS 180-4). Small, public-domain-style, no crypto dependency —
/// the engine needs exactly one hash (the handshake accept key), so linking
/// OpenSSL/LibreSSL for it would be absurd.
inline std::array<uint8_t, 20> sha1(const uint8_t* data, size_t len) {
  uint32_t h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE;
  uint32_t h3 = 0x10325476, h4 = 0xC3D2E1F0;

  // Padded message: data + 0x80 + zeros + 64-bit big-endian bit length.
  const size_t bitLen = len * 8;
  size_t padded = len + 1;
  while (padded % 64 != 56) padded++;
  padded += 8;
  std::vector<uint8_t> msg(padded, 0);
  if (len > 0) {
    for (size_t i = 0; i < len; i++) msg[i] = data[i];
  }
  msg[len] = 0x80;
  for (int i = 0; i < 8; i++) {
    msg[padded - 1 - i] = (uint8_t)((bitLen >> (8 * i)) & 0xff);
  }

  for (size_t off = 0; off < padded; off += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) {
      w[i] = ((uint32_t)msg[off + 4 * i] << 24) |
             ((uint32_t)msg[off + 4 * i + 1] << 16) |
             ((uint32_t)msg[off + 4 * i + 2] << 8) |
             (uint32_t)msg[off + 4 * i + 3];
    }
    for (int i = 16; i < 80; i++) {
      w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
    for (int i = 0; i < 80; i++) {
      uint32_t f, k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      const uint32_t tmp = rol32(a, 5) + f + e + k + w[i];
      e = d;
      d = c;
      c = rol32(b, 30);
      b = a;
      a = tmp;
    }
    h0 += a;
    h1 += b;
    h2 += c;
    h3 += d;
    h4 += e;
  }

  std::array<uint8_t, 20> out{};
  const uint32_t hs[5] = {h0, h1, h2, h3, h4};
  for (int i = 0; i < 5; i++) {
    out[4 * i] = (uint8_t)((hs[i] >> 24) & 0xff);
    out[4 * i + 1] = (uint8_t)((hs[i] >> 16) & 0xff);
    out[4 * i + 2] = (uint8_t)((hs[i] >> 8) & 0xff);
    out[4 * i + 3] = (uint8_t)(hs[i] & 0xff);
  }
  return out;
}

inline std::string base64Encode(const uint8_t* data, size_t len) {
  static const char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((len + 2) / 3) * 4);
  for (size_t i = 0; i < len; i += 3) {
    const uint32_t a = data[i];
    const uint32_t b = i + 1 < len ? data[i + 1] : 0;
    const uint32_t c = i + 2 < len ? data[i + 2] : 0;
    const uint32_t triple = (a << 16) | (b << 8) | c;
    out.push_back(kAlphabet[(triple >> 18) & 0x3f]);
    out.push_back(kAlphabet[(triple >> 12) & 0x3f]);
    out.push_back(i + 1 < len ? kAlphabet[(triple >> 6) & 0x3f] : '=');
    out.push_back(i + 2 < len ? kAlphabet[triple & 0x3f] : '=');
  }
  return out;
}

/// RFC 6455 §1.3: `Sec-WebSocket-Accept` for a client key.
inline std::string acceptKey(const std::string& clientKey) {
  const std::string input = clientKey + handshakeGuid();
  const auto digest =
      sha1((const uint8_t*)input.data(), input.size());
  return base64Encode(digest.data(), digest.size());
}

// Opcodes the engine speaks.
enum Opcode : int {
  kContinuation = 0x0,
  kText = 0x1,
  kBinary = 0x2,
  kClose = 0x8,
  kPing = 0x9,
  kPong = 0xA,
};

inline bool isControl(int opcode) { return opcode >= 0x8; }

/// One parsed frame header. `headerSize` covers the extension length and
/// the mask key, so the payload starts at `data + headerSize`.
struct FrameHeader {
  bool fin = false;
  int opcode = -1;
  bool masked = false;
  uint64_t length = 0;
  size_t headerSize = 0;
  uint8_t mask[4] = {0, 0, 0, 0};
};

/// Parses a frame header. Returns false when fewer than `headerSize` bytes
/// are buffered (caller reads more) or the frame is malformed: nonzero RSV
/// (no extensions negotiated), unknown opcode, control frame fragmented or
/// over 125 bytes, or a 64-bit length with the top bit set.
inline bool parseHeader(const uint8_t* data, size_t n, FrameHeader& out) {
  if (n < 2) return false;
  const uint8_t b0 = data[0], b1 = data[1];
  if (b0 & 0x70) return false;  // RSV1-3: no extensions, ever.
  const int opcode = b0 & 0x0f;
  if (opcode != 0x0 && opcode != 0x1 && opcode != 0x2 && opcode != 0x8 &&
      opcode != 0x9 && opcode != 0xA) {
    return false;
  }
  const bool masked = (b1 & 0x80) != 0;
  uint64_t length = b1 & 0x7f;
  size_t pos = 2;
  if (length == 126) {
    if (n < pos + 2) return false;
    length = ((uint64_t)data[pos] << 8) | data[pos + 1];
    pos += 2;
  } else if (length == 127) {
    if (n < pos + 8) return false;
    if (data[pos] & 0x80) return false;  // Lengths >= 2^63 are forbidden.
    length = 0;
    for (int i = 0; i < 8; i++) length = (length << 8) | data[pos + i];
    pos += 8;
  }
  if (isControl(opcode)) {
    if (!(b0 & 0x80)) return false;  // Control frames are never fragmented.
    if (length > 125) return false;
  }
  FrameHeader h;
  h.fin = (b0 & 0x80) != 0;
  h.opcode = opcode;
  h.masked = masked;
  h.length = length;
  if (masked) {
    if (n < pos + 4) return false;
    for (int i = 0; i < 4; i++) h.mask[i] = data[pos + i];
    pos += 4;
  }
  h.headerSize = pos;
  out = h;
  return true;
}

/// Encodes one server-side (never masked) frame into [out].
inline void encodeFrame(int opcode, const uint8_t* payload, size_t n,
                        bool fin, std::vector<uint8_t>& out) {
  out.push_back((uint8_t)((fin ? 0x80 : 0x00) | (opcode & 0x0f)));
  if (n < 126) {
    out.push_back((uint8_t)n);
  } else if (n <= 0xffff) {
    out.push_back(126);
    out.push_back((uint8_t)((n >> 8) & 0xff));
    out.push_back((uint8_t)(n & 0xff));
  } else {
    out.push_back(127);
    for (int i = 7; i >= 0; i--) {
      out.push_back((uint8_t)((n >> (8 * i)) & 0xff));
    }
  }
  out.insert(out.end(), payload, payload + n);
}

/// Strict UTF-8 check for text messages (RFC 6455 §5.6: fail on invalid).
inline bool validUtf8(const uint8_t* data, size_t n) {
  size_t i = 0;
  while (i < n) {
    const uint8_t c = data[i];
    size_t need = 0;
    if (c < 0x80) {
      i++;
      continue;
    } else if ((c & 0xe0) == 0xc0) {
      need = 1;
      if (c < 0xc2) return false;  // Overlong.
    } else if ((c & 0xf0) == 0xe0) {
      need = 2;
    } else if ((c & 0xf8) == 0xf0) {
      need = 3;
      if (c > 0xf4) return false;  // Beyond U+10FFFF.
    } else {
      return false;
    }
    if (i + need >= n) return false;
    for (size_t j = 1; j <= need; j++) {
      if ((data[i + j] & 0xc0) != 0x80) return false;
    }
    // Surrogates and overlong 3-byte forms.
    if (need == 2) {
      const uint32_t cp = ((uint32_t)(c & 0x0f) << 12) |
                          ((uint32_t)(data[i + 1] & 0x3f) << 6) |
                          (data[i + 2] & 0x3f);
      if (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff)) return false;
    }
    if (need == 3) {
      const uint32_t cp = ((uint32_t)(c & 0x07) << 18) |
                          ((uint32_t)(data[i + 1] & 0x3f) << 12) |
                          ((uint32_t)(data[i + 2] & 0x3f) << 6) |
                          (data[i + 3] & 0x3f);
      if (cp < 0x10000) return false;
    }
    i += 1 + need;
  }
  return true;
}

}  // namespace ws
}  // namespace nitroserver
