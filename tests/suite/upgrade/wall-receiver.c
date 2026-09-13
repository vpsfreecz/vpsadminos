#define _XOPEN_SOURCE 700
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Linux's 384-byte utmp ABI, also read by OsCtld::UtmpReader. The fixture
 * registers its real guest PTY, not a host file or a substitute wall command. */
struct login_record {
  int16_t type, padding;
  int32_t pid;
  char line[32], id[4], user[32], host[256];
  int16_t termination, exit;
  int32_t session, seconds, useconds, address[4];
  char unused[20];
};
_Static_assert(sizeof(struct login_record) == 384, "Linux utmp record size");

static void fail(const char *operation)
{
  perror(operation);
  exit(1);
}

static void write_file(const char *path, const char *contents)
{
  FILE *file = fopen(path, "w");
  if (!file || fputs(contents, file) == EOF || fclose(file) != 0)
    fail(path);
}

int main(int argc, char **argv)
{
  if (argc != 5) {
    fprintf(stderr, "usage: wall-receiver MESSAGE READY OUTPUT STATUS\n");
    return 2;
  }
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0)
    fail("allocate guest PTY");
  char *tty = ptsname(master);
  if (!tty || strncmp(tty, "/dev/", 5) != 0)
    fail("guest PTY name");
  int slave = open(tty, O_RDWR | O_NOCTTY);
  int utmp = open("/run/utmp", O_RDWR | O_CREAT, 0644);
  if (slave < 0 || utmp < 0 || flock(utmp, LOCK_EX) != 0)
    fail("open guest recipient");
  struct stat st;
  if (fstat(utmp, &st) != 0)
    fail("stat guest utmp");
  if (st.st_size % sizeof(struct login_record) != 0 ||
      st.st_size / sizeof(struct login_record) >= 32) {
    fprintf(stderr, "fixture utmp outside wall's 32-entry reader bound\n");
    return 1;
  }
  struct login_record record = {0};
  record.type = 7; /* USER_PROCESS */
  record.pid = (int32_t)getpid();
  record.seconds = (int32_t)time(NULL);
  snprintf(record.line, sizeof(record.line), "%s", tty + 5);
  memcpy(record.id, "uwal", 4);
  memcpy(record.user, "root", 4);
  if (pwrite(utmp, &record, sizeof(record), st.st_size) != sizeof(record) ||
      flock(utmp, LOCK_UN) != 0)
    fail("register guest recipient");
  char pid[32];
  snprintf(pid, sizeof(pid), "%ld\n", (long)getpid());
  write_file(argv[2], pid);
  char received[8192] = {0};
  size_t used = 0;
  time_t deadline = time(NULL) + 900;
  int result = 1;
  while (time(NULL) < deadline && used < sizeof(received) - 1) {
    struct pollfd ready = {.fd = master, .events = POLLIN};
    int polled = poll(&ready, 1, 1000);
    if (polled < 0 && errno == EINTR)
      continue;
    if (polled < 0)
      fail("poll guest PTY");
    if (polled == 0)
      continue;
    ssize_t count = read(master, received + used, sizeof(received) - used - 1);
    if (count < 0 && errno == EINTR)
      continue;
    if (count <= 0)
      break;
    used += (size_t)count;
    received[used] = '\0';
    if (strstr(received, argv[1])) {
      result = 0;
      break;
    }
  }
  write_file(argv[3], received);
  record.type = 8; /* DEAD_PROCESS: retire only our appended record. */
  if (flock(utmp, LOCK_EX) != 0 ||
      pwrite(utmp, &record, sizeof(record), st.st_size) != sizeof(record) ||
      flock(utmp, LOCK_UN) != 0)
    fail("retire guest recipient");
  close(utmp);
  close(slave);
  close(master);
  write_file(argv[4], result == 0 ? "delivered\n" : "not-delivered\n");
  return result;
}
