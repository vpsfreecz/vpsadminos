#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/if_pppol2tp.h>
#include <linux/if_pppox.h>
#include <linux/ip.h>
#include <linux/sctp.h>
#include <netinet/in.h>
#include <netinet/sctp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *operation)
{
	perror(operation);
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

static void wait_for_file(const char *path)
{
	struct stat statbuf;

	while (stat(path, &statbuf)) {
		if (errno != ENOENT)
			fail("stat release file");
		usleep(1000);
	}
}

static void exercise_cpu_timer(void)
{
	struct sigevent event = {
		.sigev_notify = SIGEV_NONE,
	};
	struct itimerspec value = {
		.it_value.tv_sec = 1,
	};
	timer_t timer;

	if (timer_create(CLOCK_PROCESS_CPUTIME_ID, &event, &timer))
		fail("timer_create");
	if (timer_settime(timer, 0, &value, NULL))
		fail("timer_settime");
	if (timer_delete(timer))
		fail("timer_delete");
}

static void exercise_packet_ring(void)
{
	struct tpacket_req request = {
		.tp_block_size = 4096,
		.tp_block_nr = 1,
		.tp_frame_size = 2048,
		.tp_frame_nr = 2,
	};
	struct tpacket_req empty = { 0 };
	int version = TPACKET_V1;
	int fd;

	fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (fd < 0)
		fail("socket(AF_PACKET)");
	if (setsockopt(fd, SOL_PACKET, PACKET_VERSION, &version,
		       sizeof(version)))
		fail("setsockopt(PACKET_VERSION)");
	if (setsockopt(fd, SOL_PACKET, PACKET_RX_RING, &request,
		       sizeof(request)))
		fail("setsockopt(PACKET_RX_RING)");
	if (setsockopt(fd, SOL_PACKET, PACKET_RX_RING, &empty, sizeof(empty)))
		fail("setsockopt(PACKET_RX_RING teardown)");
	close(fd);
}

static void exercise_pppol2tp(void)
{
	struct sockaddr_in tunnel = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	struct sockaddr_pppol2tp control = {
		.sa_family = AF_PPPOX,
		.sa_protocol = PX_PROTO_OL2TP,
	};
	struct sockaddr_pppol2tp session = {
		.sa_family = AF_PPPOX,
		.sa_protocol = PX_PROTO_OL2TP,
	};
	socklen_t tunnel_len = sizeof(tunnel);
	int control_pppox;
	int pppox;
	int udp;

	udp = socket(AF_INET, SOCK_DGRAM, 0);
	if (udp < 0)
		fail("socket(UDP)");
	if (bind(udp, (struct sockaddr *)&tunnel, sizeof(tunnel)))
		fail("bind(UDP)");
	if (getsockname(udp, (struct sockaddr *)&tunnel, &tunnel_len))
		fail("getsockname(UDP)");
	if (connect(udp, (struct sockaddr *)&tunnel, sizeof(tunnel)))
		fail("connect(UDP)");

	control_pppox = socket(AF_PPPOX, SOCK_DGRAM, PX_PROTO_OL2TP);
	if (control_pppox < 0)
		fail("socket(PPPoL2TP control)");
	control.pppol2tp.fd = udp;
	control.pppol2tp.addr = tunnel;
	control.pppol2tp.s_tunnel = 1;
	control.pppol2tp.d_tunnel = 2;
	if (connect(control_pppox, (struct sockaddr *)&control,
		    sizeof(control)))
		fail("connect(PPPoL2TP control)");

	pppox = socket(AF_PPPOX, SOCK_DGRAM, PX_PROTO_OL2TP);
	if (pppox < 0)
		fail("socket(PPPoL2TP)");
	session.pppol2tp.fd = udp;
	session.pppol2tp.addr = tunnel;
	session.pppol2tp.s_tunnel = 1;
	session.pppol2tp.s_session = 1;
	session.pppol2tp.d_tunnel = 2;
	session.pppol2tp.d_session = 2;
	if (connect(pppox, (struct sockaddr *)&session, sizeof(session)))
		fail("connect(PPPoL2TP)");

	close(pppox);
	close(control_pppox);
	close(udp);
}

static void exercise_sctp_asconf(void)
{
	struct sockaddr_in server = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	struct sockaddr_in client = server;
	struct sockaddr_in extra = {
		.sin_family = AF_INET,
	};
	socklen_t address_len = sizeof(server);
	int accepted;
	int client_fd;
	int server_fd;

	if (inet_pton(AF_INET, "127.0.0.2", &extra.sin_addr) != 1)
		fail("inet_pton");
	server_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP);
	if (server_fd < 0)
		fail("socket(SCTP server)");
	if (bind(server_fd, (struct sockaddr *)&server, sizeof(server)))
		fail("bind(SCTP server)");
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

	extra.sin_port = client.sin_port;
	if (sctp_bindx(client_fd, (struct sockaddr *)&extra, 1,
		       SCTP_BINDX_ADD_ADDR))
		fail("sctp_bindx(add)");
	usleep(100000);
	if (sctp_bindx(client_fd, (struct sockaddr *)&extra, 1,
		       SCTP_BINDX_REM_ADDR))
		fail("sctp_bindx(remove)");
	usleep(100000);

	close(accepted);
	close(client_fd);
	close(server_fd);
}

