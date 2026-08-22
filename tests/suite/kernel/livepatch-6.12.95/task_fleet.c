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

static size_t parse_count(const char *text, const char *name)
{
	char *end = NULL;
	unsigned long value;

	errno = 0;
	value = strtoul(text, &end, 10);
	if (errno || !end || *end || !value) {
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

static void child_main(enum child_role role, pid_t process_group)
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

static pid_t spawn_child(enum child_role role, pid_t process_group)
{
	pid_t pid = fork();

	if (pid < 0)
		return -1;
	if (!pid)
		child_main(role, process_group ? process_group : getpid());

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

int main(int argc, char **argv)
{
	struct sigaction action = {
		.sa_handler = request_stop,
	};
	const char *ready_path, *stop_path, *progress_path;
	size_t count, runnable, waking, churn, i, churn_cursor = 0;
	pid_t process_group = 0;
	pid_t *children;
	unsigned long cycles = 0;

	if (argc != 8) {
		fprintf(stderr,
			"usage: %s COUNT RUNNABLE WAKING CHURN READY STOP PROGRESS\n",
			argv[0]);
		return EXIT_FAILURE;
	}

	count = parse_count(argv[1], "count");
	runnable = parse_count(argv[2], "runnable count");
	waking = parse_count(argv[3], "waking count");
	churn = parse_count(argv[4], "churn count");
	ready_path = argv[5];
	stop_path = argv[6];
	progress_path = argv[7];
	if (runnable + waking + churn >= count) {
		fprintf(stderr, "role counts must leave sleeping tasks\n");
		return EXIT_FAILURE;
	}

	children = calloc(count, sizeof(*children));
	if (!children)
		die("calloc");
	if (sigemptyset(&action.sa_mask) || sigaction(SIGTERM, &action, NULL) ||
	    sigaction(SIGINT, &action, NULL))
		die("sigaction");

	for (i = 0; i < count; i++) {
		enum child_role role = ROLE_SLEEPING;

		if (i < runnable)
			role = ROLE_RUNNABLE;
		else if (i < runnable + waking)
			role = ROLE_WAKING;

		children[i] = spawn_child(role, process_group);
		if (children[i] < 0) {
			fprintf(stderr, "fork failed at child %zu of %zu: %s\n",
				i, count, strerror(errno));
			terminate_fleet(process_group, children, i);
			return EXIT_FAILURE;
		}
		if (!process_group)
			process_group = children[i];
	}

	write_state(ready_path, "tasks=%lu process_group=%lu\n",
		    count, (unsigned long)process_group);

	while (!stop_requested && access(stop_path, F_OK)) {
		struct timespec delay = {
			.tv_nsec = 100000000,
		};
		size_t replacements = churn < 32 ? churn : 32;

		for (i = runnable; i < runnable + waking; i++)
			kill(children[i], SIGUSR1);

		for (i = 0; i < replacements; i++) {
			size_t slot = count - churn + churn_cursor;
			pid_t replacement;

			kill(children[slot], SIGTERM);
			while (waitpid(children[slot], NULL, 0) < 0 && errno == EINTR)
				;
			replacement = spawn_child(ROLE_SLEEPING, process_group);
			if (replacement < 0) {
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
