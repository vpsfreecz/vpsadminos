/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "output.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
static void read_byte(int fd, char expected)
{
  struct pollfd p = { .fd = fd, .events = POLLIN }; assert(poll(&p, 1, 2000) == 1);
  char byte; assert(read(fd, &byte, 1) == 1 && byte == expected);
}
int main(int argc, char **argv)
{
  assert(argc == 3); char child_path[PATH_MAX], probe_path[PATH_MAX];
  assert(realpath(argv[1], child_path) && realpath(argv[2], probe_path));
  const char *root = getenv("WD_TEST_DIRECTORY"); if (!root) root = "/tmp";
  char directory[PATH_MAX]; assert(snprintf(directory, sizeof(directory), "%s/wd-unit-XXXXXX", root) < (int)sizeof(directory));
  assert(mkdtemp(directory));
  char lock_path[PATH_MAX], state_path[PATH_MAX], alias[PATH_MAX];
  assert(snprintf(lock_path, sizeof(lock_path), "%s/lock", directory) < (int)sizeof(lock_path));
  assert(snprintf(state_path, sizeof(state_path), "%s/state", directory) < (int)sizeof(state_path));
  assert(snprintf(alias, sizeof(alias), "%s/alias", directory) < (int)sizeof(alias));
  int lock = wd_lock(lock_path, geteuid()); assert(lock >= 0);
  assert(wd_lock(lock_path, geteuid()) < 0);
  struct stat identity; assert(!fstat(lock, &identity));
  pid_t child; int ipc;
  assert(!wd_spawn(child_path, lock, &child, &ipc)); read_byte(ipc, 'A');
  close(lock); assert(wd_lock(lock_path, geteuid()) < 0); /* Exec-inherited lock. */
  close(ipc); int status; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
  lock = wd_lock(lock_path, geteuid()); assert(lock >= 0); close(lock);
  /* A real owner process dies while its exec child keeps the same description. */
  assert(!prctl(PR_SET_CHILD_SUBREAPER, 1)); int report[2]; assert(!pipe2(report, O_CLOEXEC));
  pid_t owner = fork(); assert(owner >= 0);
  if (!owner) {
    close(report[0]); lock = wd_lock(lock_path, geteuid()); assert(lock >= 0);
    assert(!wd_spawn(child_path, lock, &child, &ipc)); read_byte(ipc, 'A');
    assert(send(ipc, "H", 1, MSG_NOSIGNAL) == 1); read_byte(ipc, 'B');
    assert(write(report[1], &child, sizeof(child)) == sizeof(child)); _exit(0);
  }
  close(report[1]); assert(read(report[0], &child, sizeof(child)) == sizeof(child)); close(report[0]);
  assert(waitpid(owner, &status, 0) == owner && WIFEXITED(status) && !WEXITSTATUS(status));
  assert(wd_lock(lock_path, geteuid()) < 0);
  assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
  lock = wd_lock(lock_path, geteuid()); assert(lock >= 0);
  struct stat same; assert(!fstat(lock, &same) && same.st_ino == identity.st_ino && same.st_dev == identity.st_dev); close(lock);
  /* The real probe executable rejects missing private FD setup before probing. */
  posix_spawn_file_actions_t actions; assert(!posix_spawn_file_actions_init(&actions));
  assert(!posix_spawn_file_actions_addclosefrom_np(&actions, 3));
  char *args[] = { probe_path, NULL };
  assert(!posix_spawn(&child, probe_path, &actions, NULL, args, environ)); posix_spawn_file_actions_destroy(&actions);
  assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) != 0);
  struct stat first, second;
  assert(!wd_write_file(state_path, "{\"schema\":1}\n", 0600, geteuid(), &first));
  assert((first.st_mode & 0777) == 0600);
  assert(!wd_write_file(state_path, "{\"schema\":1,\"sequence\":2}\n", 0600, geteuid(), &second));
  wd_remove_file(state_path, &first, geteuid()); assert(!access(state_path, F_OK));
  assert(!symlink(state_path, alias)); struct stat unused;
  assert(wd_write_file(alias, "bad", 0600, geteuid(), &unused) < 0); unlink(alias);
  assert(!chmod(directory, 0777)); assert(wd_lock(lock_path, geteuid()) < 0); chmod(directory, 0700);
  wd_remove_file(state_path, &second, geteuid()); assert(access(state_path, F_OK) < 0);
  struct wd_output output = {0}; pthread_mutex_init(&output.mutex, NULL); pthread_cond_init(&output.condition, NULL);
  struct wd_model model = {0};
  for (unsigned i = 1; i <= 100; i++) { model.sequence = i; wd_output_submit(&output, &model); }
  assert(output.ready && output.model.sequence == 100 && atomic_load(&output.drops) == 99);
  unlink(lock_path); rmdir(directory);
  puts("exec/parent-death lock, atomic-file and bounded-output tests passed; no netlink"); return 0;
}
