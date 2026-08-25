// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum child_role {
	ROLE_SLEEPING,
	ROLE_RUNNABLE,
	ROLE_WAKING,
};

static volatile sig_atomic_t stop_requested;

static void request_stop(int signo)
{
	(void)signo;
	stop_requested = 1;
}

static void wake_child(int signo)
{
	(void)signo;
}

static void die(const char *what)
{
	perror(what);
	exit(EXIT_FAILURE);
}

static size_t parse_count(const char *text, const char *name, bool allow_zero)
{
	char *end = NULL;
	unsigned long value;

	errno = 0;
	value = strtoul(text, &end, 10);
	if (errno || !end || *end || (!allow_zero && !value)) {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		exit(EXIT_FAILURE);
	}

	return value;
}

static unsigned long parse_limit_or_zero(const char *text, const char *name)
{
	char *end = NULL;
	unsigned long value;

	if (!text || !*text)
		return 0;

	errno = 0;
	value = strtoul(text, &end, 10);
	if (errno || !end || *end) {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		exit(EXIT_FAILURE);
	}

	return value;
}

static void write_state(const char *path, const char *format,
			unsigned long first, unsigned long second)
{
	int fd;

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		die(path);
	if (dprintf(fd, format, first, second) < 0)
		die("dprintf");
	if (fsync(fd))
		die("fsync");
	if (close(fd))
		die("close");
}

static void child_main(enum child_role role, pid_t process_group, int cpu)
{
	struct sigaction action = {
		.sa_handler = wake_child,
	};
	struct sigaction default_action = {
		.sa_handler = SIG_DFL,
	};
	unsigned long iterations = 0;

	if (setpgid(0, process_group))
		_exit(110);
	if (role == ROLE_RUNNABLE) {
		cpu_set_t affinity;

		CPU_ZERO(&affinity);
		CPU_SET(cpu, &affinity);
		if (sched_setaffinity(0, sizeof(affinity), &affinity))
			_exit(114);
	}
	if (prctl(PR_SET_PDEATHSIG, SIGTERM))
		_exit(111);
	if (getppid() == 1)
		_exit(112);

	if (sigemptyset(&default_action.sa_mask) ||
	    sigaction(SIGTERM, &default_action, NULL) ||
	    sigaction(SIGINT, &default_action, NULL) ||
	    sigemptyset(&action.sa_mask) || sigaction(SIGUSR1, &action, NULL))
		_exit(113);

	if (role != ROLE_RUNNABLE) {
		for (;;)
			pause();
	}

	for (;;) {
		sched_yield();
		if (!(++iterations & 0xffff) && getppid() == 1)
			_exit(0);
	}
}

static pid_t spawn_child(enum child_role role, pid_t process_group, int cpu)
{
	pid_t pid = fork();

	if (pid < 0)
		return -1;
	if (!pid)
		child_main(role, process_group ? process_group : getpid(), cpu);

	if (setpgid(pid, process_group ? process_group : pid) && errno != EACCES) {
		int saved_errno = errno;

		kill(pid, SIGKILL);
		while (waitpid(pid, NULL, 0) < 0 && errno == EINTR)
			;
		errno = saved_errno;
		return -1;
	}

	return pid;
}

static void terminate_fleet(pid_t process_group, pid_t *children, size_t count)
{
	size_t i;

	if (process_group > 0)
		kill(-process_group, SIGTERM);
	for (i = 0; i < count; i++) {
		if (children[i] <= 0)
			continue;
		while (waitpid(children[i], NULL, 0) < 0 && errno == EINTR)
			;
	}
}

static bool stop_requested_during_spawn(const char *stop_path)
{
	return stop_requested || access(stop_path, F_OK) == 0;
}

