// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fuse.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#define REQUEST_BUFFER_SIZE (1024U * 1024U)
#define TEST_PAGE_SIZE 4096U
#define TEST_NODE_ID 2
#define RESEND_REQUESTS 3
#define FUSE_INTERRUPT_UNIQUE_BIT (1ULL << 0)

enum writeback_finish {
	WRITEBACK_REPLY,
	WRITEBACK_ABORT,
	WRITEBACK_CLOSE,
};

struct fuse_test {
	const char *mountpoint;
	const char *state_dir;
	int fd;
	unsigned int connection;
	unsigned char *buffer;
};

struct held_request {
	uint64_t unique;
	uint32_t pid;
	pid_t child;
};

static void fail(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(EXIT_FAILURE);
}

static void fail_value(const char *what, unsigned long long actual,
		       unsigned long long expected)
{
	fprintf(stderr, "%s: got %llu, expected %llu\n",
		what, actual, expected);
	exit(EXIT_FAILURE);
}

static void state_path(const struct fuse_test *test, const char *name,
		       char *path, size_t size)
{
	int length;

	length = snprintf(path, size, "%s/%s", test->state_dir, name);
	if (length < 0 || (size_t)length >= size) {
		errno = ENAMETOOLONG;
		fail("state path");
	}
}

static void write_state(const struct fuse_test *test, const char *name,
			const char *value)
{
	char path[PATH_MAX];
	size_t length = strlen(value);
	ssize_t written;
	int fd;

	state_path(test, name, path, sizeof(path));
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0)
		fail("open state file");
	written = write(fd, value, length);
	if (written < 0 || (size_t)written != length)
		fail("write state file");
	if (close(fd))
		fail("close state file");
}

static void wait_for_state(const struct fuse_test *test, const char *name)
{
	struct stat statbuf;
	char path[PATH_MAX];

	state_path(test, name, path, sizeof(path));
	while (stat(path, &statbuf)) {
		if (errno != ENOENT)
			fail("stat state file");
		usleep(1000);
	}
}

static void write_all(int fd, const void *buffer, size_t length)
{
	const unsigned char *position = buffer;

	while (length) {
		ssize_t written = write(fd, position, length);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			fail("write");
		}
		if (!written) {
			errno = EIO;
			fail("short write");
		}
		position += written;
		length -= written;
	}
}

static ssize_t read_request(struct fuse_test *test)
{
	ssize_t length;

	do {
		length = read(test->fd, test->buffer, REQUEST_BUFFER_SIZE);
	} while (length < 0 && errno == EINTR);
	if (length < 0)
		fail("read FUSE request");
	if ((size_t)length < sizeof(struct fuse_in_header)) {
		errno = EPROTO;
		fail("short FUSE request");
	}
	return length;
}

static ssize_t splice_request(struct fuse_test *test)
{
	size_t total = 0;
	int pipefd[2];
	ssize_t length;

	if (pipe2(pipefd, O_CLOEXEC))
		fail("pipe2");
	if (fcntl(pipefd[1], F_SETPIPE_SZ, REQUEST_BUFFER_SIZE) < 0)
		fail("size splice pipe");

	do {
		length = splice(test->fd, NULL, pipefd[1], NULL,
				REQUEST_BUFFER_SIZE, SPLICE_F_MOVE);
	} while (length < 0 && errno == EINTR);
	if (length < 0) {
		int saved_errno = errno;

		close(pipefd[0]);
		close(pipefd[1]);
		errno = saved_errno;
		return -1;
	}
	if ((size_t)length > REQUEST_BUFFER_SIZE) {
		close(pipefd[0]);
		close(pipefd[1]);
		errno = EOVERFLOW;
		return -1;
	}

	while (total < (size_t)length) {
		ssize_t copied;

		copied = read(pipefd[0], test->buffer + total,
			      (size_t)length - total);
		if (copied < 0) {
			if (errno == EINTR)
				continue;
			fail("read spliced FUSE request");
		}
		if (!copied) {
			errno = EIO;
			fail("short spliced FUSE request");
		}
		total += copied;
	}
	if (close(pipefd[0]) || close(pipefd[1]))
		fail("close splice pipe");
	if (total < sizeof(struct fuse_in_header)) {
		errno = EPROTO;
		fail("short spliced FUSE header");
	}
	return length;
}

