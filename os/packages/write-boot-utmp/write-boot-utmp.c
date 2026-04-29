#define _GNU_SOURCE

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <utmpx.h>

static void set_field(char *dst, size_t size, const char *value)
{
  memset(dst, 0, size);

  if (value != NULL) {
    strncpy(dst, value, size);
  }
}

static int get_uptime(struct timeval *tv)
{
  FILE *f;
  double uptime;
  long sec;
  long usec;
  int ret;

  f = fopen("/proc/uptime", "r");
  if (f == NULL) {
    return -1;
  }

  ret = fscanf(f, "%lf", &uptime);
  fclose(f);

  if (ret != 1) {
    errno = EINVAL;
    return -1;
  }

  sec = (long)uptime;
  usec = (long)((uptime - sec) * 1000000.0 + 0.5);

  if (usec >= 1000000) {
    sec += 1;
    usec -= 1000000;
  }

  tv->tv_sec = sec;
  tv->tv_usec = usec;

  return 0;
}

static void subtract_timeval(struct timeval *tv, const struct timeval *delta)
{
  tv->tv_sec -= delta->tv_sec;
  tv->tv_usec -= delta->tv_usec;

  if (tv->tv_usec < 0) {
    tv->tv_sec -= 1;
    tv->tv_usec += 1000000;
  }
}

int main(int argc, char **argv)
{
  const char *path = "/run/utmp";
  struct timeval uptime;
  struct timeval tv;
  struct utsname uts;
  struct utmpx entry;

  if (argc > 2) {
    fprintf(stderr, "Usage: %s [utmp-file]\n", argv[0]);
    return EXIT_FAILURE;
  }

  if (argc == 2) {
    path = argv[1];
  }

  if (utmpxname(path) != 0) {
    perror("utmpxname");
    return EXIT_FAILURE;
  }

  if (get_uptime(&uptime) != 0) {
    perror("get_uptime");
    return EXIT_FAILURE;
  }

  if (gettimeofday(&tv, NULL) != 0) {
    perror("gettimeofday");
    return EXIT_FAILURE;
  }

  subtract_timeval(&tv, &uptime);

  memset(&entry, 0, sizeof(entry));
  entry.ut_type = BOOT_TIME;
  entry.ut_pid = 0;
  entry.ut_tv.tv_sec = tv.tv_sec;
  entry.ut_tv.tv_usec = tv.tv_usec;

  set_field(entry.ut_id, sizeof(entry.ut_id), "~~");
  set_field(entry.ut_user, sizeof(entry.ut_user), "reboot");
  set_field(entry.ut_line, sizeof(entry.ut_line), "~");

  if (uname(&uts) == 0) {
    set_field(entry.ut_host, sizeof(entry.ut_host), uts.release);
  }

  setutxent();

  errno = 0;
  if (pututxline(&entry) == NULL) {
    int saved_errno = errno;

    endutxent();
    errno = saved_errno;
    perror("pututxline");
    return EXIT_FAILURE;
  }

  endutxent();

  return EXIT_SUCCESS;
}
