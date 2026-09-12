#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void phase(const char *name, size_t progress)
{
  struct timespec wall, cpu;

  if (clock_gettime(CLOCK_MONOTONIC, &wall) < 0 ||
      clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu) < 0)
    exit(1);
  fprintf(stderr, "probe_phase=%s pid=%ld progress=%zu monotonic=%ld.%09ld cpu=%ld.%09ld\n",
          name, (long)getpid(), progress, (long)wall.tv_sec, wall.tv_nsec,
          (long)cpu.tv_sec, cpu.tv_nsec);
  fflush(stderr);
}

/* Bounded workloads, not measurements of VM scheduling performance. */
static int cpu_probe(void)
{
  struct timespec start, now;
  volatile unsigned long value = 1;

  if (clock_gettime(CLOCK_MONOTONIC, &start) < 0)
    return 1;

  do {
    for (unsigned int i = 0; i < 10000; i++)
      value = value * 1664525 + 1013904223;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
      return 1;
  } while (now.tv_sec - start.tv_sec < 5);

  return 0;
}

static int pids_probe(void)
{
  pid_t children[128];
  size_t count = 0;
  int fork_error = 0;

  while (count < sizeof(children) / sizeof(children[0])) {
    pid_t parent = getpid();
    pid_t child = fork();

    if (child < 0) {
      fork_error = errno;
      break;
    }
    if (child == 0) {
      if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != parent)
        _exit(1);
      for (;;)
        pause();
    }
    children[count++] = child;
  }

  for (size_t i = 0; i < count; i++)
    kill(children[i], SIGKILL);
  for (size_t i = 0; i < count; i++) {
    while (waitpid(children[i], NULL, 0) < 0) {
      if (errno != EINTR)
        return 1;
    }
  }

  printf("children=%zu fork_errno=%d\n", count, fork_error);
  return count > 0 && fork_error == EAGAIN ? 0 : 1;
}

static int memory_probe(void)
{
  pid_t parent = getpid();
  pid_t child = fork();
  int status;

  if (child < 0)
    return 1;
  if (child == 0) {
    const size_t size = 256UL * 1024 * 1024;
    FILE *score;
    volatile unsigned char *memory;

    if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != parent)
      _exit(1);
    /* Sacrifice only this disposable child, not the container's init. */
    score = fopen("/proc/self/oom_score_adj", "w");
    if (score == NULL || fprintf(score, "1000\n") < 0 || fclose(score) != 0)
      _exit(1);
    memory = mmap(NULL, size, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED)
      _exit(1);
    phase("memory-mapped", 0);
    for (size_t i = 0; i < size; i += 4096) {
      memory[i] = 1;
      if (i % (32UL * 1024 * 1024) == 0)
        phase("memory-touch", i);
    }
    _exit(2); /* Reaching 256 MiB violates the test's 128 MiB limit. */
  }

  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR)
      return 1;
  }
  printf("memory_child_status=%d\n", status);
  return WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL ? 0 : 1;
}

int main(int argc, char **argv)
{
  int ret;

  if (argc != 2)
    return 2;
  phase(argv[1], 0);
  alarm(30);
  if (strcmp(argv[1], "cpu") == 0)
    ret = cpu_probe();
  else if (strcmp(argv[1], "pids") == 0)
    ret = pids_probe();
  else if (strcmp(argv[1], "memory") == 0)
    ret = memory_probe();
  else
    return 2;
  phase("complete", 0);
  return ret;
}
