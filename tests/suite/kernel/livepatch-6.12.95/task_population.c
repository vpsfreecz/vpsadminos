// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/futex.h>
#include <linux/perf_event.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* A workload inside the normal VM test, not a host qualification launcher.
 * Linux tasks include threads. Keep the requested population alive across
 * replacement, with one runnable thread pinned to each requested guest CPU.
 * Sleepers wake in bounded batches; the controller separately forks/execs.
 */
struct worker {
	pthread_t thread;
	int cpu;
	int perf_fd;
	atomic_ulong progress;
	atomic_int actual_cpu;
};

static atomic_int phase;
static atomic_int wake_sequence;
static atomic_uint ready;
static atomic_ulong wakeups;
static atomic_int worker_error;
static volatile sig_atomic_t interrupted;
static bool with_perf;

static double now(void)
{
	struct timespec ts;
	if (clock_gettime(CLOCK_MONOTONIC, &ts)) {
		perror("clock_gettime");
		exit(1);
	}
	return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}

static void stop_signal(int signo)
{
	(void)signo;
	interrupted = 1;
}

static void wake(atomic_int *word, int count)
{
	(void)syscall(SYS_futex, word, FUTEX_WAKE_PRIVATE, count, NULL, NULL, 0);
}

static void wait_value(atomic_int *word, int value)
{
	if (syscall(SYS_futex, word, FUTEX_WAIT_PRIVATE, value, NULL, NULL, 0) &&
	    errno != EAGAIN && errno != EINTR)
		atomic_store(&worker_error, errno);
}

static void *run_worker(void *arg)
{
	struct worker *worker = arg;
	unsigned long progress = 0;
	cpu_set_t mask;
	int ret;

	if (worker->cpu >= 0) {
		CPU_ZERO(&mask);
		CPU_SET(worker->cpu, &mask);
		ret = pthread_setaffinity_np(pthread_self(), sizeof(mask), &mask);
		if (ret)
			atomic_store(&worker_error, ret);
		atomic_store(&worker->actual_cpu, sched_getcpu());
		if (with_perf) {
			struct perf_event_attr attr = {
				.type = PERF_TYPE_SOFTWARE,
				.size = sizeof(attr),
				.config = PERF_COUNT_SW_CPU_CLOCK,
			};
			worker->perf_fd = syscall(SYS_perf_event_open, &attr,
						 0, -1, -1, PERF_FLAG_FD_CLOEXEC);
			if (worker->perf_fd < 0)
				atomic_store(&worker_error, errno);
		}
	}
	atomic_fetch_add(&ready, 1);
	while (atomic_load(&phase) == 0)
		wait_value(&phase, 0);

	while (atomic_load(&phase) == 1) {
		if (worker->cpu >= 0) {
			/* Enter/leave the kernel, while remaining runnable. */
			(void)syscall(SYS_gettid);
			if (++progress % 1024 == 0) {
				int cpu = sched_getcpu();
				/* Hot-unplug can move a pinned task. Restore its CPU
				 * when it returns; EINVAL is transient while offline.
				 */
				if (cpu != worker->cpu) {
					ret = pthread_setaffinity_np(pthread_self(),
							    sizeof(mask), &mask);
					if (ret && ret != EINVAL)
						atomic_store(&worker_error, ret);
					cpu = sched_getcpu();
				}
				atomic_store(&worker->actual_cpu, cpu);
				atomic_store(&worker->progress, progress);
			}
		} else {
			int seq = atomic_load(&wake_sequence);
			if (atomic_load(&phase) != 1)
				break;
			wait_value(&wake_sequence, seq);
			atomic_fetch_add(&wakeups, 1);
		}
	}
	return NULL;
}

static unsigned long status_value(const char *file, const char *key)
{
	char line[256], name[128];
	unsigned long value;
	FILE *f = fopen(file, "r");
	if (!f)
		return ULONG_MAX;
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "%127s %lu", name, &value) == 2 &&
		    !strcmp(name, key)) {
			fclose(f);
			return value;
		}
	}
	fclose(f);
	return ULONG_MAX;
}

