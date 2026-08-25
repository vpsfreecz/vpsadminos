#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/sched/types.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested;
static volatile unsigned long long spin_sink;

static void request_stop(int signum)
{
	(void)signum;
	stop_requested = 1;
}

static void install_stop_handler(void)
{
	struct sigaction action = {
		.sa_handler = request_stop,
	};

	if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL)) {
		perror("sigaction");
		exit(EXIT_FAILURE);
	}
}

static int set_deadline_policy(void)
{
	struct sched_attr attr = {
		.size = sizeof(attr),
		.sched_policy = SCHED_DEADLINE,
		.sched_runtime = 1000 * 1000,
		.sched_deadline = 2 * 1000 * 1000,
		.sched_period = 10 * 1000 * 1000,
	};

	return syscall(SYS_sched_setattr, 0, &attr, 0);
}

static void busy_spin(int seed)
{
	unsigned long long local = (unsigned long long)seed + 1;

	while (!stop_requested) {
		for (unsigned int i = 0; i < 4096; i++)
			local = local * 2862933555777941757ULL + 3037000493ULL;
		spin_sink = local;
	}
}

static void child_main(int seed, int ready_fd)
{
	/*
	 * SCHED_DEADLINE rejects tasks whose affinity mask does not span their
	 * root domain. Keep the inherited full allowed mask here; the surrounding
	 * guest/cgroup configuration defines the intended CPU domain.
	 */
	if (set_deadline_policy()) {
		fprintf(stderr, "sched_setattr worker %d: %s\n", seed, strerror(errno));
		_exit(EXIT_FAILURE);
	}
	if (write(ready_fd, ".", 1) != 1) {
		perror("write ready");
		_exit(EXIT_FAILURE);
	}
	if (close(ready_fd)) {
		perror("close ready");
		_exit(EXIT_FAILURE);
	}

	install_stop_handler();
	busy_spin(seed);
	_exit(EXIT_SUCCESS);
}

static void kill_children(const pid_t *children, size_t count)
{
	for (size_t i = 0; i < count; i++) {
		if (children[i] <= 0)
			continue;
		kill(children[i], SIGTERM);
	}
}

static void reap_children(pid_t *children, size_t count)
{
	for (size_t i = 0; i < count; i++) {
		int status;

		if (children[i] <= 0)
			continue;
		while (waitpid(children[i], &status, 0) < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "waitpid %ld: %s\n",
				(long)children[i], strerror(errno));
			break;
		}
		children[i] = 0;
	}
}

static void write_ready_file(const char *path, size_t count)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);

	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		exit(EXIT_FAILURE);
	}
	if (dprintf(fd, "cpus=%zu\n", count) < 0) {
		fprintf(stderr, "write %s: %s\n", path, strerror(errno));
		close(fd);
		exit(EXIT_FAILURE);
	}
	if (close(fd)) {
		fprintf(stderr, "close %s: %s\n", path, strerror(errno));
		exit(EXIT_FAILURE);
	}
}

int main(int argc, char **argv)
{
	const char *ready_path, *stop_path;
	cpu_set_t allowed;
	pid_t *children;
	int ready_pipe[2];
	int allowed_cpu_ids[CPU_SETSIZE];
	int allowed_cpu_count = 0;
	size_t ready = 0;
	bool child_failed = false;

	if (argc != 3) {
		fprintf(stderr, "usage: %s READY STOP\n", argv[0]);
		return EXIT_FAILURE;
	}

	ready_path = argv[1];
	stop_path = argv[2];

	if (sched_getaffinity(0, sizeof(allowed), &allowed)) {
		perror("sched_getaffinity");
		return EXIT_FAILURE;
	}
	for (int cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (!CPU_ISSET(cpu, &allowed))
			continue;
		allowed_cpu_ids[allowed_cpu_count++] = cpu;
	}
	if (allowed_cpu_count <= 0) {
		fprintf(stderr, "no allowed CPUs available\n");
		return EXIT_FAILURE;
	}
	fprintf(stderr, "deadline sentinel allowed_cpus=%d\n", allowed_cpu_count);

	children = calloc((size_t)allowed_cpu_count, sizeof(*children));
	if (!children) {
		perror("calloc");
		return EXIT_FAILURE;
	}
	if (pipe2(ready_pipe, O_CLOEXEC)) {
		perror("pipe2");
		free(children);
		return EXIT_FAILURE;
	}

	install_stop_handler();

	for (int i = 0; i < allowed_cpu_count; i++) {
		pid_t pid = fork();

		if (pid < 0) {
			perror("fork");
			stop_requested = 1;
			break;
		}
		if (pid == 0) {
			close(ready_pipe[0]);
			child_main(allowed_cpu_ids[i], ready_pipe[1]);
		}
		children[i] = pid;
	}

	close(ready_pipe[1]);

	while (ready < (size_t)allowed_cpu_count) {
		char buffer[64];
		ssize_t n = read(ready_pipe[0], buffer, sizeof(buffer));

		if (n < 0) {
			if (errno == EINTR)
				continue;
			perror("read ready");
			child_failed = true;
			break;
		}
		if (n == 0)
			break;
		ready += (size_t)n;
	}

	if (close(ready_pipe[0]))
		perror("close ready pipe");

	if (ready != (size_t)allowed_cpu_count) {
		fprintf(stderr,
			"deadline sentinel ready bytes=%zu expected=%d\n",
			ready, allowed_cpu_count);
		child_failed = true;
	}

	if (!child_failed)
		write_ready_file(ready_path, (size_t)allowed_cpu_count);

	while (!stop_requested && !child_failed) {
		int status;
		pid_t pid = waitpid(-1, &status, WNOHANG);

		if (pid > 0) {
			fprintf(stderr, "deadline sentinel child %ld exited unexpectedly\n",
				(long)pid);
			child_failed = true;
			break;
		}
		if (pid < 0 && errno != ECHILD && errno != EINTR) {
			fprintf(stderr, "waitpid: %s\n", strerror(errno));
			child_failed = true;
			break;
		}
		if (access(stop_path, F_OK) == 0)
			break;
		{
			struct timespec delay = {
				.tv_nsec = 10000000,
			};
			nanosleep(&delay, NULL);
		}
	}

	kill_children(children, (size_t)allowed_cpu_count);
	reap_children(children, (size_t)allowed_cpu_count);
	free(children);

	return child_failed ? EXIT_FAILURE : EXIT_SUCCESS;
}
