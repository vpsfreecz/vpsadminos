// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define PROGRAM_INSNS 64

static void fail(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(EXIT_FAILURE);
}

static void write_count(const char *path, unsigned long long count)
{
	char value[32];
	int fd;
	int len;

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		fail("open progress file");

	len = snprintf(value, sizeof(value), "%llu\n", count);
	if (write(fd, value, len) != len)
		fail("write progress file");
	if (close(fd))
		fail("close progress file");
}

static void run_filter(unsigned int seed)
{
	struct sock_filter instructions[PROGRAM_INSNS];
	struct sock_fprog program = {
		.len = PROGRAM_INSNS,
		.filter = instructions,
	};
	char byte = 'x';
	int sockets[2];
	int i;

	for (i = 0; i < PROGRAM_INSNS - 1; i++)
		instructions[i] = (struct sock_filter)
			BPF_STMT(BPF_LD | BPF_IMM, seed + i);
	instructions[PROGRAM_INSNS - 1] = (struct sock_filter)
		BPF_STMT(BPF_RET | BPF_K, ~0U);

	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0, sockets))
		fail("socketpair");
	if (setsockopt(sockets[0], SOL_SOCKET, SO_ATTACH_FILTER, &program,
		       sizeof(program)))
		fail("SO_ATTACH_FILTER");
	if (send(sockets[1], &byte, sizeof(byte), 0) != sizeof(byte))
		fail("send");
	if (recv(sockets[0], &byte, sizeof(byte), 0) != sizeof(byte))
		fail("recv");
	if (close(sockets[0]) || close(sockets[1]))
		fail("close socket");
}

int main(int argc, char **argv)
{
	const char *progress_path;
	const char *stop_path;
	unsigned long long count = 0;

	if (argc != 3) {
		fprintf(stderr, "usage: %s <progress-file> <stop-file>\n",
			argv[0]);
		return 64;
	}

	progress_path = argv[1];
	stop_path = argv[2];
	while (access(stop_path, F_OK)) {
		if (errno != ENOENT)
			fail("access stop file");
		run_filter(count);
		count++;
		if (!(count % 128))
			write_count(progress_path, count);
	}
	write_count(progress_path, count);
	return 0;
}