static int attach_child_to_cgroup(const char *cgroup_procs_path, pid_t pid)
{
	int fd;

	if (!cgroup_procs_path)
		return 0;

	fd = open(cgroup_procs_path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	if (dprintf(fd, "%ld\n", (long)pid) < 0) {
		int saved_errno = errno;

		close(fd);
		errno = saved_errno;
		return -1;
	}
	if (close(fd))
		return -1;

	return 0;
}

int main(int argc, char **argv)
{
	struct sigaction action = {
		.sa_handler = request_stop,
	};
	const char *ready_path, *stop_path, *progress_path;
	const char *child_cgroup_procs_path = NULL;
	size_t count, runnable, waking, churn, i, churn_cursor = 0, spawned = 0;
	cpu_set_t allowed_cpus;
	int allowed_cpu_count;
	int allowed_cpu_ids[CPU_SETSIZE];
	int allowed_cpu_index = 0;
	unsigned long max_churn_cycles = 0;
	pid_t process_group = 0;
	pid_t *children;
	unsigned long cycles = 0;

	if (argc != 8 && argc != 9) {
		fprintf(stderr,
			"usage: %s COUNT RUNNABLE WAKING CHURN READY STOP PROGRESS [CGROUP_PROCS]\n",
			argv[0]);
		return EXIT_FAILURE;
	}

	count = parse_count(argv[1], "count", false);
	runnable = parse_count(argv[2], "runnable count", false);
	waking = parse_count(argv[3], "waking count", false);
	churn = parse_count(argv[4], "churn count", true);
	ready_path = argv[5];
	stop_path = argv[6];
	progress_path = argv[7];
	if (argc == 9)
		child_cgroup_procs_path = argv[8];
	max_churn_cycles = parse_limit_or_zero(getenv("TASK_FLEET_MAX_CHURN_CYCLES"),
					       "max churn cycles");
	if (runnable + waking + churn >= count) {
		fprintf(stderr, "role counts must leave sleeping tasks\n");
		return EXIT_FAILURE;
	}
	if (sched_getaffinity(0, sizeof(allowed_cpus), &allowed_cpus))
		die("sched_getaffinity");
	allowed_cpu_count = CPU_COUNT(&allowed_cpus);
	if (allowed_cpu_count <= 0) {
		fprintf(stderr, "no allowed CPUs available\n");
		return EXIT_FAILURE;
	}
	for (i = 0; i < CPU_SETSIZE; i++) {
		if (!CPU_ISSET(i, &allowed_cpus))
			continue;
		allowed_cpu_ids[allowed_cpu_index++] = i;
	}

	children = calloc(count, sizeof(*children));
	if (!children)
		die("calloc");
	if (sigemptyset(&action.sa_mask) || sigaction(SIGTERM, &action, NULL) ||
	    sigaction(SIGINT, &action, NULL))
		die("sigaction");

	write_state(progress_path, "phase=spawn spawned=%lu tasks=%lu\n",
		    0, count);

	for (i = 0; i < count; i++) {
		enum child_role role = ROLE_SLEEPING;

		if (stop_requested_during_spawn(stop_path)) {
			write_state(progress_path,
				    "phase=spawn-stopped spawned=%lu tasks=%lu\n",
				    spawned, count);
			terminate_fleet(process_group, children, spawned);
			return EXIT_SUCCESS;
		}

		if (i < runnable)
			role = ROLE_RUNNABLE;
		else if (i < runnable + waking)
			role = ROLE_WAKING;

		children[i] = spawn_child(role, process_group,
					   role == ROLE_RUNNABLE ?
					   allowed_cpu_ids[i % (size_t)allowed_cpu_count] :
					   -1);
		if (children[i] < 0) {
			fprintf(stderr, "fork failed at child %zu of %zu: %s\n",
				i, count, strerror(errno));
			terminate_fleet(process_group, children, i);
			return EXIT_FAILURE;
		}
		if (!process_group)
			process_group = children[i];
		if (attach_child_to_cgroup(child_cgroup_procs_path, children[i])) {
			fprintf(stderr,
				"failed to move child %ld into %s: %s\n",
				(long)children[i], child_cgroup_procs_path,
				strerror(errno));
			terminate_fleet(process_group, children, i + 1);
			return EXIT_FAILURE;
		}
		spawned++;
		if (!(spawned & 0xff) || spawned == count)
			write_state(progress_path,
				    "phase=spawn spawned=%lu tasks=%lu\n",
				    spawned, count);
	}

	write_state(ready_path, "tasks=%lu runnable_pinned=%lu\n",
		    count, runnable);

	while (!stop_requested && access(stop_path, F_OK)) {
		struct timespec delay = {
			.tv_nsec = 100000000,
		};
		bool churn_active = !max_churn_cycles || cycles < max_churn_cycles;
		size_t replacements =
			churn_active ? (churn < 32 ? churn : 32) : 0;

		for (i = runnable; i < runnable + waking; i++)
			kill(children[i], SIGUSR1);

		for (i = 0; i < replacements; i++) {
			size_t slot = count - churn + churn_cursor;
			pid_t replacement;

			kill(children[slot], SIGTERM);
			while (waitpid(children[slot], NULL, 0) < 0 && errno == EINTR)
				;
			replacement = spawn_child(ROLE_SLEEPING, process_group, -1);
			if (replacement < 0) {
				stop_requested = 1;
				children[slot] = 0;
				break;
			}
			if (attach_child_to_cgroup(child_cgroup_procs_path,
						   replacement)) {
				fprintf(stderr,
					"failed to move replacement %ld into %s: %s\n",
					(long)replacement, child_cgroup_procs_path,
					strerror(errno));
				kill(replacement, SIGKILL);
				while (waitpid(replacement, NULL, 0) < 0 &&
				       errno == EINTR)
					;
				children[slot] = 0;
				stop_requested = 1;
				break;
			}
			children[slot] = replacement;
			churn_cursor = (churn_cursor + 1) % churn;
		}

		cycles++;
		write_state(progress_path, "cycles=%lu tasks=%lu\n",
			    cycles, count);
		nanosleep(&delay, NULL);
	}

	terminate_fleet(process_group, children, count);
	free(children);
	return EXIT_SUCCESS;
}
