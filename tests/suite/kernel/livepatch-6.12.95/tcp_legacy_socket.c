// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define SEND_BYTES (8U * 1024U * 1024U)

static void fail(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(EXIT_FAILURE);
}

static void write_value(const char *path, const char *value)
{
	int fd;
	ssize_t written;
	size_t length = strlen(value);

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		fail("open state file");
	written = write(fd, value, length);
	if (written < 0 || (size_t)written != length)
		fail("write state file");
	if (close(fd))
		fail("close state file");
}

static void wait_for_release(const char *path)
{
	struct stat statbuf;

	while (stat(path, &statbuf)) {
		if (errno != ENOENT)
			fail("stat release file");
		usleep(1000);
	}
}

int main(int argc, char **argv)
{
	struct sockaddr_in address = {
		.sin_family = AF_INET,
	};
	char buffer[64 * 1024] = { 0 };
	char result[64];
	size_t sent = 0;
	int fd;
	int port;

	if (argc != 6) {
		fprintf(stderr,
			"usage: %s <address> <port> <ready> <release> <result>\n",
			argv[0]);
		return 64;
	}

	errno = 0;
	port = strtol(argv[2], NULL, 10);
	if (errno || port <= 0 || port > 65535) {
		fprintf(stderr, "invalid port: %s\n", argv[2]);
		return 64;
	}
	address.sin_port = htons(port);
	if (inet_pton(AF_INET, argv[1], &address.sin_addr) != 1) {
		fprintf(stderr, "invalid address: %s\n", argv[1]);
		return 64;
	}

	signal(SIGPIPE, SIG_IGN);
	fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		fail("socket");
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)))
		fail("connect");

	write_value(argv[3], "ready\n");
	wait_for_release(argv[4]);

	while (sent < SEND_BYTES) {
		size_t remaining = SEND_BYTES - sent;
		ssize_t length;

		if (remaining > sizeof(buffer))
			remaining = sizeof(buffer);
		length = send(fd, buffer, remaining, MSG_NOSIGNAL);
		if (length < 0) {
			if (errno == EINTR)
				continue;
			fail("send");
		}
		sent += length;
	}
	if (shutdown(fd, SHUT_WR))
		fail("shutdown");
	if (close(fd))
		fail("close socket");

	snprintf(result, sizeof(result), "%zu\n", sent);
	write_value(argv[5], result);
	return 0;
}
