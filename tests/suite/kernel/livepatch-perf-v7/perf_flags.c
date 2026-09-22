// SPDX-License-Identifier: GPL-2.0
/*
 * livepatch v7 perf witness probe (B3b / execution-record 11.3).
 *
 * P1  open a group leader with remove_on_exec, exec, then attach a sibling
 *     through the surviving fd: the exited leader must reject the attach
 *     with ENODEV.
 * P3  observational FD_NO_GROUP row.
 * P4  observational FD_NO_GROUP|FD_OUTPUT row.
 * P5  bounded exec/open race: P5_THREADS workers, P5_MAX_ATTEMPTS attempts or
 *     P5_MAX_SECONDS, whichever comes first.
 *
 * Every mode prints the raw return value and errno it observed. The two
 * observational rows intentionally require no success; only P1/P5 enforce
 * the ENODEV outcome.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/perf_event.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define P5_THREADS 8
#define P5_MAX_ATTEMPTS 100000
#define P5_MAX_SECONDS 900

static long perf_open(struct perf_event_attr *attr, int group_fd, unsigned long flags)
{
	return syscall(__NR_perf_event_open, attr, 0, -1, group_fd, flags);
}

static void init_attr(struct perf_event_attr *attr, int remove_on_exec)
{
	memset(attr, 0, sizeof(*attr));
	attr->size = sizeof(*attr);
	attr->type = PERF_TYPE_SOFTWARE;
	attr->config = PERF_COUNT_SW_CPU_CLOCK;
	attr->disabled = 1;
	attr->inherit = 1;
	if (remove_on_exec)
		attr->remove_on_exec = 1;
}

static int attach(int leader_fd, int quiet)
{
	struct perf_event_attr attr;
	int fd, err;

	init_attr(&attr, 0);
	errno = 0;
	fd = perf_open(&attr, leader_fd, 0);
	err = errno;
	if (!quiet)
		printf("attach group_fd=%d rc=%d errno=%d\n", leader_fd, fd,
		       fd < 0 ? err : 0);
	if (fd >= 0) {
		close(fd);
		return 2;	/* attached to an exited group leader */
	}
	if (err == ENODEV)
		return 0;
	if (!quiet)
		printf("attach unexpected errno %d (%s)\n", err, strerror(err));
	return 3;
}

static int mode_p1(int quiet)
{
	struct perf_event_attr attr;
	char fdbuf[16];
	char *argv[5];
	int leader, err;

	init_attr(&attr, 1);
	errno = 0;
	leader = perf_open(&attr, -1, 0);
	err = errno;
	if (leader < 0) {
		if (!quiet)
			printf("leader open failed errno=%d (%s)\n", err,
			       strerror(err));
		return 4;
	}
	snprintf(fdbuf, sizeof(fdbuf), "%d", leader);
	argv[0] = "/proc/self/exe";
	argv[1] = "p1-attach";
	if (quiet) {
		argv[2] = "quiet";
		argv[3] = fdbuf;
		argv[4] = NULL;
	} else {
		argv[2] = fdbuf;
		argv[3] = NULL;
	}
	execv("/proc/self/exe", argv);
	perror("execv");
	return 5;
}

static int mode_attach(int argc, char **argv)
{
	int quiet = argc > 2 && !strcmp(argv[2], "quiet");
	int fd = atoi(argv[quiet ? 3 : 2]);
	int rc;

	rc = attach(fd, quiet);
	if (!quiet)
		printf("P1 verdict: %s\n", rc == 0 ? "ENODEV" : "FAIL");
	return rc;
}

static int mode_observational(unsigned long flags)
{
	struct perf_event_attr attr;
	int leader, fd, err;

	init_attr(&attr, 0);
	errno = 0;
	leader = perf_open(&attr, -1, 0);
	err = errno;
	if (leader < 0) {
		printf("leader open failed errno=%d (%s)\n", err, strerror(err));
		return 4;
	}
	errno = 0;
	fd = perf_open(&attr, leader, flags);
	err = errno;
	printf("flags=0x%lx rc=%d errno=%d (%s)\n", flags, fd,
	       fd < 0 ? err : 0, fd < 0 ? strerror(err) : "ok");
	if (fd >= 0)
		close(fd);
	close(leader);
	return 0;	/* observational: no success requirement */
}