static void reply_request(struct fuse_test *test, uint64_t unique, int error,
			  const void *payload, size_t payload_length)
{
	struct fuse_out_header header = {
		.len = sizeof(header) + payload_length,
		.error = error,
		.unique = unique,
	};
	struct iovec vectors[2] = {
		{
			.iov_base = &header,
			.iov_len = sizeof(header),
		},
		{
			.iov_base = (void *)payload,
			.iov_len = payload_length,
		},
	};
	ssize_t written;
	int count = payload_length ? 2 : 1;

	do {
		written = writev(test->fd, vectors, count);
	} while (written < 0 && errno == EINTR);
	if (written < 0)
		fail("write FUSE reply");
	if ((size_t)written != sizeof(header) + payload_length) {
		errno = EIO;
		fail("short FUSE reply");
	}
}

static struct fuse_attr test_attr(void)
{
	struct fuse_attr attr = {
		.ino = TEST_NODE_ID,
		.size = 4096,
		.blocks = 8,
		.atime = 1,
		.mtime = 1,
		.ctime = 1,
		.mode = S_IFREG | 0644,
		.nlink = 1,
		.uid = 0,
		.gid = 0,
		.blksize = 4096,
	};

	return attr;
}

static void handle_request(struct fuse_test *test, ssize_t length)
{
	struct fuse_in_header *header = (void *)test->buffer;

	if ((uint32_t)length != header->len)
		fail_value("FUSE request length", length, header->len);

	switch (header->opcode) {
	case FUSE_LOOKUP: {
		struct fuse_entry_out entry = {
			.nodeid = TEST_NODE_ID,
			.generation = 1,
			.attr = test_attr(),
		};

		reply_request(test, header->unique, 0, &entry, sizeof(entry));
		break;
	}
	case FUSE_GETATTR:
	case FUSE_SETATTR: {
		struct fuse_attr_out attr = {
			.attr = test_attr(),
		};

		reply_request(test, header->unique, 0, &attr, sizeof(attr));
		break;
	}
	case FUSE_OPEN: {
		struct fuse_open_out open_out = {
			.fh = 1,
			.open_flags = FOPEN_KEEP_CACHE,
		};

		reply_request(test, header->unique, 0, &open_out,
			      sizeof(open_out));
		break;
	}
	case FUSE_READ: {
		struct fuse_read_in *read_in;
		unsigned long long unique = header->unique;
		unsigned int size;

		if ((size_t)length < sizeof(*header) + sizeof(*read_in)) {
			errno = EPROTO;
			fail("short FUSE_READ");
		}
		read_in = (void *)(header + 1);
		size = read_in->size;
		if (size > REQUEST_BUFFER_SIZE) {
			errno = EOVERFLOW;
			fail("oversized FUSE_READ");
		}
		memset(test->buffer, 0, size);
		reply_request(test, unique, 0, test->buffer, size);
		break;
	}
	case FUSE_WRITE: {
		struct fuse_write_in *write_in;
		struct fuse_write_out write_out;

		if ((size_t)length < sizeof(*header) + sizeof(*write_in)) {
			errno = EPROTO;
			fail("short FUSE_WRITE");
		}
		write_in = (void *)(header + 1);
		write_out.size = write_in->size;
		write_out.padding = 0;
		reply_request(test, header->unique, 0, &write_out,
			      sizeof(write_out));
		break;
	}
	case FUSE_GETXATTR:
		reply_request(test, header->unique, -ENODATA, NULL, 0);
		break;
	case FUSE_FLUSH:
	case FUSE_FSYNC:
	case FUSE_RELEASE:
	case FUSE_ACCESS:
	case FUSE_SYNCFS:
		reply_request(test, header->unique, 0, NULL, 0);
		break;
	case FUSE_FORGET:
	case FUSE_BATCH_FORGET:
	case FUSE_DESTROY:
		break;
	default:
		fprintf(stderr, "unexpected FUSE opcode %u\n", header->opcode);
		reply_request(test, header->unique, -ENOSYS, NULL, 0);
		break;
	}
}

