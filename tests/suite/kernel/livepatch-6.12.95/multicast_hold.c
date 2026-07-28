// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static void fail(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(EXIT_FAILURE);
}

static void write_ready(const char *path)
{
	int fd;

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		fail("open ready file");
	if (write(fd, "ready\n", 6) != 6)
		fail("write ready file");
	if (close(fd))
		fail("close ready file");
}

static void wait_for_stop(const char *path)
{
	struct stat statbuf;

	while (stat(path, &statbuf)) {
		if (errno != ENOENT)
			fail("stat stop file");
		usleep(1000);
	}
}

int main(int argc, char **argv)
{
	struct ipv6_mreq membership6 = { 0 };
	struct ip_mreqn membership4 = { 0 };
	char group4[INET_ADDRSTRLEN];
	char group6[INET6_ADDRSTRLEN];
	unsigned int ifindex;
	unsigned long group;
	char *end;
	int socket4;
	int socket6;

	if (argc != 5) {
		fprintf(stderr,
			"usage: %s <interface> <group-id> <ready> <stop>\n",
			argv[0]);
		return 64;
	}

	errno = 0;
	group = strtoul(argv[2], &end, 0);
	if (errno || *end || !group || group > 65535) {
		fprintf(stderr, "invalid group id: %s\n", argv[2]);
		return 64;
	}
	ifindex = if_nametoindex(argv[1]);
	if (!ifindex)
		fail("if_nametoindex");

	snprintf(group4, sizeof(group4), "239.1.%lu.%lu",
		 group / 256, group % 256);
	snprintf(group6, sizeof(group6), "ff02::%lx", group);
	if (inet_pton(AF_INET, group4, &membership4.imr_multiaddr) != 1 ||
	    inet_pton(AF_INET6, group6, &membership6.ipv6mr_multiaddr) != 1) {
		errno = EINVAL;
		fail("parse multicast group");
	}
	membership4.imr_ifindex = ifindex;
	membership6.ipv6mr_interface = ifindex;

	socket4 = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (socket4 < 0)
		fail("IPv4 socket");
	socket6 = socket(AF_INET6, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (socket6 < 0)
		fail("IPv6 socket");
	if (setsockopt(socket4, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership4,
		       sizeof(membership4)))
		fail("IPv4 membership");
	if (setsockopt(socket6, IPPROTO_IPV6, IPV6_JOIN_GROUP, &membership6,
		       sizeof(membership6)))
		fail("IPv6 membership");

	write_ready(argv[3]);
	wait_for_stop(argv[4]);

	if (close(socket6) || close(socket4))
		fail("close socket");
	return 0;
}
