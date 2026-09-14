#pragma once

#include <vector>

namespace nitroserver {

struct PollerEvent {
  int fd;
  void* userData;
  bool canRead;
  bool canWrite;
};

class Poller {
 public:
  Poller();
  ~Poller();

  // Non-copyable
  Poller(const Poller&) = delete;
  Poller& operator=(const Poller&) = delete;

  /// Adds an fd to the poller.
  bool add(int fd, void* userData, bool read, bool write);

  /// Modifies the interest of an existing fd.
  bool modify(int fd, void* userData, bool read, bool write);

  /// Removes an fd from the poller.
  bool remove(int fd);

  /// Blocks until events are available or timeoutMs expires.
  /// Returns the number of events populated, or <0 on error.
  int wait(std::vector<PollerEvent>& events, int timeoutMs);

  /// Wakes up a currently blocking wait() call.
  void wakeup();

 private:
#if defined(__linux__)
  int epfd_ = -1;
  int wakeupFd_ = -1;
#elif defined(__APPLE__) || defined(__FreeBSD__)
  int kq_ = -1;
  int wakeupPipe_[2] = {-1, -1};
#else
  // Windows/Fallback
  struct PollContext;
  PollContext* ctx_ = nullptr;
#endif
};

}  // namespace nitroserver