static unsigned int highest_connection(void)
{
	struct dirent *entry;
	DIR *directory;
	unsigned int highest = 0;

	directory = opendir("/sys/fs/fuse/connections");
	if (!directory)
		fail("open FUSE connections");
	while ((entry = readdir(directory))) {
		char *end;
		unsigned long value;

		errno = 0;
		value = strtoul(entry->d_name, &end, 10);
		if (errno || *end || value > UINT32_MAX)
			continue;
		if (value > highest)
			highest = value;
	}
	if (closedir(directory))
		fail("close FUSE connections");
	return highest;
}

static void initialize_fuse(struct fuse_test *test, bool resend)
{
	struct fuse_in_header *header;
	struct fuse_init_in *init_in;
	struct fuse_init_out init_out = {
		.major = FUSE_KERNEL_VERSION,
		.max_readahead = 128 * 1024,
		.max_background = 64,
		.congestion_threshold = 48,
		.max_write = 128 * 1024,
		.time_gran = 1,
		.max_pages = 32,
	};
	uint64_t offered_flags;
	uint64_t required_flags;
	char options[256];
	unsigned int old_connection;
	ssize_t length;

	old_connection = highest_connection();
	test->fd = open("/dev/fuse", O_RDWR | O_CLOEXEC);
	if (test->fd < 0)
		fail("open /dev/fuse");
	if (mkdir(test->mountpoint, 0700) && errno != EEXIST)
		fail("mkdir FUSE mountpoint");

	snprintf(options, sizeof(options),
		 "fd=%d,rootmode=40000,user_id=0,group_id=0,max_read=131072",
		 test->fd);
	if (mount("livepatch-fuse", test->mountpoint, "fuse",
		  MS_NOSUID | MS_NODEV, options))
		fail("mount FUSE filesystem");

	length = read_request(test);
	header = (void *)test->buffer;
	if (header->opcode != FUSE_INIT)
		fail_value("first FUSE opcode", header->opcode, FUSE_INIT);
	if ((size_t)length < sizeof(*header) + sizeof(*init_in)) {
		errno = EPROTO;
		fail("short FUSE_INIT");
	}
	init_in = (void *)(header + 1);
	if (init_in->major != FUSE_KERNEL_VERSION)
		fail_value("FUSE protocol major", init_in->major,
			   FUSE_KERNEL_VERSION);
	offered_flags = init_in->flags;
	if (init_in->flags & FUSE_INIT_EXT)
		offered_flags |= (uint64_t)init_in->flags2 << 32;
	required_flags = FUSE_ASYNC_READ | FUSE_BIG_WRITES |
			 FUSE_SPLICE_READ | FUSE_WRITEBACK_CACHE |
			 FUSE_MAX_PAGES | FUSE_INIT_EXT;
	if (resend)
		required_flags |= FUSE_HAS_RESEND | FUSE_PARALLEL_DIROPS;
	if ((offered_flags & required_flags) != required_flags) {
		errno = EOPNOTSUPP;
		fail("required FUSE protocol flags");
	}
	init_out.minor = init_in->minor;
	init_out.flags = required_flags;
	init_out.flags2 = required_flags >> 32;
	reply_request(test, header->unique, 0, &init_out, sizeof(init_out));

	test->connection = highest_connection();
	if (test->connection <= old_connection) {
		errno = EPROTO;
		fail("identify new FUSE connection");
	}

	snprintf(options, sizeof(options), "%u\n", test->connection);
	write_state(test, "connection", options);
}

static void cleanup_fuse(struct fuse_test *test)
{
	umount2(test->mountpoint, MNT_DETACH);
	if (test->fd >= 0)
		close(test->fd);
	test->fd = -1;
}

