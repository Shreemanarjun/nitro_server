# Experiments

Standalone spikes that inform engine design. Not part of the build or CI.

## `uv_reactor_spike.c`

A libuv reactor prototype in the shape a libuv-backed nitro engine would take
for the engine-served (`getStatic`) path: N event loops (one per thread) over
`SO_REUSEPORT` listeners, each serving a fixed keep-alive response. Measures
libuv's connection-scaling ceiling against Go `net/http` and nitro's
thread-per-connection pool (see `../README.md` → Connection scaling).

Build (macOS, libuv via Homebrew; Linux: `apt install libuv1-dev`):

```
cc uv_reactor_spike.c -o uv_reactor_spike \
   -I/opt/homebrew/include -L/opt/homebrew/lib -luv -lpthread -O2
DYLD_LIBRARY_PATH=/opt/homebrew/lib ./uv_reactor_spike 8100 4   # port, loops
```

Drive it with the same raw keep-alive loadgen used for the other sides.
Measured (8-core, /static-equivalent, req/s): ~147k @64 conns, ~145k @256,
~145k @512, ~143k @1024 — flat and above Go, where nitro's pool dips past a
few hundred connections. Validation for building the engine I/O core on libuv.
