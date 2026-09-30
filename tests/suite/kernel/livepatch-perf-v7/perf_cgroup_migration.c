// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Exercise cgroup-filtered counters, not merely counters attached to tasks.
 * The parent stays outside both groups; its one child owns exactly TASKS
 * continuously runnable, pinned threads and moves A -> B -> A as a unit.
 */
struct shared {
	atomic_uint ready;
	atomic_int error;
	atomic_bool stop;
};

struct worker {
	struct shared *shared;
	int cpu;
};

static double now(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts)) {
		perror("clock_gettime");
		exit(1);
	}
	return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}

static int move_child(int group, pid_t pid)
{
	char text[32];
	int fd = openat(group, "cgroup.procs", O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
	int len = snprintf(text, sizeof(text), "%ld", (long)pid);
	int ret = 0;

	if (fd < 0)
		return -1;
	if (write(fd, text, len) != len)
		ret = -1;
	if (close(fd))
		ret = -1;
	return ret;
}

static void *worker_main(void *arg)
{
	struct worker *worker = arg;
	cpu_set_t mask;
	int ret;

	CPU_ZERO(&mask);
	CPU_SET(worker->cpu, &mask);
	ret = pthread_setaffinity_np(pthread_self(), sizeof(mask), &mask);
	if (ret)
		atomic_store(&worker->shared->error, ret);
	atomic_fetch_add(&worker->shared->ready, 1);
	while (!atomic_load(&worker->shared->stop))
		(void)syscall(SYS_gettid);
	return NULL;
}

static void child_main(struct shared *shared, int group, unsigned int tasks,
		       const int *cpus, unsigned int nr_cpus, pid_t parent)
{
	struct worker *workers = calloc(tasks, sizeof(*workers));
	pthread_t *threads = calloc(tasks, sizeof(*threads));
	unsigned int i;

	if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent ||
	    !workers || !threads || move_child(group, getpid()))
		_exit(1);
	for (i = 0; i < tasks; i++) {
		workers[i].shared = shared;
		workers[i].cpu = cpus[i % nr_cpus];
		if (i && pthread_create(&threads[i], NULL, worker_main, &workers[i]))
			_exit(1);
	}
	worker_main(&workers[0]);
	for (i = 1; i < tasks; i++)
		if (pthread_join(threads[i], NULL))
			_exit(1);
	free(threads);
	free(workers);
	_exit(atomic_load(&shared->error) ? 1 : 0);
}

static int read_counters(int (*fds)[2], unsigned int nr_cpus,
			unsigned long long (*values)[2])
{
	unsigned int cpu, group;

	for (cpu = 0; cpu < nr_cpus; cpu++) {
		for (group = 0; group < 2; group++) {
			if (read(fds[cpu][group], &values[cpu][group],
				 sizeof(values[cpu][group])) != sizeof(values[cpu][group])) {
				fprintf(stderr, "read cgroup counter cpu=%u group=%u\n", cpu, group);
				return -1;
			}
		}
	}
	return 0;
}

static int check_group(int (*fds)[2], const int *cpus, unsigned int nr_cpus,
		       unsigned int tasks, unsigned int active)
{
	unsigned long long before[CPU_SETSIZE][2], after[CPU_SETSIZE][2];
	unsigned int cpu, inactive = 1 - active;

	if (read_counters(fds, nr_cpus, before))
		return -1;
	usleep(200000);
	if (read_counters(fds, nr_cpus, after))
		return -1;
	for (cpu = 0; cpu < nr_cpus; cpu++) {
		bool used = cpu < tasks;

		if (after[cpu][inactive] != before[cpu][inactive] ||
		    (used && after[cpu][active] <= before[cpu][active]) ||
		    (!used && after[cpu][active] != before[cpu][active])) {
			fprintf(stderr, "cgroup accounting mismatch cpu=%d active=%u used=%d "
				"before=%llu,%llu after=%llu,%llu\n", cpus[cpu], active, used,
				before[cpu][0], before[cpu][1], after[cpu][0], after[cpu][1]);
			return -1;
		}
		printf("cgroup phase=%c cpu=%d used=%d active_delta=%llu inactive_delta=0\n",
		       'a' + active, cpus[cpu], used, after[cpu][active] - before[cpu][active]);
	}
	return 0;
}