static void wait_for_child(pid_t child, bool require_success)
{
	int status;

	if (waitpid(child, &status, 0) != child)
		fail("waitpid");
	if (require_success &&
	    (!WIFEXITED(status) || WEXITSTATUS(status) != EXIT_SUCCESS)) {
		errno = ECHILD;
		fail("child failed");
	}
}

static void writeback_child(const char *path, int ready_fd, int control_fd,
			    bool expect_success)
{
	void *mapping;
	char command;
	int fd;
	int result = 0;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		_exit(10);
	write_all(ready_fd, "R", 1);
	if (read(control_fd, &command, 1) != 1)
		_exit(11);

	mapping = mmap(NULL, TEST_PAGE_SIZE, PROT_READ | PROT_WRITE,
		       MAP_SHARED, fd, 0);
	if (mapping == MAP_FAILED)
		result = errno ? errno : EIO;
	if (!result) {
		memset(mapping, 0xa5, TEST_PAGE_SIZE);
		if (msync(mapping, TEST_PAGE_SIZE, MS_SYNC))
			result = errno ? errno : EIO;
	}
	if (mapping != MAP_FAILED &&
	    munmap(mapping, TEST_PAGE_SIZE) && !result)
		result = errno ? errno : EIO;
	if (close(fd) && !result)
		result = errno ? errno : EIO;

	if (expect_success ? result != 0 : result == 0)
		_exit(12);
	_exit(EXIT_SUCCESS);
}

static bool child_ready(int fd)
{
	char byte;
	ssize_t length;

	length = read(fd, &byte, 1);
	if (length < 0) {
		if (errno == EAGAIN)
			return false;
		fail("read child readiness");
	}
	if (length != 1 || byte != 'R') {
		errno = EPROTO;
		fail("invalid child readiness");
	}
	return true;
}

static void prepare_writeback_file(struct fuse_test *test, pid_t child,
				   int ready_fd)
{
	struct pollfd descriptors[2] = {
		{
			.fd = test->fd,
			.events = POLLIN,
		},
		{
			.fd = ready_fd,
			.events = POLLIN,
		},
	};

	for (;;) {
		int status;
		int result;

		result = waitpid(child, &status, WNOHANG);
		if (result < 0)
			fail("waitpid writeback preparation");
		if (result == child) {
			errno = ECHILD;
			fail("writeback child exited during preparation");
		}

		result = poll(descriptors, 2, 30000);
		if (result < 0) {
			if (errno == EINTR)
				continue;
			fail("poll writeback preparation");
		}
		if (!result) {
			errno = ETIMEDOUT;
			fail("writeback preparation timeout");
		}
		if (descriptors[0].revents & POLLIN)
			handle_request(test, read_request(test));
		if (descriptors[1].revents & POLLIN) {
			if (child_ready(ready_fd))
				return;
		}
	}
}

