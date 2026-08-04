#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/if_pppol2tp.h>
#include <linux/if_pppox.h>
#include <netinet/in.h>
#include <netinet/sctp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *operation)
{
	perror(operation);
	exit(EXIT_FAILURE);
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

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s cpu-timer|packet-ring|pppol2tp|sctp-asconf\n",
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
	else {
		fprintf(stderr, "unknown operation: %s\n", argv[1]);
		return EXIT_FAILURE;
	}

	return EXIT_SUCCESS;
}
