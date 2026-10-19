# Dockerized black-box benchmark

A **controlled, reproducible** environment for the `nitro_server` vs
`dart:io` / `shelf` / Go / Node comparison. The point is that anyone — on any
host with Docker — can run the *same* pinned container on the *same* pinned
cores and get a comparable result, instead of chasing numbers that drift with
the host's background load and the engine's adaptive dispatch controller.

## Run it

From the repo root:

```bash
benchmark/docker/bench.sh                 # 4 cores (0-3), 4 GiB
benchmark/docker/bench.sh --cpus 0-7 --mem 8g
benchmark/docker/bench.sh -- --batch-events   # pass extra compare flags
```

Output lands in `benchmark/docker/out/`:

| file | what |
|------|------|
| `results.txt` | adaptive **and** pinned, side by side |
| `results-adaptive.txt` | controller auto — production-realistic |
| `results-pinned.txt` | controller frozen (`NITRO_DISPATCH`) — deterministic |

## Why two controller modes

The engine has an **adaptive dispatch controller** that sizes the
worker/isolate fan-out from live load. That is the right behavior in
production, but its convergence can vary slightly run-to-run, which is exactly
what you do *not* want in a reproducible comparison. So the harness measures
both:

- **Adaptive** — what a real deployment sees.
- **Pinned** — `NITRO_DISPATCH` freezes the dispatch width (default `1`, the
  single-isolate I/O sweet spot the headline uses), removing the controller as
  a variable so the number is a true black box.

If the two columns differ materially, that *is* the controller's contribution;
if they match (as they do at the default single-isolate config, where the
width is 1 either way), the controller is not a factor for that config.

## What is held fixed

- **Base image** — pinned `DART_VERSION` (pin a digest in the Dockerfile for
  byte-exact reproduction). Go and Node come from that base's apt repo and
  their exact versions are printed into every results header.
- **CPU** — `--cpuset-cpus` pins the exact cores; `nproc`/`GOMAXPROCS` follow.
- **Memory** — `--memory == --memory-swap` (no swap).
- **Build** — engine `Release`, **HTTP/2 off** (matches `benchmark/run_all.sh`);
  change via the `ENGINE_FLAGS` build arg.
- **Driver** — same `compare.dart`, `--keep-alive`, same isolate count.

## Caveats

- Linux-container numbers are **not** comparable to bare-metal macOS numbers
  (different kernel, scheduler, and — on Docker Desktop / colima — a VM layer).
  They are comparable to *each other* and to anyone else running this image on
  the same cpuset. Use the host `benchmark/run_all.sh` for native-macOS numbers.
- Pin the base-image **digest** (not just the version tag) if you need
  bit-for-bit reproducibility across time; tags move.