static void hold_sctp_association(const char *ready, const char *release)
{
	struct sockaddr_in server = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	socklen_t address_len = sizeof(server);
	int accepted;
	int client_fd;
	int server_fd;

	server_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP);
	if (server_fd < 0)
		fail("socket(SCTP hold server)");
	if (bind(server_fd, (struct sockaddr *)&server, sizeof(server)))
		fail("bind(SCTP hold server)");
	if (getsockname(server_fd, (struct sockaddr *)&server, &address_len))
		fail("getsockname(SCTP hold server)");
	if (listen(server_fd, 1))
		fail("listen(SCTP hold server)");

	client_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP);
	if (client_fd < 0)
		fail("socket(SCTP hold client)");
	if (connect(client_fd, (struct sockaddr *)&server, sizeof(server)))
		fail("connect(SCTP hold client)");
	accepted = accept(server_fd, NULL, NULL);
	if (accepted < 0)
		fail("accept(SCTP hold)");

	write_ready(ready);
	wait_for_file(release);

	close(accepted);
	close(client_fd);
	close(server_fd);
}

static uint32_t sctp_crc32c(const void *data, size_t length)
{
	const unsigned char *bytes = data;
	uint32_t crc = ~0U;
	size_t i;

	for (i = 0; i < length; i++) {
		unsigned int bit;

		crc ^= bytes[i];
		for (bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0x82f63b78U &
						-(int32_t)(crc & 1));
	}
	return ~crc;
}

struct test_sctp_common_header {
	uint16_t source;
	uint16_t dest;
	uint32_t vtag;
	uint32_t checksum;
} __attribute__((packed));

struct test_sctp_chunk_header {
	uint8_t type;
	uint8_t flags;
	uint16_t length;
} __attribute__((packed));

struct test_sctp_init_header {
	uint32_t init_tag;
	uint32_t a_rwnd;
	uint16_t num_outbound_streams;
	uint16_t num_inbound_streams;
	uint32_t initial_tsn;
} __attribute__((packed));

struct test_sctp_parameter_header {
	uint16_t type;
	uint16_t length;
} __attribute__((packed));

struct malformed_adaptation_init {
	struct test_sctp_common_header common;
	struct test_sctp_chunk_header chunk;
	struct test_sctp_init_header init;
	struct test_sctp_parameter_header adaptation;
} __attribute__((packed));

