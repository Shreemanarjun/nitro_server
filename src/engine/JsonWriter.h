// Native JSON writer, reached from Dart through the NitroServerNative spec
// (`json*` methods). The writer is an opaque handle; byte arguments point at
// native memory Dart reuses (tokens, scratch), so no call copies.
#pragma once

#include <cstdint>

namespace nitroserver::jw {

void* create();
void destroy(void* w);
void reset(void* w);
uint8_t* alloc(int64_t bytes);
void freeBuffer(void* p);
void beginObject(void* w);
void endObject(void* w);
void beginArray(void* w);
void endArray(void* w);
void key(void* w, const uint8_t* k, int64_t n);
void writeInt(void* w, int64_t v);
void writeDouble(void* w, double v);
void writeString(void* w, const uint8_t* s, int64_t n);
void writeBool(void* w, bool v);
void writeNull(void* w);
void writeRaw(void* w, const uint8_t* r, int64_t n);
// A JSON array of `n` records from a fixed template, in one call. Each record
// interleaves `k` constant segments with `k` numeric columns: seg[0]
// col[0][row] seg[1] ... col[k-1][row] seg[k]. `segPtrs`/`segLens` have k+1
// entries; `colTypes[c]` is 0 for an int64 column, 1 for a double column, and
// `colData[c]` points at that column's n-element array.
void emitTemplate(void* w, int64_t n, int64_t k, const uint8_t* const* segPtrs,
                  const int32_t* segLens, const uint8_t* colTypes,
                  const void* const* colData);
const uint8_t* bytes(void* w);
int64_t length(void* w);

}  // namespace nitroserver::jw
