// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <liburing.h>
#include <linux/errqueue.h>
#include <linux/vm_sockets.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define LEGACY_BYTES (256U * 1024U)

struct server_context {
	pthread_cond_t condition;
	pthread_mutex_t mutex;
	const char *release_path;
	size_t expected;
	size_t received;
	unsigned int port;
	bool ready;
};

static void fail(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(EXIT_FAILURE);
}

static void fail_value(const char *what, long actual, long expected)
{
	fprintf(stderr, "%s: got %ld, expected %ld\n",
		what, actual, expected);
	exit(EXIT_FAILURE);
}

static void write_value(const char *path, const char *value)
{
	size_t length = strlen(value);
	ssize_t written;
	int fd;

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		fail("open state file");
	written = write(fd, value, length);
	if (written < 0 || (size_t)written != length)
		fail("write state file");
	if (close(fd))
		fail("close state file");
}

static void wait_for_path(const char *path)
{
	struct stat statbuf;

	while (stat(path, &statbuf)) {
		if (errno != ENOENT)
			fail("stat release file");
		usleep(1000);
	}
}

static int create_vsock(void)
{
	int fd;
	int size = 2 * 1024 * 1024;

	fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		fail("socket");
	if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)))
		fail("SO_SNDBUF");
	if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)))
		fail("SO_RCVBUF");
	return fd;
}

static void *server_thread(void *opaque)
{
	struct server_context *context = opaque;
	struct sockaddr_vm address = {
		.svm_family = AF_VSOCK,
		.svm_cid = VMADDR_CID_ANY,
		.svm_port = context->port,
	};
	char buffer[64 * 1024];
	int accepted;
	int listener;

	listener = create_vsock();
	if (bind(listener, (struct sockaddr *)&address, sizeof(address)))
		fail("bind");
	if (listen(listener, 1))
		fail("listen");

	if (pthread_mutex_lock(&context->mutex))
		fail("pthread_mutex_lock");
	context->ready = true;
	if (pthread_cond_signal(&context->condition))
		fail("pthread_cond_signal");
	if (pthread_mutex_unlock(&context->mutex))
		fail("pthread_mutex_unlock");

	accepted = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
	if (accepted < 0)
		fail("accept4");
	wait_for_path(context->release_path);

	while (context->received < context->expected) {
		size_t remaining = context->expected - context->received;
		ssize_t length;

		if (remaining > sizeof(buffer))
			remaining = sizeof(buffer);
		length = recv(accepted, buffer, remaining, 0);
		if (length < 0) {
			if (errno == EINTR)
				continue;
			fail("recv");
		}
		if (!length)
			fail_value("early vsock EOF", context->received,
				   context->expected);
		context->received += length;
	}

	if (close(accepted))
		fail("close accepted socket");
	if (close(listener))
		fail("close listener");
	return NULL;
}

static void wait_for_primary_cqe(struct io_uring *ring, size_t expected)
{
	struct io_uring_cqe *cqe;
	int flags;
	int result;
	int ret;

	ret = io_uring_wait_cqe(ring, &cqe);
	if (ret) {
		errno = -ret;
		fail("io_uring_wait_cqe");
	}
	result = cqe->res;
	flags = cqe->flags;
	io_uring_cqe_seen(ring, cqe);

	if (result != (int)expected)
		fail_value("fixed-buffer send", result, expected);
	if (!(flags & IORING_CQE_F_MORE))
		fail_value("missing zerocopy notification", flags,
			   IORING_CQE_F_MORE);
}

static void wait_for_notification(struct io_uring *ring)
{
	struct io_uring_cqe *cqe;
	int ret;

	ret = io_uring_wait_cqe(ring, &cqe);
	if (ret) {
		errno = -ret;
		fail("io_uring_wait_cqe notification");
	}
	if (!(cqe->flags & IORING_CQE_F_NOTIF))
		fail_value("zerocopy completion flags", cqe->flags,
			   IORING_CQE_F_NOTIF);
	if (cqe->res)
		fail_value("zerocopy completion result", cqe->res, 0);
	io_uring_cqe_seen(ring, cqe);
}

