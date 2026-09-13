#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Read the probe's own v1 leaf while it still exists. Newer helpers use a
 * short-lived osctl.attach child; its local events do not reach the init leaf. */
static FILE *open_local_event(const char *controller, const char *parameter)
{
  FILE *groups = fopen("/proc/self/cgroup", "r");
  char *line = NULL;
  size_t capacity = 0;
  FILE *event = NULL;

  if (!groups)
    exit(1);
  while (getline(&line, &capacity, groups) >= 0) {
    char *first = strchr(line, ':');
    char *second = first ? strchr(first + 1, ':') : NULL;
    char path[PATH_MAX];

    if (!second)
      exit(1);
    *second = '\0';
    if (strcmp(first + 1, controller) != 0)
      continue;
    second++;
    second[strcspn(second, "\n")] = '\0';
    if (snprintf(path, sizeof(path), "/sys/fs/cgroup/%s%s/%s",
                 controller, second, parameter) >= (int)sizeof(path))
      exit(1);
    event = fopen(path, "r");
    if (!event) {
      perror(path);
      exit(1);
    }
    fprintf(stderr, "probe_event_path=%s\n", path);
    break;
  }
  free(line);
  fclose(groups);
  return event; /* No separate controller means the host uses cgroup v2. */
}

static unsigned long long event_value(FILE *event, const char *key)
{
  char *line = NULL;
  size_t capacity = 0;
  unsigned long long value;
  char name[128];

  rewind(event);
  while (getline(&line, &capacity, event) >= 0) {
    if (sscanf(line, "%127s %llu", name, &value) == 2 &&
        strcmp(name, key) == 0) {
      free(line);
      return value;
    }
  }
  free(line);
  fprintf(stderr, "event counter missing: %s\n", key);
  exit(1);
}

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
  FILE *event = NULL;
  const char *key = NULL;
  unsigned long long before = 0;

  if (argc != 2)
    return 2;
  phase(argv[1], 0);
  alarm(30);
  if (strcmp(argv[1], "pids") == 0) {
    event = open_local_event("pids", "pids.events");
    key = "max";
  } else if (strcmp(argv[1], "memory") == 0) {
    event = open_local_event("memory", "memory.oom_control");
    key = "oom_kill";
  }
  if (event)
    before = event_value(event, key);
  if (strcmp(argv[1], "cpu") == 0)
    ret = cpu_probe();
  else if (strcmp(argv[1], "pids") == 0)
    ret = pids_probe();
  else if (strcmp(argv[1], "memory") == 0)
    ret = memory_probe();
  else
    return 2;
  if (event) {
    unsigned long long after = event_value(event, key);

    fprintf(stderr, "probe_event=%s before=%llu after=%llu\n", key, before, after);
    fclose(event);
    if (after <= before)
      ret = 1;
  }
  phase("complete", 0);
  return ret;
}
