#include <fcntl.h>
#include <limits.h>
#include <linux/close_range.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static pthread_barrier_t files_barrier;

static void *files_waiter(void *unused)
{
  (void)unused;
  (void)pthread_barrier_wait(&files_barrier);
  (void)pthread_barrier_wait(&files_barrier);
  return NULL;
}

static int run_files_unshare(void)
{
  pthread_t thread;
  int rc;
  int ret = 0;

  rc = pthread_barrier_init(&files_barrier, NULL, 2);
  if (rc) {
    fprintf(stderr, "pthread_barrier_init: %s\n", strerror(rc));
    return 1;
  }

  rc = pthread_create(&thread, NULL, files_waiter, NULL);
  if (rc) {
    fprintf(stderr, "pthread_create: %s\n", strerror(rc));
    pthread_barrier_destroy(&files_barrier);
    return 1;
  }

  (void)pthread_barrier_wait(&files_barrier);
  if (syscall(SYS_close_range, 3U, UINT_MAX, CLOSE_RANGE_UNSHARE) < 0) {
    perror("close_range(CLOSE_RANGE_UNSHARE)");
    ret = 1;
  }
  (void)pthread_barrier_wait(&files_barrier);

  rc = pthread_join(thread, NULL);
  if (rc) {
    fprintf(stderr, "pthread_join: %s\n", strerror(rc));
    ret = 1;
  }
  pthread_barrier_destroy(&files_barrier);
  return ret;
}

int main(int argc, char **argv)
{
  struct sock_filter filter[] = {
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog prog = {
    .len = sizeof(filter) / sizeof(filter[0]),
    .filter = filter,
  };
  const char *target;
  int fd;

  if (argc != 2) {
    fprintf(stderr, "usage: %s TARGET\n", argv[0]);
    return 1;
  }
  target = argv[1];

  if (!strcmp(target, "files_unshare"))
    return run_files_unshare();

  if (strcmp(target, "seccomp_filter") &&
      strcmp(target, "seccomp_filter_count") &&
      strcmp(target, "seccomp_smoke")) {
    fprintf(stderr, "unsupported target: %s\n", target);
    return 1;
  }

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) {
    perror("prctl(PR_SET_NO_NEW_PRIVS)");
    return 1;
  }

  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) < 0) {
    perror("prctl(PR_SET_SECCOMP)");
    return 1;
  }

  if (!strcmp(target, "seccomp_smoke"))
    return 0;

  fd = open("/sys/kernel/debug/auth_guard/corrupt_current", O_WRONLY);
  if (fd < 0) {
    perror("open(corrupt_current)");
    return 1;
  }

  if (dprintf(fd, "%s\n", target) < 0) {
    perror("write(corrupt_current)");
    close(fd);
    return 1;
  }

  close(fd);
  return 0;
}