static int run_writeback(struct fuse_test *test, enum writeback_finish finish)
{
	struct fuse_in_header *header;
	struct fuse_write_in *write_in;
	struct fuse_write_out write_out;
	char file_path[PATH_MAX];
	int control[2];
	int ready[2];
	pid_t child;
	ssize_t length;

	initialize_fuse(test, false);
	if (pipe2(control, O_CLOEXEC) || pipe2(ready, O_CLOEXEC | O_NONBLOCK))
		fail("writeback pipes");

	snprintf(file_path, sizeof(file_path), "%s/file", test->mountpoint);
	child = fork();
	if (child < 0)
		fail("fork writeback child");
	if (!child) {
		close(control[1]);
		close(ready[0]);
		/*
		 * The requester does not act as a FUSE daemon.  In particular,
		 * WRITEBACK_CLOSE must let the parent's close drop the final
		 * device reference and abort the in-flight writeback.
		 */
		if (close(test->fd))
			_exit(13);
		writeback_child(file_path, ready[1], control[0],
				finish == WRITEBACK_REPLY);
	}
	close(control[0]);
	close(ready[1]);

	prepare_writeback_file(test, child, ready[0]);
	close(ready[0]);
	write_state(test, "ready", "ready\n");
	wait_for_state(test, "start");
	write_all(control[1], "S", 1);
	close(control[1]);
	write_state(test, "writeback-started", "started\n");

	for (;;) {
		length = splice_request(test);
		if (length < 0) {
			if (finish != WRITEBACK_ABORT)
				fail("splice FUSE_WRITE");
			wait_for_child(child, true);
			write_state(test, "aborted", "aborted\n");
			cleanup_fuse(test);
			return 0;
		}

		header = (void *)test->buffer;
		if ((uint32_t)length != header->len)
			fail_value("spliced request length", length, header->len);
		fprintf(stderr, "spliced FUSE opcode %u\n", header->opcode);
		fflush(stderr);
		if (header->opcode == FUSE_WRITE)
			break;
		handle_request(test, length);
	}

	if ((size_t)length < sizeof(*header) + sizeof(*write_in))
		fail("short spliced FUSE_WRITE");
	write_in = (void *)(header + 1);
	if (!(write_in->write_flags & FUSE_WRITE_CACHE)) {
		errno = EPROTO;
		fail("spliced FUSE_WRITE was not page-cache writeback");
	}
	fprintf(stderr, "spliced FUSE_WRITE size %u flags %#x\n",
		write_in->size, write_in->write_flags);
	fflush(stderr);
	write_state(test, "write-seen", "write\n");

	if (finish == WRITEBACK_CLOSE) {
		if (close(test->fd))
			fail("close last FUSE device");
		test->fd = -1;
		wait_for_child(child, true);
		write_state(test, "closed", "closed\n");
		cleanup_fuse(test);
		return 0;
	}
	if (finish == WRITEBACK_ABORT) {
		wait_for_child(child, true);
		write_state(test, "aborted", "aborted\n");
		cleanup_fuse(test);
		return 0;
	}

	write_out.size = write_in->size;
	write_out.padding = 0;
	reply_request(test, header->unique, 0, &write_out, sizeof(write_out));

	for (unsigned int attempt = 0; attempt < 300; attempt++) {
		struct pollfd descriptor = {
			.fd = test->fd,
			.events = POLLIN,
		};
		int status;
		int poll_result;
		pid_t result = waitpid(child, &status, WNOHANG);

		if (result < 0)
			fail("waitpid writeback completion");
		if (result == child) {
			if (!WIFEXITED(status) ||
			    WEXITSTATUS(status) != EXIT_SUCCESS) {
				errno = ECHILD;
				fail("writeback child failed");
			}
			write_state(test, "completed", "completed\n");
			cleanup_fuse(test);
			return 0;
		}

		poll_result = poll(&descriptor, 1, 100);
		if (poll_result < 0) {
			if (errno == EINTR)
				continue;
			fail("poll writeback completion");
		}
		if (poll_result && descriptor.revents & POLLIN)
			handle_request(test, read_request(test));
	}

	errno = ETIMEDOUT;
	fail("writeback completion timeout");
	return 1;
}

static void empty_signal_handler(int signal_number)
{
	(void)signal_number;
}

static void resend_child(const char *path, int ready_fd)
{
	struct sigaction action = {
		.sa_handler = empty_signal_handler,
	};
	struct stat statbuf;
	int result;

	sigemptyset(&action.sa_mask);
	if (sigaction(SIGUSR1, &action, NULL))
		_exit(20);
	write_all(ready_fd, "R", 1);

	errno = 0;
	result = lstat(path, &statbuf);
	if (!result || errno == 0)
		_exit(21);
	_exit(EXIT_SUCCESS);
}

static void send_resend_notification(struct fuse_test *test)
{
	struct fuse_out_header notification = {
		.len = sizeof(notification),
		.error = FUSE_NOTIFY_RESEND,
		.unique = 0,
	};

	write_all(test->fd, &notification, sizeof(notification));
}

