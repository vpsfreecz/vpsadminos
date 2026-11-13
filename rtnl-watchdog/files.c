/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "watchdog.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>
static int parent(const char *path, char *name, uid_t owner)
{
  char directory[PATH_MAX]; size_t len = strlen(path);
  if (!len || len >= sizeof(directory) || path[0] != '/') { errno = EINVAL; return -1; }
  strcpy(directory, path); char *slash = strrchr(directory, '/');
  if (!slash[1] || !strcmp(slash + 1, ".") || !strcmp(slash + 1, "..")) { errno = EINVAL; return -1; }
  strcpy(name, slash + 1);
  if (slash == directory) slash[1] = 0; else *slash = 0;
  int fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat st;
  if (fd < 0) return -1;
  if (fstat(fd, &st) || st.st_uid != owner || st.st_mode & 022) { close(fd); errno = EACCES; return -1; }
  return fd;
}
int wd_lock(const char *path, uid_t owner)
{
  char name[PATH_MAX]; int directory = parent(path, name, owner);
  if (directory < 0) return -1;
  int fd = openat(directory, name, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600); close(directory);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != owner ||
      (st.st_mode & 0777) != 0600 || st.st_nlink != 1) { close(fd); errno = EACCES; return -1; }
  if (flock(fd, LOCK_EX | LOCK_NB)) { int saved = errno; close(fd); errno = saved; return -1; }
  return fd; /* Never unlock/unlink: the helper inherits this description. */
}
int wd_write_file(const char *path, const char *data, mode_t mode, uid_t owner, struct stat *identity)
{
  char name[PATH_MAX], temporary[PATH_MAX];
  int directory = parent(path, name, owner); if (directory < 0) return -1;
  struct stat old;
  int exists = fstatat(directory, name, &old, AT_SYMLINK_NOFOLLOW);
  if ((!exists && (!S_ISREG(old.st_mode) || old.st_uid != owner || old.st_nlink != 1 || (old.st_mode & 0777) != mode)) ||
      (exists && errno != ENOENT)) { close(directory); errno = EACCES; return -1; }
  int length = snprintf(temporary, sizeof(temporary), ".%s.tmp.%ld", name, (long)getpid());
  if (length < 0 || (size_t)length >= sizeof(temporary)) { close(directory); errno = ENAMETOOLONG; return -1; }
  int fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) { close(directory); return -1; }
  size_t size = strlen(data), sent = 0; bool ok = true;
  while (sent < size) {
    ssize_t n = write(fd, data + sent, size - sent);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { ok = false; break; }
    sent += n;
  }
  struct stat st;
  if (fchmod(fd, mode) || fstat(fd, &st)) ok = false;
  if (close(fd)) ok = false;
  if (ok && !renameat(directory, temporary, directory, name)) { *identity = st; close(directory); return 0; }
  unlinkat(directory, temporary, 0); close(directory); return -1;
}
void wd_remove_file(const char *path, const struct stat *identity, uid_t owner)
{
  if (!identity->st_ino) return;
  char name[PATH_MAX]; int directory = parent(path, name, owner);
  if (directory < 0) return;
  struct stat st;
  if (!fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) && st.st_dev == identity->st_dev && st.st_ino == identity->st_ino)
    unlinkat(directory, name, 0);
  close(directory);
}
