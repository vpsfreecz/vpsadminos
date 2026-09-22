// SPDX-License-Identifier: GPL-2.0-only
/*
 * Hostile-transaction driver for the SCTP retransmission-path acceptance test.
 *
 * Creates a loopback SCTP association, announces it, waits while the test
 * probe arms the server-side association (every transport SCTP_UNCONFIRMED,
 * retran_path on the tail transport), then removes the extra client address so
 * the peer's DEL-IP processing runs sctp_assoc_rm_peer() on the armed
 * retransmission path.  With the defective scan that call never returns; with
 * the corrected body it terminates.
 *
 * Phases are ordered through marker files in the state directory:
 *   writes: assoc, add-sent, rem-sent, health-ok/health-failed, done
 *   waits:  add, arm, release
 */
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/sctp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define WAIT_TIMEOUT_SECONDS 600

static const char *state_dir;

static void fail(const char *operation)
{
	perror(operation);
	exit(EXIT_FAILURE);
}

static void marker_path(char *buffer, size_t size, const char *name)
{
	int written = snprintf(buffer, size, "%s/%s", state_dir, name);

	if (written < 0 || (size_t)written >= size) {
		fprintf(stderr, "marker path too long: %s/%s\n", state_dir, name);
		exit(EXIT_FAILURE);
	}
}

static void write_marker(const char *name)
{
	char path[512];
	int fd;

	marker_path(path, sizeof(path), name);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		fail("open marker");
	if (close(fd))
		fail("close marker");
}

static void wait_for_marker(const char *name)
{
	char path[512];
	struct stat statbuf;
	time_t deadline = time(NULL) + WAIT_TIMEOUT_SECONDS;

	marker_path(path, sizeof(path), name);
	while (stat(path, &statbuf)) {
		if (errno != ENOENT)
			fail("stat marker");
		if (time(NULL) > deadline) {
			fprintf(stderr, "timed out waiting for marker %s\n", name);
			exit(EXIT_FAILURE);
		}
		usleep(20000);
	}
}

/*
 * Confirm the association's primary path before asking for an Add-IP: a queued
 * ASCONF is only put on the wire once the association/transport is in a
 * sendable, established state, so without prior data flow the Add-IP ASCONF
 * can sit in the outqueue indefinitely (observed on the base kernel too).
 */
static void confirm_path(int client_fd, int accepted)
{
	struct pollfd pfd = {
		.fd = accepted,
		.events = POLLIN,
	};
	char sent = 'x';
	char received = 0;

	if (send(client_fd, &sent, 1, 0) != 1)
		fail("confirm send");
	if (poll(&pfd, 1, 5000) != 1)
		fail("confirm poll");
	if (recv(accepted, &received, 1, 0) != 1 || received != sent)
		fail("confirm recv");
}

static void exchange_health(int client_fd, int accepted)
{
	struct pollfd pfd = {
		.fd = accepted,
		.events = POLLIN,
	};
	char sent = 'x';
	char received = 0;

	if (send(client_fd, &sent, 1, 0) != 1) {
		write_marker("health-failed");
		return;
	}
	if (poll(&pfd, 1, 5000) == 1 && recv(accepted, &received, 1, 0) == 1 &&
	    received == sent)
		write_marker("health-ok");
	else
		write_marker("health-failed");
}

int main(int argc, char **argv)
{
	struct sockaddr_in server = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	struct sockaddr_in client = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	struct sockaddr_in extra = {
		.sin_family = AF_INET,
	};
	socklen_t address_len;
	int accepted;
	int client_fd;
	int server_fd;

	if (argc != 2) {
		fprintf(stderr, "usage: %s STATE_DIR\n", argv[0]);
		return 2;
	}
	state_dir = argv[1];

	if (inet_pton(AF_INET, "127.0.0.2", &extra.sin_addr) != 1)
		fail("inet_pton");

	server_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP);
	if (server_fd < 0)
		fail("socket(SCTP server)");
	if (bind(server_fd, (struct sockaddr *)&server, sizeof(server)))
		fail("bind(SCTP server)");
	address_len = sizeof(server);
	if (getsockname(server_fd, (struct sockaddr *)&server, &address_len))
		fail("getsockname(SCTP server)");
	if (listen(server_fd, 1))
		fail("listen(SCTP)");

	client_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP);
	if (client_fd < 0)
		fail("socket(SCTP client)");
	if (bind(client_fd, (struct sockaddr *)&client, sizeof(client)))
		fail("bind(SCTP client)");
	address_len = sizeof(client);
	if (getsockname(client_fd, (struct sockaddr *)&client, &address_len))
		fail("getsockname(SCTP client)");
	if (connect(client_fd, (struct sockaddr *)&server, sizeof(server)))
		fail("connect(SCTP)");
	accepted = accept(server_fd, NULL, NULL);
	if (accepted < 0)
		fail("accept(SCTP)");

	write_marker("assoc");

	wait_for_marker("add");
	confirm_path(client_fd, accepted);
	extra.sin_port = client.sin_port;
	if (sctp_bindx(client_fd, (struct sockaddr *)&extra, 1,
		       SCTP_BINDX_ADD_ADDR))
		fail("sctp_bindx(add)");
	/* Give the stack a transmit trigger so the queued ASCONF goes out. */
	if (send(client_fd, "x", 1, 0) != 1)
		fail("add flush");
	write_marker("add-sent");

	wait_for_marker("arm");
	if (sctp_bindx(client_fd, (struct sockaddr *)&extra, 1,
		       SCTP_BINDX_REM_ADDR))
		fail("sctp_bindx(remove)");
	write_marker("rem-sent");

	exchange_health(client_fd, accepted);

	write_marker("done");
	wait_for_marker("release");

	close(accepted);
	close(client_fd);
	close(server_fd);
	return 0;
}
