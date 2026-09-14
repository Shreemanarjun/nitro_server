#include "Poller.h"

#include <stdexcept>
#include <system_error>

#if defined(__linux__)
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#elif defined(__APPLE__) || defined(__FreeBSD__)
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>
#include <fcntl.h>
#else
// Windows/Fallback
#ifdef _WIN32
#include <winsock2.h>
#else
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#endif
#include <unordered_map>
#include <mutex>
#endif

namespace nitroserver {

#if defined(__linux__)

Poller::Poller() {
  epfd_ = epoll_create1(EPOLL_CLOEXEC);
  if (epfd_ < 0) throw std::system_error(errno, std::generic_category(), "epoll_create1");

  wakeupFd_ = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (wakeupFd_ < 0) {
    close(epfd_);
    throw std::system_error(errno, std::generic_category(), "eventfd");
  }

  epoll_event ev{};
  ev.events = EPOLLIN | EPOLLET;
  ev.data.ptr = nullptr; // nullptr means wakeup
  if (epoll_ctl(epfd_, EPOLL_CTL_ADD, wakeupFd_, &ev) != 0) {
    close(wakeupFd_);
    close(epfd_);
    throw std::system_error(errno, std::generic_category(), "epoll_ctl wakeupFd");
  }
}

Poller::~Poller() {
  if (wakeupFd_ >= 0) close(wakeupFd_);
  if (epfd_ >= 0) close(epfd_);
}

bool Poller::add(int fd, void* userData, bool read, bool write) {
  epoll_event ev{};
  ev.events = EPOLLET; // Edge-triggered
  if (read) ev.events |= EPOLLIN;
  if (write) ev.events |= EPOLLOUT;
  ev.data.ptr = userData;
  return epoll_ctl(epfd_, EPOLL_CTL_ADD, fd, &ev) == 0;
}

bool Poller::modify(int fd, void* userData, bool read, bool write) {
  epoll_event ev{};
  ev.events = EPOLLET;
  if (read) ev.events |= EPOLLIN;
  if (write) ev.events |= EPOLLOUT;
  ev.data.ptr = userData;
  return epoll_ctl(epfd_, EPOLL_CTL_MOD, fd, &ev) == 0;
}

bool Poller::remove(int fd) {
  return epoll_ctl(epfd_, EPOLL_CTL_DEL, fd, nullptr) == 0;
}

int Poller::wait(std::vector<PollerEvent>& events, int timeoutMs) {
  epoll_event evs[64];
  int n = epoll_wait(epfd_, evs, 64, timeoutMs);
  if (n < 0) return -1;

  events.clear();
  for (int i = 0; i < n; ++i) {
    if (evs[i].data.ptr == nullptr) {
      // Wakeup event
      uint64_t val;
      ::read(wakeupFd_, &val, sizeof(val));
      continue;
    }
    PollerEvent e{};
    e.fd = -1; // Not tracked explicitly in event, we use userData
    e.userData = evs[i].data.ptr;
    e.canRead = (evs[i].events & (EPOLLIN | EPOLLERR | EPOLLHUP)) != 0;
    e.canWrite = (evs[i].events & EPOLLOUT) != 0;
    events.push_back(e);
  }
  return events.size();
}

void Poller::wakeup() {
  uint64_t val = 1;
  ::write(wakeupFd_, &val, sizeof(val));
}

#elif defined(__APPLE__) || defined(__FreeBSD__)

Poller::Poller() {
  kq_ = kqueue();
  if (kq_ < 0) throw std::system_error(errno, std::generic_category(), "kqueue");

  if (pipe(wakeupPipe_) != 0) {
    close(kq_);
    throw std::system_error(errno, std::generic_category(), "pipe");
  }
  fcntl(wakeupPipe_[0], F_SETFL, O_NONBLOCK);
  fcntl(wakeupPipe_[1], F_SETFL, O_NONBLOCK);

  struct kevent ev;
  EV_SET(&ev, wakeupPipe_[0], EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, nullptr);
  if (kevent(kq_, &ev, 1, nullptr, 0, nullptr) != 0) {
    close(wakeupPipe_[0]); close(wakeupPipe_[1]); close(kq_);
    throw std::system_error(errno, std::generic_category(), "kevent pipe");
  }
}

Poller::~Poller() {
  if (wakeupPipe_[0] >= 0) close(wakeupPipe_[0]);
  if (wakeupPipe_[1] >= 0) close(wakeupPipe_[1]);
  if (kq_ >= 0) close(kq_);
}

bool Poller::add(int fd, void* userData, bool read, bool write) {
  struct kevent ev[2];
  int n = 0;
  if (read) {
    EV_SET(&ev[n++], fd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, userData);
  }
  if (write) {
    EV_SET(&ev[n++], fd, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0, 0, userData);
  }
  if (n == 0) return true;
  return kevent(kq_, ev, n, nullptr, 0, nullptr) == 0;
}

bool Poller::modify(int fd, void* userData, bool read, bool write) {
  // kqueue requires explicitly deleting filters if they are no longer needed.
  // For simplicity, we just delete both and add the needed ones.
  struct kevent ev[4];
  int n = 0;
  EV_SET(&ev[n++], fd, EVFILT_READ, EV_DELETE, 0, 0, nullptr);
  EV_SET(&ev[n++], fd, EVFILT_WRITE, EV_DELETE, 0, 0, nullptr);
  if (read) {
    EV_SET(&ev[n++], fd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, userData);
  }
  if (write) {
    EV_SET(&ev[n++], fd, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0, 0, userData);
  }
  // Ignore errors on DELETE (it might not have existed)
  kevent(kq_, ev, 2, nullptr, 0, nullptr);
  if (n > 2) {
    return kevent(kq_, ev + 2, n - 2, nullptr, 0, nullptr) == 0;
  }
  return true;
}

bool Poller::remove(int fd) {
  struct kevent ev[2];
  EV_SET(&ev[0], fd, EVFILT_READ, EV_DELETE, 0, 0, nullptr);
  EV_SET(&ev[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, nullptr);
  kevent(kq_, ev, 2, nullptr, 0, nullptr);
  return true;
}

int Poller::wait(std::vector<PollerEvent>& events, int timeoutMs) {
  struct kevent evs[64];
  struct timespec ts;
  ts.tv_sec = timeoutMs / 1000;
  ts.tv_nsec = (timeoutMs % 1000) * 1000000;
  
  int n = kevent(kq_, nullptr, 0, evs, 64, timeoutMs >= 0 ? &ts : nullptr);
  if (n < 0) return -1;

  events.clear();
  for (int i = 0; i < n; ++i) {
    if (evs[i].udata == nullptr) {
      char buf[8];
      ::read(wakeupPipe_[0], buf, sizeof(buf));
      continue;
    }
    PollerEvent e{};
    e.fd = (int)evs[i].ident;
    e.userData = evs[i].udata;
    e.canRead = evs[i].filter == EVFILT_READ;
    e.canWrite = evs[i].filter == EVFILT_WRITE;
    // Combine if there are multiple events for the same fd
    bool merged = false;
    for (auto& existing : events) {
      if (existing.userData == e.userData) {
        existing.canRead |= e.canRead;
        existing.canWrite |= e.canWrite;
        merged = true;
        break;
      }
    }
    if (!merged) events.push_back(e);
  }
  return events.size();
}

void Poller::wakeup() {
  char b = 1;
  ::write(wakeupPipe_[1], &b, 1);
}

#else

// Windows / generic poll fallback (Not implemented for this benchmark pass, but stubbed for compilation)
struct Poller::PollContext {};

Poller::Poller() {}
Poller::~Poller() {}
bool Poller::add(int fd, void* userData, bool read, bool write) { return true; }
bool Poller::modify(int fd, void* userData, bool read, bool write) { return true; }
bool Poller::remove(int fd) { return true; }
int Poller::wait(std::vector<PollerEvent>& events, int timeoutMs) { return 0; }
void Poller::wakeup() {}

#endif

}  // namespace nitroserver