static void exercise_sctp_malformed_adaptation(void)
{
	struct malformed_adaptation_init packet = { 0 };
	struct sockaddr_in server = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	struct pollfd pollfd;
	socklen_t address_len = sizeof(server);
	unsigned char response[2048];
	int raw_fd;
	int server_fd;
	int source_fd;
	int saw_abort = 0;

	server_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP);
	if (server_fd < 0)
		fail("socket(SCTP malformed server)");
	if (bind(server_fd, (struct sockaddr *)&server, sizeof(server)))
		fail("bind(SCTP malformed server)");
	if (getsockname(server_fd, (struct sockaddr *)&server, &address_len))
		fail("getsockname(SCTP malformed server)");
	if (listen(server_fd, 1))
		fail("listen(SCTP malformed server)");

	source_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP);
	if (source_fd < 0)
		fail("socket(SCTP malformed source)");
	{
		struct sockaddr_in source = {
			.sin_family = AF_INET,
			.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
		};

		if (bind(source_fd, (struct sockaddr *)&source, sizeof(source)))
			fail("bind(SCTP malformed source)");
		address_len = sizeof(source);
		if (getsockname(source_fd, (struct sockaddr *)&source,
				&address_len))
			fail("getsockname(SCTP malformed source)");
		packet.common.source = source.sin_port;
	}

	raw_fd = socket(AF_INET, SOCK_RAW, IPPROTO_SCTP);
	if (raw_fd < 0)
		fail("socket(raw SCTP)");
	packet.common.dest = server.sin_port;
	packet.common.vtag = 0;
	packet.chunk.type = 1; /* INIT */
	packet.chunk.length = htons(sizeof(packet.chunk) +
					    sizeof(packet.init) +
					    sizeof(packet.adaptation));
	packet.init.init_tag = htonl(0x5a5a1234);
	packet.init.a_rwnd = htonl(65535);
	packet.init.num_outbound_streams = htons(1);
	packet.init.num_inbound_streams = htons(1);
	packet.init.initial_tsn = htonl(1);
	packet.adaptation.type = htons(0xc006); /* Adaptation Layer Indication */
	packet.adaptation.length = htons(sizeof(packet.adaptation));
	packet.common.checksum = sctp_crc32c(&packet, sizeof(packet));

	if (sendto(raw_fd, &packet, sizeof(packet), 0,
		   (struct sockaddr *)&server, sizeof(server)) != sizeof(packet))
		fail("sendto(raw SCTP malformed INIT)");

	pollfd.fd = raw_fd;
	pollfd.events = POLLIN;
	while (poll(&pollfd, 1, 1000) > 0) {
		struct test_sctp_common_header *common;
		struct test_sctp_chunk_header *chunk;
		ssize_t length;

		length = recv(raw_fd, response, sizeof(response), 0);
		if (length < (ssize_t)(sizeof(struct iphdr) +
					     sizeof(*common) + sizeof(*chunk)))
			continue;
		common = (struct test_sctp_common_header *)(response +
						 ((struct iphdr *)response)->ihl * 4);
		if (common->source != server.sin_port ||
		    common->dest != packet.common.source)
			continue;
		chunk = (struct test_sctp_chunk_header *)(common + 1);
		if (chunk->type == 2) { /* INIT ACK */
			errno = EPROTO;
			fail("malformed SCTP INIT unexpectedly acknowledged");
		}
		if (chunk->type == 6) { /* ABORT */
			saw_abort = 1;
			break;
		}
	}
	if (!saw_abort) {
		errno = ETIMEDOUT;
		fail("malformed SCTP INIT abort");
	}

	close(raw_fd);
	close(source_fd);
	close(server_fd);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s OPERATION [ARGS...]\n",
			argv[0]);
		return EXIT_FAILURE;
	}

	if (!strcmp(argv[1], "cpu-timer"))
		exercise_cpu_timer();
	else if (!strcmp(argv[1], "packet-ring"))
		exercise_packet_ring();
	else if (!strcmp(argv[1], "pppol2tp"))
		exercise_pppol2tp();
	else if (!strcmp(argv[1], "sctp-asconf"))
		exercise_sctp_asconf();
	else if (!strcmp(argv[1], "sctp-hold") && argc == 4)
		hold_sctp_association(argv[2], argv[3]);
	else if (!strcmp(argv[1], "sctp-malformed-adaptation") && argc == 2)
		exercise_sctp_malformed_adaptation();
	else {
		fprintf(stderr, "unknown operation: %s\n", argv[1]);
		return EXIT_FAILURE;
	}

	return EXIT_SUCCESS;
}
