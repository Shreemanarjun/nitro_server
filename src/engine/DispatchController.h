#ifndef NITRO_SERVER_ENGINE_DISPATCH_CONTROLLER_H
#define NITRO_SERVER_ENGINE_DISPATCH_CONTROLLER_H

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace nitroserver {

// Hill-climbs the dispatch width — how many isolates requests are dealt across —
// toward maximum throughput. Fed one sample per sweep tick (answers completed
// and current backlog), tick() returns the width to use. Light handlers settle
// at 1 (one isolate saturates the cores-wide engine; fanning out only adds
// coordination cost); CPU-bound or head-of-line-blocked workloads climb toward
// every isolate. Pure policy — no engine deps, so it unit-tests in isolation and
// runs once per sweep (~100 ms), never on the request path.
class DispatchController {
 public:
  // answers: handler answers since the last tick (the throughput signal).
  // backlog: requests in flight. maxWidth: isolate count. Returns width >= 1.
  size_t tick(double answers, int64_t backlog, size_t maxWidth) {
    if (maxWidth <= 1) return 1;
    if (backlog < kSaturatedBacklog) {  // not backed up: nothing to parallelize
      reset();
      return width_;
    }
    if (!probing_) {  // settled: observe this width, dwell, then trial a step
      baseRate_ = answers;
      if (++dwell_ < dwellTarget_) return width_;
      dwell_ = 0;
      if (dir_ > 0 && width_ >= maxWidth) dir_ = -1;
      else if (dir_ < 0 && width_ <= 1) dir_ = 1;
      const size_t probe = step(width_, dir_, maxWidth);
      if (probe == width_) return width_;  // nowhere to go
      probe_ = probe;
      probing_ = true;
      return probe_;
    }
    if (answers > baseRate_ * kMargin) {  // step helped: commit, keep stepping
      width_ = probe_;
      baseRate_ = answers;
      dwellTarget_ = kDwellMin;
      const size_t next = step(width_, dir_, maxWidth);
      if (next != width_) {
        probe_ = next;
        return probe_;
      }
      probing_ = false;  // hit a bound: settle here
      return width_;
    }
    probing_ = false;  // step did not help: revert, flip, back off re-probing
    dir_ = -dir_;
    dwellTarget_ = std::min(kDwellMax, dwellTarget_ * 2);
    return width_;
  }

  size_t width() const { return width_; }

 private:
  static size_t step(size_t w, int dir, size_t maxWidth) {
    return dir > 0 ? std::min(maxWidth, w * 2) : std::max<size_t>(1, w / 2);
  }
  void reset() {
    width_ = probe_ = 1;
    baseRate_ = -1;
    probing_ = false;
    dir_ = 1;
    dwell_ = 0;
    dwellTarget_ = kDwellMin;
  }

  static constexpr int64_t kSaturatedBacklog = 8;  // below this, concentrate
  static constexpr int kDwellMin = 4;              // ticks between probes, adapting
  static constexpr int kDwellMax = 50;             // ~5 s cap once optimal
  static constexpr double kMargin = 1.05;          // a probe must beat settled 5%

  size_t width_ = 1;         // committed width (best known)
  size_t probe_ = 1;         // width being trialled
  double baseRate_ = -1;     // throughput at the committed width
  bool probing_ = false;     // trialling a step vs. settled and dwelling
  int dir_ = 1;              // +1 wider, -1 narrower
  int dwell_ = 0;            // settled ticks toward the next probe
  int dwellTarget_ = kDwellMin;
};

}  // namespace nitroserver

#endif  // NITRO_SERVER_ENGINE_DISPATCH_CONTROLLER_H