int main(int argc, char **argv)
{
	struct shared *shared = MAP_FAILED;
	int cpus[CPU_SETSIZE], (*fds)[2] = NULL, groups[2] = { -1, -1 };
	unsigned int nr_cpus = 0, cpu, group, tasks;
	cpu_set_t allowed;
	pid_t child = -1, parent = getpid();
	char *end;
	unsigned long parsed;
	double deadline;
	int ret = 1, status;

	if (argc != 4) {
		fprintf(stderr, "usage: %s CGROUP_A CGROUP_B TASKS\n", argv[0]);
		return 2;
	}
	errno = 0;
	parsed = strtoul(argv[3], &end, 10);
	if (errno || !*argv[3] || *end || !parsed || parsed > 4096)
		return 2;
	tasks = parsed;
	if (sched_getaffinity(0, sizeof(allowed), &allowed))
		goto out;
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++)
		if (CPU_ISSET(cpu, &allowed))
			cpus[nr_cpus++] = cpu;
	if (!nr_cpus)
		goto out;
	fds = malloc(nr_cpus * sizeof(*fds));
	if (!fds)
		goto out;
	for (cpu = 0; cpu < nr_cpus; cpu++)
		fds[cpu][0] = fds[cpu][1] = -1;
	for (group = 0; group < 2; group++) {
		groups[group] = open(argv[group + 1], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
		if (groups[group] < 0)
			goto out;
		for (cpu = 0; cpu < nr_cpus; cpu++) {
			struct perf_event_attr attr = {
				.type = PERF_TYPE_SOFTWARE,
				.size = sizeof(attr),
				.config = PERF_COUNT_SW_CPU_CLOCK,
			};

			fds[cpu][group] = syscall(SYS_perf_event_open, &attr, groups[group],
						 cpus[cpu], -1, PERF_FLAG_PID_CGROUP | PERF_FLAG_FD_CLOEXEC);
			if (fds[cpu][group] < 0)
				goto out;
		}
	}
	shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE,
		      MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (shared == MAP_FAILED)
		goto out;
	atomic_init(&shared->ready, 0);
	atomic_init(&shared->error, 0);
	atomic_init(&shared->stop, false);
	child = fork();
	if (!child)
		child_main(shared, groups[0], tasks, cpus, nr_cpus, parent);
	if (child < 0)
		goto out;
	deadline = now() + 10;
	while (atomic_load(&shared->ready) != tasks) {
		if (atomic_load(&shared->error) || now() >= deadline) {
			fprintf(stderr, "worker startup failed ready=%u tasks=%u error=%d\n",
				atomic_load(&shared->ready), tasks, atomic_load(&shared->error));
			goto out;
		}
		usleep(10000);
	}
	if (atomic_load(&shared->error) ||
	    check_group(fds, cpus, nr_cpus, tasks, 0) || move_child(groups[1], child) ||
	    check_group(fds, cpus, nr_cpus, tasks, 1) || move_child(groups[0], child) ||
	    check_group(fds, cpus, nr_cpus, tasks, 0))
		goto out;
	atomic_store(&shared->stop, true);
	while (waitpid(child, &status, 0) < 0) {
		if (errno != EINTR) {
			if (errno == ECHILD)
				child = -1;
			goto out;
		}
	}
	child = -1;
	if (!WIFEXITED(status) || WEXITSTATUS(status)) {
		fprintf(stderr, "worker exited with unexpected wait status=%d\n", status);
		goto out;
	}
	printf("cgroup migration tasks=%u cpus=%u phases=3 passed\n", tasks, nr_cpus);
	ret = 0;
out:
	if (ret)
		perror("cgroup migration");
	if (child > 0) {
		kill(child, SIGKILL);
		while (waitpid(child, NULL, 0) < 0 && errno == EINTR)
			;
	}
	if (shared != MAP_FAILED)
		munmap(shared, sizeof(*shared));
	if (fds) {
		for (cpu = 0; cpu < nr_cpus; cpu++)
			for (group = 0; group < 2; group++)
				if (fds[cpu][group] >= 0)
					close(fds[cpu][group]);
		free(fds);
	}
	for (group = 0; group < 2; group++)
		if (groups[group] >= 0)
			close(groups[group]);
	return ret;
}