static void wait_for_server(struct server_context *context)
{
	if (pthread_mutex_lock(&context->mutex))
		fail("pthread_mutex_lock");
	while (!context->ready) {
		if (pthread_cond_wait(&context->condition, &context->mutex))
			fail("pthread_cond_wait");
	}
	if (pthread_mutex_unlock(&context->mutex))
		fail("pthread_mutex_unlock");
}

static int connect_client(unsigned int port)
{
	struct sockaddr_vm address = {
		.svm_family = AF_VSOCK,
		.svm_cid = VMADDR_CID_LOCAL,
		.svm_port = port,
	};
	int enabled = 1;
	int fd;

	fd = create_vsock();
	if (setsockopt(fd, SOL_SOCKET, SO_ZEROCOPY, &enabled,
		       sizeof(enabled)))
		fail("SO_ZEROCOPY");
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)))
		fail("connect");
	return fd;
}

static void run_send(unsigned int port, const char *ready_path,
		     const char *release_path, const char *result_path)
{
	struct server_context context = {
		.condition = PTHREAD_COND_INITIALIZER,
		.mutex = PTHREAD_MUTEX_INITIALIZER,
		.release_path = release_path,
		.expected = LEGACY_BYTES,
		.port = port,
	};
	struct io_uring_sqe *sqe;
	struct io_uring ring;
	struct iovec iovec;
	pthread_t thread;
	long page_size;
	void *buffer;
	char result[64];
	int fd;
	int ret;

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0)
		fail("sysconf");
	ret = posix_memalign(&buffer, page_size, LEGACY_BYTES);
	if (ret) {
		errno = ret;
		fail("posix_memalign");
	}
	memset(buffer, 0x5a, LEGACY_BYTES);

	if (pthread_create(&thread, NULL, server_thread, &context)) {
		errno = EAGAIN;
		fail("pthread_create");
	}
	wait_for_server(&context);
	fd = connect_client(port);

	ret = io_uring_queue_init(8, &ring, 0);
	if (ret) {
		errno = -ret;
		fail("io_uring_queue_init");
	}
	iovec.iov_base = buffer;
	iovec.iov_len = LEGACY_BYTES;
	ret = io_uring_register_buffers(&ring, &iovec, 1);
	if (ret) {
		errno = -ret;
		fail("io_uring_register_buffers");
	}

	sqe = io_uring_get_sqe(&ring);
	if (!sqe) {
		errno = ENOSPC;
		fail("io_uring_get_sqe");
	}
	io_uring_prep_send_zc_fixed(sqe, fd, buffer, LEGACY_BYTES,
				    MSG_NOSIGNAL, 0, 0);
	ret = io_uring_submit(&ring);
	if (ret != 1)
		fail_value("io_uring_submit", ret, 1);

	wait_for_primary_cqe(&ring, LEGACY_BYTES);
	write_value(ready_path, "ready\n");
	wait_for_path(release_path);
	wait_for_notification(&ring);

	ret = io_uring_unregister_buffers(&ring);
	if (ret) {
		errno = -ret;
		fail("io_uring_unregister_buffers");
	}
	io_uring_queue_exit(&ring);
	if (shutdown(fd, SHUT_RDWR) && errno != ENOTCONN)
		fail("shutdown");
	if (close(fd))
		fail("close client socket");
	if (pthread_join(thread, NULL)) {
		errno = EINVAL;
		fail("pthread_join");
	}

	if (context.received != context.expected)
		fail_value("received byte count", context.received,
			   context.expected);
	snprintf(result, sizeof(result), "%zu\n", context.received);
	write_value(result_path, result);
	free(buffer);
}

int main(int argc, char **argv)
{
	char *end;
	unsigned long port;

	if (argc != 5) {
		fprintf(stderr,
			"usage: %s <port> <ready> <release> <result>\n",
			argv[0]);
		return 64;
	}

	errno = 0;
	port = strtoul(argv[1], &end, 10);
	if (errno || *end || !port || port > UINT32_MAX) {
		fprintf(stderr, "invalid port: %s\n", argv[1]);
		return 64;
	}

	run_send(port, argv[2], argv[3], argv[4]);
	return 0;
}
