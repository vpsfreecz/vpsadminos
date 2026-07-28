// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <linux/perf_event.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct shared_state {
	atomic_int ready;
	atomic_int go;
	atomic_int error;
};

static long perf_event_open(struct perf_event_attr *attr, int group_fd)
{
	return syscall(__NR_perf_event_open, attr, 0, -1, group_fd, 0);
}

static void fail_child(struct shared_state *state, const char *what)
{
	fprintf(stderr, "child: %s: %s\n", what, strerror(errno));
	atomic_store_explicit(&state->error, errno ? errno : EIO,
			      memory_order_release);
	_exit(1);
}

static int select_affinity_cpu(bool last)
{
	cpu_set_t mask;
	int cpu;
	int selected = -1;

	if (sched_getaffinity(0, sizeof(mask), &mask))
		return -1;

	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (!CPU_ISSET(cpu, &mask))
			continue;
		selected = cpu;
		if (!last)
			break;
	}

	return selected;
}

static int pin_to_cpu(int cpu)
{
	cpu_set_t mask;

	CPU_ZERO(&mask);
	CPU_SET(cpu, &mask);
	return sched_setaffinity(0, sizeof(mask), &mask);
}

static int set_fifo(bool enable)
{
	struct sched_param param = {
		.sched_priority = enable ? 80 : 0,
	};

	return sched_setscheduler(0, enable ? SCHED_FIFO : SCHED_OTHER,
				  &param);
}

static void exercise_promoted_event(int sibling)
{
	int i;

	for (i = 0; i < 1000; i++) {
		if (ioctl(sibling, PERF_EVENT_IOC_DISABLE,
			  PERF_IOC_FLAG_GROUP))
			_exit(2);
		if (ioctl(sibling, PERF_EVENT_IOC_ENABLE,
			  PERF_IOC_FLAG_GROUP))
			_exit(3);
		sched_yield();
	}
}

static int child_main(int argc, char **argv)
{
	struct shared_state *state;
	int phase;
	int leader;
	int sibling;
	int state_fd;
	int cpu;

	if (argc != 6)
		return 64;

	phase = atoi(argv[2]);
	leader = atoi(argv[3]);
	sibling = atoi(argv[4]);
	state_fd = atoi(argv[5]);

	state = mmap(NULL, sizeof(*state), PROT_READ | PROT_WRITE, MAP_SHARED,
		     state_fd, 0);
	if (state == MAP_FAILED)
		return 65;

	prctl(PR_SET_NAME, "klp-perf-child");

	if (phase == 2) {
		cpu = select_affinity_cpu(true);
		if (cpu < 0 || pin_to_cpu(cpu))
			fail_child(state, "pin phase-2 child");
		if (set_fifo(true))
			fail_child(state, "enter SCHED_FIFO");

		if (close(leader))
			fail_child(state, "close detached leader");
		atomic_store_explicit(&state->ready, 1, memory_order_release);
		while (!atomic_load_explicit(&state->go, memory_order_acquire))
			asm volatile("pause" ::: "memory");

		if (set_fifo(false))
			fail_child(state, "leave SCHED_FIFO");
	} else {
		atomic_store_explicit(&state->ready, 1, memory_order_release);
		while (!atomic_load_explicit(&state->go, memory_order_acquire))
			usleep(1000);
		if (close(leader))
			fail_child(state, "close detached leader");
	}

	exercise_promoted_event(sibling);
	if (close(sibling))
		fail_child(state, "close promoted sibling");

	return 0;
}

static int run_insmod(const char *module)
{
	pid_t pid;
	int status;

	pid = fork();
	if (pid < 0)
		return -1;
	if (!pid) {
		execlp("insmod", "insmod", module, NULL);
		_exit(127);
	}
	if (waitpid(pid, &status, 0) != pid)
		return -1;
	if (!WIFEXITED(status) || WEXITSTATUS(status))
		return -1;
	return 0;
}

static int read_sysfs_int(const char *module_name, const char *attribute,
			  int *value)
{
	char path[512];
	char buf[32];
	int fd;
	ssize_t len;

	snprintf(path, sizeof(path), "/sys/kernel/livepatch/%s/%s",
		 module_name, attribute);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	len = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (len <= 0)
		return -1;
	buf[len] = '\0';
	*value = atoi(buf);
	return 0;
}