static unsigned long number(const char *s, unsigned long max)
{
	char *end;
	unsigned long n;
	errno = 0;
	n = strtoul(s, &end, 10);
	if (errno || !*s || *end || n > max) {
		fprintf(stderr, "invalid numeric argument: %s\n", s);
		exit(2);
	}
	return n;
}

static int publish(int dir, struct worker *workers, unsigned int cpus,
		   unsigned long forks, double started, const char *state)
{
	unsigned int i;
	unsigned long tasks = status_value("/proc/self/status", "Threads:");
	unsigned long available = status_value("/proc/meminfo", "MemAvailable:");
	FILE *f;
	if (tasks == ULONG_MAX || available == ULONG_MAX) {
		errno = EIO;
		return -1;
	}
	int fd = openat(dir, "population.tmp", O_CREAT | O_TRUNC | O_WRONLY |
			O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0)
		return -1;
	f = fdopen(fd, "w");
	if (!f) {
		close(fd);
		return -1;
	}
	fprintf(f, "state=%s\npid=%ld\ntasks=%lu\nready=%u\ncpus=%u\n"
		"wakeups=%lu\nfork_exec=%lu\nelapsed=%.3f\nmem_available_kib=%lu\n",
		state, (long)getpid(), tasks,
		atomic_load(&ready), cpus, atomic_load(&wakeups), forks,
		now() - started, available);
	for (i = 0; i < cpus; i++) {
		fprintf(f, "cpu_%d_progress=%lu\n", workers[i].cpu,
			atomic_load(&workers[i].progress));
		fprintf(f, "cpu_%d_actual=%d\n", workers[i].cpu,
			atomic_load(&workers[i].actual_cpu));
		if (with_perf) {
			unsigned long long counter;
			if (workers[i].perf_fd < 0 ||
			    read(workers[i].perf_fd, &counter, sizeof(counter)) !=
			    sizeof(counter)) {
				if (strcmp(state, "running")) {
					fprintf(f, "cpu_%d_perf=unavailable\n", workers[i].cpu);
					continue;
				}
				fclose(f);
				errno = EIO;
				return -1;
			}
			fprintf(f, "cpu_%d_perf=%llu\n", workers[i].cpu, counter);
		}
	}
	if (fclose(f))
		return -1;
	return renameat(dir, "population.tmp", dir, "population");
}

