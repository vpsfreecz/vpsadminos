// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netfilter.h>
#include <linux/netfilter/nfnetlink_queue.h>
#include <libnetfilter_queue/libnetfilter_queue.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

struct hold_state {
	const char *ready_path;
	const char *release_path;
	bool saw_gso;
};

static void fail(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(EXIT_FAILURE);
}

static void write_ready(const struct hold_state *state)
{
	char value[32];
	int fd;
	int len;

	fd = open(state->ready_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		fail("open ready file");

	len = snprintf(value, sizeof(value), "gso=%u\n", state->saw_gso);
	if (write(fd, value, len) != len)
		fail("write ready file");
	if (close(fd))
		fail("close ready file");
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

static int queue_callback(struct nfq_q_handle *queue,
			  struct nfgenmsg *message,
			  struct nfq_data *packet,
			  void *opaque)
{
	struct hold_state *state = opaque;
	struct nfqnl_msg_packet_hdr *header;
	unsigned int id;
	int ret;

	(void)message;
	header = nfq_get_msg_packet_hdr(packet);
	if (!header) {
		errno = EPROTO;
		fail("packet header");
	}
	id = ntohl(header->packet_id);
	state->saw_gso = nfq_get_skbinfo(packet) & NFQA_SKB_GSO;
	write_ready(state);
	wait_for_release(state->release_path);

	ret = nfq_set_verdict(queue, id, NF_ACCEPT, 0, NULL);
	if (ret < 0 && errno != ENOENT && errno != ESRCH)
		fail("set verdict");

	return 1;
}

static int parse_uint(const char *value, unsigned int maximum,
		      const char *description)
{
	char *end;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 0);
	if (errno || *end || parsed > maximum) {
		fprintf(stderr, "invalid %s: %s\n", description, value);
		exit(EXIT_FAILURE);
	}

	return parsed;
}

int main(int argc, char **argv)
{
	struct hold_state state;
	struct nfq_handle *handle;
	struct nfq_q_handle *queue;
	char buffer[128 * 1024];
	unsigned int family;
	unsigned int queue_number;
	unsigned int flags;
	int fd;
	int len;
	int ret;

	if (argc != 5) {
		fprintf(stderr,
			"usage: %s <4|6> <queue> <ready-file> <release-file>\n",
			argv[0]);
		return 64;
	}

	family = parse_uint(argv[1], 6, "address family");
	if (family != 4 && family != 6) {
		fprintf(stderr, "address family must be 4 or 6\n");
		return 64;
	}
	queue_number = parse_uint(argv[2], UINT16_MAX, "queue number");
	state.ready_path = argv[3];
	state.release_path = argv[4];
	state.saw_gso = false;

	handle = nfq_open();
	if (!handle)
		fail("nfq_open");

	queue = nfq_create_queue(handle, queue_number, queue_callback, &state);
	if (!queue)
		fail("nfq_create_queue");
	if (nfq_set_mode(queue, NFQNL_COPY_PACKET, 0xffff) < 0)
		fail("nfq_set_mode");
	flags = NFQA_CFG_F_GSO | NFQA_CFG_F_UID_GID;
	if (nfq_set_queue_flags(queue, flags, flags) < 0)
		fail("nfq_set_queue_flags");

	fd = nfq_fd(handle);
	for (;;) {
		len = recv(fd, buffer, sizeof(buffer), 0);
		if (len < 0) {
			if (errno == EINTR)
				continue;
			fail("recv");
		}

		ret = nfq_handle_packet(handle, buffer, len);
		if (ret < 0)
			fail("nfq_handle_packet");
		if (ret > 0)
			break;
	}

	nfq_destroy_queue(queue);
	nfq_close(handle);
	return 0;
}
