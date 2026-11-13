/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "watchdog.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static bool private_setup(void)
{
  struct stat st; int type, domain; struct ucred peer;
  socklen_t size = sizeof(type);
  if (geteuid() || fstat(3, &st) || !S_ISREG(st.st_mode) || st.st_uid ||
      (st.st_mode & 0777) != 0600 || st.st_nlink != 1 ||
      getsockopt(4, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_SEQPACKET) return false;
  size = sizeof(domain);
  if (getsockopt(4, SOL_SOCKET, SO_DOMAIN, &domain, &size) || domain != AF_UNIX) return false;
  size = sizeof(peer);
  if (getsockopt(4, SOL_SOCKET, SO_PEERCRED, &peer, &size) || peer.uid || peer.pid != getppid()) return false;
  /* A separate open must conflict with the inherited lock, while the inherited
   * description itself must own it. This rejects a missing/unlocked setup. */
  int other = open("/proc/self/fd/3", O_RDWR | O_CLOEXEC);
  if (other < 0) return false;
  int result = flock(other, LOCK_EX | LOCK_NB), saved = errno;
  close(other);
  return result < 0 && (saved == EWOULDBLOCK || saved == EAGAIN) && !flock(3, LOCK_EX | LOCK_NB);
}
static bool host_namespace(void)
{
  struct stat self, init;
  return !stat("/proc/self/ns/net", &self) && !stat("/proc/1/ns/net", &init) &&
    self.st_dev == init.st_dev && self.st_ino == init.st_ino;
}
static int route_socket(uint32_t *port)
{
  int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
  if (fd < 0) return -1;
  struct sockaddr_nl local = { .nl_family = AF_NETLINK };
  socklen_t size = sizeof(local);
  if (bind(fd, (struct sockaddr *)&local, sizeof(local)) ||
      getsockname(fd, (struct sockaddr *)&local, &size) || size != sizeof(local) ||
      local.nl_family != AF_NETLINK || !local.nl_pid || local.nl_groups) { close(fd); return -1; }
  *port = local.nl_pid; return fd;
}
int main(int argc, char **argv)
{
  (void)argv;
  if (argc != 1 || !private_setup()) return 1;
  signal(SIGPIPE, SIG_IGN);
  int route = -1; uint32_t port = 0;
  for (;;) {
    struct wd_message request;
    if (wd_receive(4, &request, 0) != 1) break;
    if (request.type != WD_REQUEST || !request.sequence || request.error || request.started_ns || request.completed_ns) break;
    struct wd_message result = { .type = WD_COMPLETED, .sequence = request.sequence };
    if (!host_namespace()) result.error = WD_NAMESPACE;
    else if (route < 0 && (route = route_socket(&port)) < 0) result.error = WD_SOCKET;
    else {
      uint32_t sequence = (uint32_t)request.sequence; if (!sequence) sequence = 1;
      struct wd_request wire; wd_request_init(&wire, sequence, port);
      struct sockaddr_nl kernel = { .nl_family = AF_NETLINK };
      struct iovec iov = { .iov_base = &wire, .iov_len = sizeof(wire) };
      struct msghdr msg = { .msg_name = &kernel, .msg_namelen = sizeof(kernel), .msg_iov = &iov, .msg_iovlen = 1 };
      result.started_ns = wd_now();
      struct wd_message started = { .type = WD_STARTED, .sequence = request.sequence, .started_ns = result.started_ns };
      if (wd_send(4, &started)) break; /* Never start an unannounced call. */
      if (sendmsg(route, &msg, 0) != sizeof(wire)) result.error = WD_SEND;
      else {
        unsigned char buffer[256]; struct sockaddr_nl sender;
        iov = (struct iovec){ .iov_base = buffer, .iov_len = sizeof(buffer) };
        msg = (struct msghdr){ .msg_name = &sender, .msg_namelen = sizeof(sender), .msg_iov = &iov, .msg_iovlen = 1 };
        ssize_t n = recvmsg(route, &msg, 0);
        result.error = n < 0 ? WD_RECEIVE : wd_reply(buffer, (size_t)n, &sender, msg.msg_namelen, msg.msg_flags, &wire);
      }
    }
    result.completed_ns = wd_now();
    if (result.error && route >= 0) { close(route); route = -1; }
    if (wd_send(4, &result)) break;
  }
  if (route >= 0) close(route);
  close(4); close(3); return 0;
}
