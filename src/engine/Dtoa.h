#pragma once

#include <cstddef>
#include <cstdio>
#include <cstdlib>

namespace nitroserver {

// Shortest round-trip scientific form of a finite positive double, as
// "d[.ddd]e±xx" — the digits std::to_chars(..., chars_format::scientific)
// writes. The smallest precision whose correctly rounded %.*e parses back to
// `v` has the fewest digits, and at that length the correctly rounded value is
// the closest, so the digits equal to_chars's (the exponent may carry a
// leading zero, e.g. "e+05"; callers parse it numerically). Used where the
// platform's libc++ has no floating-point to_chars (iOS < 16.3). `cap` >= 32.
inline int sciShortestPortable(char* out, size_t cap, double v) {
  for (int prec = 0; prec <= 17; prec++) {
    const int len = std::snprintf(out, cap, "%.*e", prec, v);
    if (std::strtod(out, nullptr) == v) return len;
  }
  return std::snprintf(out, cap, "%.17e", v);
}

}  // namespace nitroserver