static int request_index(const struct held_request *requests, uint64_t unique)
{
	int i;

	for (i = 0; i < RESEND_REQUESTS; i++) {
		if ((requests[i].unique | FUSE_UNIQUE_RESEND) == unique)
			return i;
	}
	errno = EPROTO;
	fail("unknown resent FUSE request");
	return -1;
}

static int read_expected_interrupt(struct fuse_test *test,
				   const struct held_request *requests,
				   bool *seen)
{
	struct fuse_in_header *header;
	struct fuse_interrupt_in *interrupt;
	int index;
	ssize_t length;

	length = read_request(test);
	header = (void *)test->buffer;
	if (header->opcode != FUSE_INTERRUPT)
		fail_value("FUSE interrupt opcode", header->opcode,
			   FUSE_INTERRUPT);
	if ((size_t)length != sizeof(*header) + sizeof(*interrupt)) {
		errno = EPROTO;
		fail("FUSE interrupt length");
	}
	interrupt = (void *)(header + 1);
	index = request_index(requests, interrupt->unique);
	if (seen[index]) {
		errno = EPROTO;
		fail("duplicate FUSE interrupt");
	}
	if (header->unique !=
	    (interrupt->unique | FUSE_INTERRUPT_UNIQUE_BIT))
		fail_value("FUSE interrupt unique", header->unique,
			   interrupt->unique | FUSE_INTERRUPT_UNIQUE_BIT);
	seen[index] = true;
	/*
	 * The original request was moved from the processing queue back to the
	 * pending queue by FUSE_NOTIFY_RESEND, so an interrupt reply cannot
	 * find it.  FUSE permits userspace to ignore interrupt notifications.
	 */
	return index;
}

static int read_and_complete_resent(struct fuse_test *test,
				    const struct held_request *requests)
{
	struct fuse_in_header *header;
	int index;
	ssize_t length;

	length = read_request(test);
	header = (void *)test->buffer;
	if ((uint32_t)length != header->len)
		fail_value("resent FUSE request length", length, header->len);
	if (header->opcode != FUSE_LOOKUP)
		fail_value("resent FUSE opcode", header->opcode, FUSE_LOOKUP);
	index = request_index(requests, header->unique);
	if (header->pid != requests[index].pid)
		fail_value("resent FUSE requester", header->pid,
			   requests[index].pid);
	reply_request(test, header->unique, -ENOENT, NULL, 0);
	return index;
}

static void abort_connection(const struct fuse_test *test)
{
	char path[PATH_MAX];
	int fd;

	snprintf(path, sizeof(path), "/sys/fs/fuse/connections/%u/abort",
		 test->connection);
	fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		fail("open FUSE abort");
	write_all(fd, "1\n", 2);
	if (close(fd))
		fail("close FUSE abort");
}

