/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "watchdog.h"
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <unistd.h>
extern char **environ;
int wd_spawn(const char *helper, int lock_fd, pid_t *pid, int *ipc_fd)
{
  *pid = 0; *ipc_fd = -1;
  int pair[2]; if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair)) return -1;
  int lock_copy = fcntl(lock_fd, F_DUPFD_CLOEXEC, 10);
  int ipc_copy = fcntl(pair[1], F_DUPFD_CLOEXEC, 10);
  if (lock_copy < 0 || ipc_copy < 0) goto fail;
  posix_spawn_file_actions_t actions;
  int error = posix_spawn_file_actions_init(&actions);
  if (error) { errno = error; goto fail; }
#define ACTION(call) do { if (!error) error = (call); } while (0)
  ACTION(posix_spawn_file_actions_adddup2(&actions, lock_copy, 3));
  ACTION(posix_spawn_file_actions_adddup2(&actions, ipc_copy, 4));
  for (int i = 0; i < 3; i++) ACTION(posix_spawn_file_actions_addopen(&actions, i, "/dev/null", O_RDWR, 0));
  ACTION(posix_spawn_file_actions_addclosefrom_np(&actions, 5));
  char *const args[] = { (char *)helper, NULL };
  pid_t child = 0;
  if (!error) error = posix_spawn(&child, helper, &actions, NULL, args, environ);
  posix_spawn_file_actions_destroy(&actions);
#undef ACTION
  if (error) { errno = error; goto fail; }
  *pid = child;
  close(lock_copy); close(ipc_copy); close(pair[1]);
  int flags = fcntl(pair[0], F_GETFL);
  if (flags >= 0 && !fcntl(pair[0], F_SETFL, flags | O_NONBLOCK)) { *ipc_fd = pair[0]; return 0; }
  /* Spawn already happened. Keep its PID visible; closing IPC asks it to exit,
   * and the caller must reap it before any replacement. */
  close(pair[0]); *ipc_fd = -1; return -1;
fail:
  { int saved = errno;
    if (lock_copy >= 0) close(lock_copy);
    if (ipc_copy >= 0) close(ipc_copy);
    close(pair[0]); close(pair[1]); errno = saved; return -1;
  }
}
int wd_send(int fd, const struct wd_message *message)
{
  ssize_t n = send(fd, message, sizeof(*message), MSG_NOSIGNAL | MSG_DONTWAIT);
  return n == sizeof(*message) ? 0 : -1;
}
int wd_receive(int fd, struct wd_message *message, int flags)
{
  struct iovec iov = { .iov_base = message, .iov_len = sizeof(*message) };
  struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
  ssize_t n = recvmsg(fd, &msg, flags);
  if (n <= 0) return (int)n;
  if (n != sizeof(*message) || msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) { errno = EPROTO; return -1; }
  return 1;
}
