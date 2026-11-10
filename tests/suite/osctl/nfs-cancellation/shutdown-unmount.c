/* Assert a partial callback result or race shutdown with final NFS unmount. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/nsfs.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void fail(const char *operation)
{
  perror(operation);
  exit(EXIT_FAILURE);
}

static int expect_eagain(const char *path)
{
  ssize_t ret;
  int fd, write_errno;

  fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0)
    fail("open shutdown");
  ret = pwrite(fd, "1\n", 2, 0);
  write_errno = errno;
  if (close(fd))
    fail("close shutdown");

  if (ret == -1 && write_errno == EAGAIN) {
    printf("partial_callback=eagain\n");
    return EXIT_SUCCESS;
  }
  if (ret == -1) {
    errno = write_errno;
    fail("write shutdown");
  }
  if (ret == 2)
    fprintf(stderr, "shutdown write unexpectedly succeeded\n");
  else
    fprintf(stderr, "short shutdown write: %zd\n", ret);
  return EXIT_FAILURE;
}

int main(int argc, char **argv)
{
  char path[128], ready;
  int fd, proc, user_ns, ns, owner_user_ns, expected_root, reopened_root;
  int status, events[2], error = 0;
  struct stat user_ns_stat, owner_user_ns_stat;
  struct stat expected_root_stat, reopened_root_stat;
  unsigned long writes = 0;
  pid_t writer;

  if (argc == 3 && strcmp(argv[1], "--expect-eagain") == 0)
    return expect_eagain(argv[2]);
  if (argc != 4) {
    fprintf(stderr,
            "usage: %s shutdown-file init-pid mountpoint\n"
            "       %s --expect-eagain shutdown-file\n",
            argv[0], argv[0]);
    return EXIT_FAILURE;
  }

  fd = open(argv[1], O_WRONLY | O_CLOEXEC);
  if (fd < 0)
    fail("open shutdown");
  snprintf(path, sizeof(path), "/proc/%s", argv[2]);
  proc = open(path, O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (proc < 0)
    fail("open init proc directory");
  user_ns = openat(proc, "ns/user", O_RDONLY | O_CLOEXEC);
  if (user_ns < 0)
    fail("open user namespace");
  ns = openat(proc, "ns/mnt", O_RDONLY | O_CLOEXEC);
  if (ns < 0)
    fail("open mount namespace");
  expected_root = openat(proc, "root", O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (expected_root < 0)
    fail("open expected container root");
  if (fstat(expected_root, &expected_root_stat))
    fail("stat expected container root");
  owner_user_ns = ioctl(ns, NS_GET_USERNS);
  if (owner_user_ns < 0)
    fail("get mount namespace owner");
  if (fstat(owner_user_ns, &owner_user_ns_stat))
    fail("stat mount namespace owner");
  if (fstat(user_ns, &user_ns_stat))
    fail("stat target user namespace");
  if (owner_user_ns_stat.st_dev != user_ns_stat.st_dev ||
      owner_user_ns_stat.st_ino != user_ns_stat.st_ino) {
    errno = EXDEV;
    fail("authenticate mount namespace owner");
  }
  if (close(owner_user_ns))
    fail("close mount namespace owner");
  if (setns(user_ns, CLONE_NEWUSER))
    fail("enter container user namespace");
  if (setresgid(0, 0, 0))
    fail("select container root group");
  if (setresuid(0, 0, 0))
    fail("select container root user");
  if (close(user_ns))
    fail("close user namespace");
  if (setns(ns, CLONE_NEWNS))
    fail("enter container mount namespace");
  reopened_root = openat(proc, "root", O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (reopened_root < 0)
    fail("reopen container root");
  if (fstat(reopened_root, &reopened_root_stat))
    fail("stat reopened container root");
  if (expected_root_stat.st_dev != reopened_root_stat.st_dev ||
      expected_root_stat.st_ino != reopened_root_stat.st_ino) {
    errno = EXDEV;
    fail("authenticate reopened container root");
  }
  if (close(expected_root))
    fail("close expected container root");
  if (close(proc))
    fail("close init proc directory");
  if (fchdir(reopened_root) || chroot(".") || chdir("/"))
    fail("enter container root");
  if (close(reopened_root))
    fail("close reopened container root");
  if (unshare(CLONE_NEWNS))
    fail("clone container mount namespace");
  if (mount(NULL, "/", NULL, MS_REC | MS_SLAVE, NULL))
    fail("make cloned mount namespace slave");
  /* Drop the cloned mount before changing the original container namespace. */
  if (umount2(argv[3], 0))
    fail("drop cloned mount");
  if (pipe(events))
    fail("pipe");

  writer = fork();
  if (writer < 0)
    fail("fork");
  if (!writer) {
    close(events[0]);
    close(ns);
    for (;;) {
      ssize_t ret = pwrite(fd, "1\n", 2, 0);

      if (ret == 2) {
        /* The parent cannot begin teardown before a real callback succeeds. */
        if (!writes && write(events[1], "r", 1) != 1)
          fail("signal admitted callback");
        writes++;
      } else if (ret < 0 && errno == ENODEV) {
        break;
      } else if (ret < 0 && errno == EINTR) {
        continue;
      } else {
        fail("write shutdown");
      }
    }
    if (write(events[1], &writes, sizeof(writes)) != sizeof(writes))
      fail("report writes");
    close(fd);
    return EXIT_SUCCESS;
  }

  close(events[1]);
  if (read(events[0], &ready, 1) != 1 || ready != 'r') {
    fprintf(stderr, "writer did not complete an admitted callback\n");
    error = 1;
  } else if (setns(ns, CLONE_NEWNS)) {
    perror("re-enter original container mount namespace");
    error = 1;
  } else if (umount2(argv[3], 0)) {
    perror("final unmount");
    error = 1;
  }

  if (error) {
    if (kill(writer, SIGKILL) && errno != ESRCH)
      fail("stop writer");
  } else if (read(events[0], &writes, sizeof(writes)) != sizeof(writes)) {
    fprintf(stderr, "writer did not observe sysfs removal\n");
    error = 1;
  }
  if (waitpid(writer, &status, 0) != writer)
    fail("wait writer");
  if (!error && (!WIFEXITED(status) || WEXITSTATUS(status) || !writes))
    error = 1;
  printf("shutdown_writes=%lu unmounted=%d\n", writes, !error);
  close(events[0]);
  close(fd);
  close(ns);
  return error ? EXIT_FAILURE : EXIT_SUCCESS;
}
