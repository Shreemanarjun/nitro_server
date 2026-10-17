// Unit tests for the adaptive dispatch-width policy. The controller is a closed
// loop: the width it returns determines the throughput the next tick sees, so
// each test models answers = f(width) and drives it to convergence.
#include "DispatchController.h"

#include <gtest/gtest.h>

#include <functional>

using nitroserver::DispatchController;

namespace {

// Run `ticks` of the closed loop under a workload model answers=model(width),
// at the given backlog and isolate count. Returns the settled width.
size_t converge(DispatchController& dc, const std::function<double(size_t)>& model,
                int64_t backlog, size_t maxWidth, int ticks) {
  size_t width = 1;
  for (int i = 0; i < ticks; i++)
    width = dc.tick(model(width), backlog, maxWidth);
  return dc.width();
}

constexpr int64_t kBusy = 64;  // saturated backlog

}  // namespace

// A light handler is fastest on one isolate: fanning out lowers throughput, so
// the controller must settle at width 1 even with 8 isolates available.
TEST(DispatchControllerTest, LightHandlerSettlesAtOne) {
  DispatchController dc;
  const size_t w = converge(dc, [](size_t width) { return 100000.0 / width; },
                            kBusy, 8, 80);
  EXPECT_EQ(w, 1u);
}

// A CPU-bound handler scales with isolates: throughput rises with width, so the
// controller must climb all the way to the isolate count.
TEST(DispatchControllerTest, CpuBoundClimbsToMaxWidth) {
  DispatchController dc;
  const size_t w = converge(dc, [](size_t width) { return 5000.0 * width; },
                            kBusy, 8, 80);
  EXPECT_EQ(w, 8u);
}

// Throughput that peaks at an intermediate width: the controller should settle
// at (or adjacent to) the peak, not the extremes.
TEST(DispatchControllerTest, SettlesNearAnInteriorPeak) {
  DispatchController dc;
  // Peak at width 4; falls off on either side.
  const size_t w = converge(
      dc,
      [](size_t width) {
        const double d = (double)width - 4.0;
        return 50000.0 - 2000.0 * d * d;
      },
      kBusy, 8, 160);
  EXPECT_GE(w, 2u);
  EXPECT_LE(w, 4u);
}

// When the workload shifts from light to CPU-bound, the controller must notice
// and climb — it cannot stay pinned at the width that was once optimal.
TEST(DispatchControllerTest, AdaptsWhenWorkloadShifts) {
  DispatchController dc;
  converge(dc, [](size_t width) { return 100000.0 / width; }, kBusy, 8, 60);
  EXPECT_EQ(dc.width(), 1u);
  const size_t w = converge(dc, [](size_t width) { return 5000.0 * width; },
                            kBusy, 8, 200);
  EXPECT_EQ(w, 8u);
}

// With little backlog nothing is bottlenecked on handlers, so concentrate on one
// isolate regardless of how expensive a request would be.
TEST(DispatchControllerTest, ConcentratesWhenNotSaturated) {
  DispatchController dc;
  const size_t w = converge(dc, [](size_t width) { return 5000.0 * width; },
                            /*backlog=*/1, 8, 80);
  EXPECT_EQ(w, 1u);
}

// One isolate: there is nothing to fan out to, so the width is always 1.
TEST(DispatchControllerTest, SingleIsolateAlwaysWidthOne) {
  DispatchController dc;
  for (int i = 0; i < 20; i++)
    EXPECT_EQ(dc.tick(1000.0, kBusy, 1), 1u);
}

// A server that starts idle then suddenly saturates with CPU-bound work must
// still climb — the light startup must not pin it low forever.
TEST(DispatchControllerTest, StartupLightThenSpikeClimbs) {
  DispatchController dc;
  for (int i = 0; i < 3; i++) {
    dc.tick(500.0, /*backlog=*/2, 8);  // light startup: not saturated
    EXPECT_EQ(dc.width(), 1u);
  }
  const size_t w = converge(dc, [](size_t width) { return 5000.0 * width; },
                            kBusy, 8, 120);
  EXPECT_GE(w, 4u);  // climbed well once the spike arrived
}

// Rapidly alternating light/CPU-bound phases must never wedge the controller at
// an extreme or out of range; it stays in [1, maxWidth] and still responds.
TEST(DispatchControllerTest, RapidOscillationStaysInRange) {
  DispatchController dc;
  for (int cycle = 0; cycle < 6; cycle++) {
    const bool heavy = cycle % 2 == 0;
    for (int i = 0; i < 40; i++) {
      const size_t w = heavy ? dc.tick(5000.0 * dc.width(), kBusy, 8)
                             : dc.tick(100000.0 / dc.width(), kBusy, 8);
      EXPECT_GE(w, 1u);
      EXPECT_LE(w, 8u);
    }
  }
  // End on a sustained CPU-bound tail: it must recover and fan out.
  const size_t w = converge(dc, [](size_t width) { return 5000.0 * width; },
                            kBusy, 8, 150);
  EXPECT_GE(w, 4u);
}