static int wait_for_patch(const char *module_name)
{
	struct timespec start;
	struct timespec now;
	int enabled;
	int transition;

	clock_gettime(CLOCK_MONOTONIC, &start);
	for (;;) {
		if (!read_sysfs_int(module_name, "enabled", &enabled) &&
		    !read_sysfs_int(module_name, "transition", &transition) &&
		    enabled == 1 && transition == 0)
			return 0;

		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec - start.tv_sec >= 30)
			return -1;
		usleep(1000);
	}
}

static int parent_main(int argc, char **argv)
{
	struct perf_event_attr leader_attr = {
		.type = PERF_TYPE_SOFTWARE,
		.size = sizeof(leader_attr),
		.config = PERF_COUNT_SW_TASK_CLOCK,
		.disabled = 1,
		.exclude_kernel = 1,
		.exclude_hv = 1,
		.remove_on_exec = 1,
	};
	struct perf_event_attr sibling_attr = {
		.type = PERF_TYPE_SOFTWARE,
		.size = sizeof(sibling_attr),
		.config = PERF_COUNT_SW_CPU_CLOCK,
		.disabled = 0,
		.exclude_kernel = 1,
		.exclude_hv = 1,
	};
	struct shared_state *state;
	char leader_arg[24];
	char sibling_arg[24];
	char state_arg[24];
	int state_fd;
	int leader;
	int sibling;
	int status;
	int phase;
	int cpu;
	pid_t child;
	struct timespec start;
	struct timespec now;

	if (argc != 4) {
		fprintf(stderr,
			"usage: %s <phase:1|2> <module.ko> <module-name>\n",
			argv[0]);
		return 64;
	}
	phase = atoi(argv[1]);
	if (phase != 1 && phase != 2)
		return 64;

	cpu = select_affinity_cpu(false);
	if (cpu < 0 || pin_to_cpu(cpu)) {
		perror("pin parent");
		return 1;
	}

	state_fd = syscall(__NR_memfd_create, "perf-klp-state", 0);
	if (state_fd < 0 || ftruncate(state_fd, 4096)) {
		perror("memfd");
		return 1;
	}
	state = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, state_fd,
		     0);
	if (state == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	memset(state, 0, 4096);

	child = fork();
	if (child < 0) {
		perror("fork");
		return 1;
	}
	if (!child) {
		leader = perf_event_open(&leader_attr, -1);
		if (leader < 0)
			fail_child(state, "perf_event_open leader");
		sibling = perf_event_open(&sibling_attr, leader);
		if (sibling < 0)
			fail_child(state, "perf_event_open sibling");
		if (ioctl(leader, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP))
			fail_child(state, "enable group");

		snprintf(leader_arg, sizeof(leader_arg), "%d", leader);
		snprintf(sibling_arg, sizeof(sibling_arg), "%d", sibling);
		snprintf(state_arg, sizeof(state_arg), "%d", state_fd);
		execl("/proc/self/exe", "perf_transition", "child", argv[1],
		      leader_arg, sibling_arg, state_arg, NULL);
		fail_child(state, "exec child");
	}

	clock_gettime(CLOCK_MONOTONIC, &start);
	while (!atomic_load_explicit(&state->ready, memory_order_acquire)) {
		if (atomic_load_explicit(&state->error, memory_order_acquire))
			break;
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec - start.tv_sec >= 10)
			break;
		usleep(1000);
	}
	if (!atomic_load_explicit(&state->ready, memory_order_acquire)) {
		fprintf(stderr, "child did not reach legacy phase %d\n", phase);
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}

	if (run_insmod(argv[2])) {
		perror("insmod");
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}
	if (wait_for_patch(argv[3])) {
		fprintf(stderr, "livepatch did not finish activation\n");
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
		return 1;
	}

	atomic_store_explicit(&state->go, 1, memory_order_release);
	if (waitpid(child, &status, 0) != child ||
	    !WIFEXITED(status) || WEXITSTATUS(status)) {
		fprintf(stderr, "phase %d child failed: status=%#x\n", phase,
			status);
		return 1;
	}

	printf("perf transition phase %d: PASS\n", phase);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "child"))
		return child_main(argc, argv);
	return parent_main(argc, argv);
}