struct p5_state {
	atomic_int attempts;
	atomic_int enodev;
	atomic_int success;
	atomic_int other;
	atomic_int internal;
	atomic_int stop;
};

static void classify(struct p5_state *st, int status)
{
	if (WIFEXITED(status)) {
		switch (WEXITSTATUS(status)) {
		case 0:
			atomic_fetch_add(&st->enodev, 1);
			return;
		case 2:
			atomic_fetch_add(&st->success, 1);
			return;
		case 3:
			atomic_fetch_add(&st->other, 1);
			return;
		}
	}
	atomic_fetch_add(&st->internal, 1);
}

static void *p5_worker(void *arg)
{
	struct p5_state *st = arg;

	for (;;) {
		int prior, status;
		pid_t pid;

		if (atomic_load(&st->stop))
			return NULL;
		prior = atomic_fetch_add(&st->attempts, 1);
		if (prior >= P5_MAX_ATTEMPTS) {
			atomic_store(&st->stop, 1);
			return NULL;
		}
		pid = fork();
		if (pid < 0) {
			atomic_fetch_add(&st->internal, 1);
			continue;
		}
		if (pid == 0) {
			char *argv[4];

			argv[0] = "/proc/self/exe";
			argv[1] = "p1";
			argv[2] = "quiet";
			argv[3] = NULL;
			execv("/proc/self/exe", argv);
			_exit(5);
		}
		if (waitpid(pid, &status, 0) != pid) {
			atomic_fetch_add(&st->internal, 1);
			continue;
		}
		classify(st, status);
	}
}

static int mode_p5(void)
{
	struct p5_state st;
	pthread_t threads[P5_THREADS];
	struct timespec start, now;
	int i, elapsed = 0;

	memset(&st, 0, sizeof(st));
	clock_gettime(CLOCK_MONOTONIC, &start);
	for (i = 0; i < P5_THREADS; i++)
		pthread_create(&threads[i], NULL, p5_worker, &st);
	while (!atomic_load(&st.stop)) {
		usleep(200000);
		clock_gettime(CLOCK_MONOTONIC, &now);
		elapsed = (int)(now.tv_sec - start.tv_sec);
		if (elapsed >= P5_MAX_SECONDS)
			atomic_store(&st.stop, 1);
		if (atomic_load(&st.attempts) >= P5_MAX_ATTEMPTS)
			atomic_store(&st.stop, 1);
	}
	for (i = 0; i < P5_THREADS; i++)
		pthread_join(threads[i], NULL);
	printf("P5 attempts=%d enodev=%d success=%d other=%d internal=%d elapsed=%ds\n",
	       atomic_load(&st.attempts), atomic_load(&st.enodev),
	       atomic_load(&st.success), atomic_load(&st.other),
	       atomic_load(&st.internal), elapsed);
	if (atomic_load(&st.success) || atomic_load(&st.other) ||
	    atomic_load(&st.internal))
		return 1;
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s p1|p1-attach|p3|p4|p5\n", argv[0]);
		return 64;
	}
	if (!strcmp(argv[1], "p1"))
		return mode_p1(argc > 2 && !strcmp(argv[2], "quiet"));
	if (!strcmp(argv[1], "p1-attach"))
		return mode_attach(argc, argv);
	if (!strcmp(argv[1], "p3"))
		return mode_observational(PERF_FLAG_FD_NO_GROUP);
	if (!strcmp(argv[1], "p4"))
		return mode_observational(PERF_FLAG_FD_NO_GROUP |
					  PERF_FLAG_FD_OUTPUT);
	if (!strcmp(argv[1], "p5"))
		return mode_p5();
	fprintf(stderr, "unknown mode %s\n", argv[1]);
	return 64;
}
