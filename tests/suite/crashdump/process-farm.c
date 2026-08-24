#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;

static void stop(int signal_number) {
  (void)signal_number;
  stopping = 1;
}

static int write_ready(const char *path, long count) {
  char value[64];
  int fd;
  int length;

  fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd == -1)
    return -1;

  length = snprintf(value, sizeof(value), "%ld\n", count);
  if (length < 0 || (size_t)length >= sizeof(value) ||
      write(fd, value, (size_t)length) != length || close(fd) == -1)
    return -1;

  return 0;
}

int main(int argc, char **argv) {
  struct sigaction action = {.sa_handler = stop};
  char *end;
  long count;
  long started = 0;
  pid_t *children;

  if (argc != 3) {
    fprintf(stderr, "Usage: %s COUNT READY_FILE\n", argv[0]);
    return EXIT_FAILURE;
  }

  errno = 0;
  count = strtol(argv[1], &end, 10);
  if (errno != 0 || *end != '\0' || count < 1 || count > 100000) {
    fprintf(stderr, "Invalid process count: %s\n", argv[1]);
    return EXIT_FAILURE;
  }

  children = calloc((size_t)count, sizeof(*children));
  if (children == NULL) {
    perror("calloc");
    return EXIT_FAILURE;
  }

  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGTERM, &action, NULL);

  for (started = 0; started < count; started++) {
    pid_t child = fork();

    if (child == -1) {
      perror("fork");
      stopping = 1;
      break;
    }

    if (child == 0) {
      prctl(PR_SET_NAME, "crash-load", 0, 0, 0);
      for (;;)
        pause();
    }

    children[started] = child;
  }

  if (!stopping && write_ready(argv[2], started) == -1) {
    perror(argv[2]);
    stopping = 1;
  }

  while (!stopping)
    pause();

  for (long i = 0; i < started; i++)
    kill(children[i], SIGTERM);

  for (long i = 0; i < started; i++)
    while (waitpid(children[i], NULL, 0) == -1 && errno == EINTR)
      ;

  free(children);
  return started == count ? EXIT_SUCCESS : EXIT_FAILURE;
}