static int run_resend(struct fuse_test *test)
{
	struct held_request requests[RESEND_REQUESTS] = { 0 };
	struct fuse_in_header *header;
	bool interrupt_seen[RESEND_REQUESTS] = { false };
	char request_path[PATH_MAX];
	char state[512];
	int ready[2];
	pid_t children[RESEND_REQUESTS];
	int completed_index;
	int remaining_index = -1;
	int i;

	initialize_fuse(test, true);
	if (pipe2(ready, O_CLOEXEC))
		fail("resend readiness pipe");

	for (i = 0; i < RESEND_REQUESTS; i++) {
		pid_t child;

		snprintf(request_path, sizeof(request_path), "%s/request-%d",
			 test->mountpoint, i);
		child = fork();
		if (child < 0)
			fail("fork resend child");
		if (!child) {
			close(ready[0]);
			resend_child(request_path, ready[1]);
		}
		children[i] = child;
	}
	close(ready[1]);
	for (i = 0; i < RESEND_REQUESTS; i++) {
		char byte;

		if (read(ready[0], &byte, 1) != 1 || byte != 'R') {
			errno = EPROTO;
			fail("resend child readiness");
		}
	}
	close(ready[0]);

	for (i = 0; i < RESEND_REQUESTS; i++) {
		ssize_t length = read_request(test);

		header = (void *)test->buffer;
		if ((uint32_t)length != header->len)
			fail_value("held FUSE request length", length,
				   header->len);
		if (header->opcode != FUSE_LOOKUP)
			fail_value("held FUSE opcode", header->opcode,
				   FUSE_LOOKUP);
		requests[i].unique = header->unique;
		requests[i].pid = header->pid;
		requests[i].child = header->pid;
		for (int child_index = 0;
		     child_index < RESEND_REQUESTS; child_index++) {
			if (children[child_index] == requests[i].child)
				break;
			if (child_index == RESEND_REQUESTS - 1) {
				errno = EPROTO;
				fail("unknown FUSE requester");
			}
		}
	}

	snprintf(state, sizeof(state),
		 "%u %llu\n%u %llu\n%u %llu\n",
		 requests[0].pid,
		 (unsigned long long)requests[0].unique,
		 requests[1].pid,
		 (unsigned long long)requests[1].unique,
		 requests[2].pid,
		 (unsigned long long)requests[2].unique);
	write_state(test, "requests", state);
	write_state(test, "held", "held\n");

	wait_for_state(test, "signal");
	for (i = 0; i < RESEND_REQUESTS; i++) {
		if (kill(requests[i].child, SIGUSR1))
			fail("signal FUSE requester");
	}
	write_state(test, "signaled", "signaled\n");

	wait_for_state(test, "resend");
	send_resend_notification(test);
	write_state(test, "resent", "resent\n");

	wait_for_state(test, "fatal");
	if (kill(requests[0].child, SIGKILL))
		fail("kill fatal FUSE requester");
	wait_for_child(requests[0].child, false);
	write_state(test, "fatal-done", "fatal\n");

	wait_for_state(test, "consume");
	for (i = 0; i < RESEND_REQUESTS - 1; i++) {
		int index = read_expected_interrupt(test, requests,
						    interrupt_seen);

		if (!index) {
			errno = EPROTO;
			fail("fatal FUSE request remained interrupt-visible");
		}
	}
	completed_index = read_and_complete_resent(test, requests);
	if (!completed_index || !interrupt_seen[completed_index]) {
		errno = EPROTO;
		fail("unexpected resent FUSE completion");
	}
	wait_for_child(requests[completed_index].child, true);
	for (i = 1; i < RESEND_REQUESTS; i++) {
		if (i != completed_index)
			remaining_index = i;
	}
	if (remaining_index < 0) {
		errno = EPROTO;
		fail("no FUSE request remained for abort");
	}
	write_state(test, "consume-done", "consumed\n");

	wait_for_state(test, "abort");
	abort_connection(test);
	wait_for_child(requests[remaining_index].child, true);
	write_state(test, "abort-done", "aborted\n");

	cleanup_fuse(test);
	return 0;
}

int main(int argc, char **argv)
{
	struct fuse_test test = {
		.fd = -1,
	};
	enum writeback_finish finish;

	if (argc < 4 || argc > 5) {
		fprintf(stderr,
			"usage: %s <writeback|resend> <mountpoint> <state-dir> "
			"[reply|abort|close]\n",
			argv[0]);
		return 64;
	}

	test.mountpoint = argv[2];
	test.state_dir = argv[3];
	test.buffer = malloc(REQUEST_BUFFER_SIZE);
	if (!test.buffer)
		fail("allocate FUSE request buffer");
	if (mkdir(test.state_dir, 0700) && errno != EEXIST)
		fail("mkdir FUSE state directory");

	if (!strcmp(argv[1], "resend")) {
		if (argc != 4)
			return 64;
		return run_resend(&test);
	}
	if (strcmp(argv[1], "writeback") || argc != 5)
		return 64;

	if (!strcmp(argv[4], "reply"))
		finish = WRITEBACK_REPLY;
	else if (!strcmp(argv[4], "abort"))
		finish = WRITEBACK_ABORT;
	else if (!strcmp(argv[4], "close"))
		finish = WRITEBACK_CLOSE;
	else
		return 64;

	return run_writeback(&test, finish);
}
