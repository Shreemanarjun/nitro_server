# nitro_server — project rules

## Benchmarking (rule)

Any performance claim about nitro_server MUST follow
[benchmark/BENCHMARKING.md](benchmark/BENCHMARKING.md). The short version,
non-negotiable because dev-machine variance is ~10–15% (big enough to fake or
hide a whole framework's difference):

- **Cross-framework or `@Native` vs `_dylib` → use the blackbox harness**
  `benchmark/blackbox/run.sh` (each framework is an opaque HTTP server hit by
  `oha`, in a pinned container).
- **Disjoint pinned cores** — server and load generator on different cores
  (needs a Linux container host; `colima start` on macOS).
- **Interleave + median, never two separate full runs** — measure every target
  once per rep, loop N reps, report the median. Two separate full runs are
  banned (their drift dwarfs the real delta — it once invented a phantom
  "@Native regression").
- **Warm up, one server at a time, AOT, keep-alive is the headline.**
- SSE/WebSocket/getStatic aren't in the blackbox (oha can't drive open streams)
  — use `benchmark/compare.dart --keep-alive` for those.

Settled: `@Native` vs `_dylib` is perf-**neutral** for this workload; `@Native`
buys packaging (self-contained code asset, no cmake for consumers), not speed.
Re-run the blackbox A/B before re-opening that question.