int main(int argc, char **argv)
{
	unsigned int tasks, cpus, created = 0, i, found = 0;
	unsigned long duration, forks = 0;
	struct worker *workers;
	pthread_attr_t attr;
	cpu_set_t allowed;
	double started, deadline;
	int dir, ret = 0;
	const struct timespec pause = { .tv_sec = 0, .tv_nsec = 100000000 };
	struct sigaction action = { .sa_handler = stop_signal };

	if (argc == 2 && !strcmp(argv[1], "--exec-child"))
		return 0;
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc != 5 && argc != 6) {
		fprintf(stderr, "usage: %s TASKS CPUS MAX_SECONDS STATE_DIRECTORY [PERF:0|1]\n",
			argv[0]);
		return 2;
	}
	tasks = number(argv[1], 200000);
	cpus = number(argv[2], CPU_SETSIZE);
	duration = number(argv[3], 21600);
	with_perf = argc == 6 && number(argv[5], 1);
	if (!cpus || tasks <= cpus + 1 || !duration)
		return 2;
	dir = open(argv[4], O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (dir < 0 || sched_getaffinity(0, sizeof(allowed), &allowed)) {
		perror("population admission");
		return 1;
	}
	if ((unsigned int)CPU_COUNT(&allowed) < cpus) {
		fprintf(stderr, "requested %u CPUs, affinity allows %d\n",
			cpus, CPU_COUNT(&allowed));
		close(dir);
		return 1;
	}
	workers = calloc(tasks - 1, sizeof(*workers));
	if (!workers) {
		perror("calloc workers");
		close(dir);
		return 1;
	}
	for (i = 0; i < CPU_SETSIZE && found < cpus; i++)
		if (CPU_ISSET(i, &allowed))
			workers[found++].cpu = i;
	for (i = cpus; i < tasks - 1; i++)
		workers[i].cpu = -1;
	for (i = 0; i < tasks - 1; i++) {
		atomic_init(&workers[i].progress, 0);
		atomic_init(&workers[i].actual_cpu, -1);
		workers[i].perf_fd = -1;
	}
	sigemptyset(&action.sa_mask);
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGINT, &action, NULL);
	ret = pthread_attr_init(&attr);
	if (ret) {
		fprintf(stderr, "pthread_attr_init: %s\n", strerror(ret));
		free(workers);
		close(dir);
		return 1;
	}
	ret = pthread_attr_setstacksize(&attr, 65536);
	if (ret) {
		fprintf(stderr, "pthread_attr_setstacksize: %s\n", strerror(ret));
		goto out;
	}
	started = now();
	deadline = started + duration;
	for (created = 0; created < tasks - 1; created++) {
		ret = pthread_create(&workers[created].thread, &attr,
				     run_worker, &workers[created]);
		if (ret) {
			fprintf(stderr, "pthread_create %u/%u: %s\n", created,
				tasks - 1, strerror(ret));
			break;
		}
		if (interrupted || now() >= deadline) {
			created++;
			ret = ETIMEDOUT;
			break;
		}
		ret = atomic_load(&worker_error);
		if (ret) {
			created++;
			break;
		}
		if ((created + 1) % 10000 == 0)
			printf("population startup created=%u requested=%u\n",
			       created + 1, tasks - 1);
	}
	while (!ret && atomic_load(&ready) < created) {
		if (interrupted || now() >= deadline)
			ret = ETIMEDOUT;
		nanosleep(&pause, NULL);
	}
	if (!ret)
		ret = atomic_load(&worker_error);
	if (ret)
		goto stop;
	atomic_store(&phase, 1);
	wake(&phase, INT_MAX);
	while (!interrupted && faccessat(dir, "stop", F_OK, 0)) {
		pid_t child;
		int status;
		if (now() >= deadline || atomic_load(&worker_error)) {
			ret = ETIMEDOUT;
			break;
		}
		child = fork();
		if (child == 0) {
			execl("/proc/self/exe", argv[0], "--exec-child", NULL);
			_exit(127);
		}
		if (child < 0) {
			ret = errno;
			break;
		}
		while (waitpid(child, &status, 0) < 0) {
			if (errno == EINTR)
				continue;
			ret = errno;
			break;
		}
		if (ret || !WIFEXITED(status) || WEXITSTATUS(status)) {
			ret = ret ? ret : ECHILD;
			break;
		}
		forks++;
		atomic_fetch_add(&wake_sequence, 1);
		wake(&wake_sequence, 64);
		if (publish(dir, workers, cpus, forks, started, "running")) {
			ret = errno ? errno : EIO;
			break;
		}
		nanosleep(&pause, NULL);
	}
	if (interrupted)
		ret = EINTR;
stop:
	atomic_store(&phase, 2);
	wake(&phase, INT_MAX);
	atomic_fetch_add(&wake_sequence, 1);
	wake(&wake_sequence, INT_MAX);
	for (i = 0; i < created; i++) {
		int joined = pthread_join(workers[i].thread, NULL);
		if (joined) {
			fprintf(stderr, "pthread_join %u: %s\n", i, strerror(joined));
			/* Never free an array that an unjoined worker might use. */
			_exit(1);
		}
	}
	if (publish(dir, workers, cpus, forks, started, ret ? "failed" : "stopped"))
		ret = ret ? ret : EIO;
	if (ret)
		fprintf(stderr, "population failed: %s\n", strerror(ret));
out:
	pthread_attr_destroy(&attr);
	for (i = 0; i < cpus; i++)
		if (workers[i].perf_fd >= 0)
			close(workers[i].perf_fd);
	free(workers);
	close(dir);
	return ret ? 1 : 0;
}
