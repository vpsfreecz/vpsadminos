// SPDX-License-Identifier: GPL-2.0

#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <linux/if_packet.h>
#include <linux/virtio_net.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <netinet/ip6.h>
#include <netinet/udp.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define UDP_PAYLOAD_LEN 4096U
#define UDP_DATAGRAM_LEN (sizeof(struct udphdr) + UDP_PAYLOAD_LEN)
#define FRAGMENT_DATA_LEN 1224U
#define IPV6_PACKET_MTU 1280U

struct destination_options {
	uint8_t next_header;
	uint8_t header_length;
	uint8_t padding[6];
};

static void fail(const char *message)
{
	perror(message);
	exit(EXIT_FAILURE);
}

static void parse_mac(const char *text, uint8_t address[ETH_ALEN])
{
	unsigned int octets[ETH_ALEN];
	int parsed;

	parsed = sscanf(text, "%x:%x:%x:%x:%x:%x",
			&octets[0], &octets[1], &octets[2],
			&octets[3], &octets[4], &octets[5]);
	if (parsed != ETH_ALEN) {
		fprintf(stderr, "invalid MAC address: %s\n", text);
		exit(EXIT_FAILURE);
	}

	for (size_t i = 0; i < ETH_ALEN; i++) {
		if (octets[i] > UINT8_MAX) {
			fprintf(stderr, "invalid MAC address: %s\n", text);
			exit(EXIT_FAILURE);
		}
		address[i] = (uint8_t)octets[i];
	}
}

static uint16_t fold_sum(uint32_t sum)
{
	while (sum >> 16)
		sum = (sum & UINT16_MAX) + (sum >> 16);
	return (uint16_t)sum;
}

static uint32_t add_bytes(uint32_t sum, const uint8_t *data, size_t length)
{
	while (length >= 2) {
		sum += ((uint32_t)data[0] << 8) | data[1];
		data += 2;
		length -= 2;
	}
	if (length)
		sum += (uint32_t)data[0] << 8;
	return sum;
}

static uint16_t udp6_partial_seed(const struct in6_addr *source,
				  const struct in6_addr *destination)
{
	uint8_t length_and_protocol[8] = {
		0, 0,
		(uint8_t)(UDP_DATAGRAM_LEN >> 8),
		(uint8_t)UDP_DATAGRAM_LEN,
		0, 0, 0, IPPROTO_UDP,
	};
	uint32_t sum = 0;

	sum = add_bytes(sum, source->s6_addr, sizeof(source->s6_addr));
	sum = add_bytes(sum, destination->s6_addr,
			sizeof(destination->s6_addr));
	sum = add_bytes(sum, length_and_protocol,
			sizeof(length_and_protocol));
	return htons(fold_sum(sum));
}

int main(int argc, char **argv)
{
	uint8_t udp_datagram[UDP_DATAGRAM_LEN];
	uint8_t source_mac[ETH_ALEN];
	uint8_t destination_mac[ETH_ALEN];
	struct in6_addr source_ip;
	struct in6_addr destination_ip;
	struct sockaddr_ll destination = { 0 };
	struct udphdr *udp = (struct udphdr *)udp_datagram;
	unsigned long destination_port;
	unsigned int interface_index;
	uint32_t fragment_id;
	int enabled = 1;
	int socket_fd;

	if (argc != 7) {
		fprintf(stderr,
			"usage: %s IFACE SOURCE_MAC DEST_MAC SOURCE_IP DEST_IP DEST_PORT\n",
			argv[0]);
		return EXIT_FAILURE;
	}

	interface_index = if_nametoindex(argv[1]);
	if (!interface_index) {
		errno = ENODEV;
		fail("if_nametoindex");
	}
	parse_mac(argv[2], source_mac);
	parse_mac(argv[3], destination_mac);
	if (inet_pton(AF_INET6, argv[4], &source_ip) != 1 ||
	    inet_pton(AF_INET6, argv[5], &destination_ip) != 1) {
		fprintf(stderr, "invalid IPv6 address\n");
		return EXIT_FAILURE;
	}
	destination_port = strtoul(argv[6], NULL, 10);
	if (!destination_port || destination_port > UINT16_MAX) {
		fprintf(stderr, "invalid destination port: %s\n", argv[6]);
		return EXIT_FAILURE;
	}

	memset(udp_datagram, 0, sizeof(udp_datagram));
	udp->source = htons(40000);
	udp->dest = htons((uint16_t)destination_port);
	udp->len = htons(UDP_DATAGRAM_LEN);
	udp->check = udp6_partial_seed(&source_ip, &destination_ip);
	for (size_t i = sizeof(*udp); i < sizeof(udp_datagram); i++)
		udp_datagram[i] = (uint8_t)i;

	socket_fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_IPV6));
	if (socket_fd < 0)
		fail("socket");
	if (setsockopt(socket_fd, SOL_PACKET, PACKET_VNET_HDR,
		       &enabled, sizeof(enabled)) < 0)
		fail("setsockopt(PACKET_VNET_HDR)");

	destination.sll_family = AF_PACKET;
	destination.sll_protocol = htons(ETH_P_IPV6);
	destination.sll_ifindex = (int)interface_index;
	destination.sll_halen = ETH_ALEN;
	memcpy(destination.sll_addr, destination_mac, ETH_ALEN);
	fragment_id = htonl(0x4b4c0000U | (uint32_t)destination_port);

	for (size_t offset = 0; offset < sizeof(udp_datagram);) {
		uint8_t packet[sizeof(struct virtio_net_hdr) + ETH_HLEN +
			       sizeof(struct ip6_hdr) +
			       sizeof(struct destination_options) +
			       sizeof(struct ip6_frag) + FRAGMENT_DATA_LEN];
		struct virtio_net_hdr *vnet = (struct virtio_net_hdr *)packet;
		struct ether_header *ether = (struct ether_header *)(vnet + 1);
		struct ip6_hdr *ipv6 = (struct ip6_hdr *)(ether + 1);
		struct destination_options *options =
			(struct destination_options *)(ipv6 + 1);
		struct ip6_frag *fragment = (struct ip6_frag *)(options + 1);
		uint8_t *payload = (uint8_t *)(fragment + 1);
		size_t remaining = sizeof(udp_datagram) - offset;
		size_t fragment_length = remaining > FRAGMENT_DATA_LEN ?
			FRAGMENT_DATA_LEN : remaining;
		bool more = fragment_length < remaining;
		size_t frame_length = ETH_HLEN + sizeof(*ipv6) +
			sizeof(*options) + sizeof(*fragment) + fragment_length;
		size_t send_length = sizeof(*vnet) + frame_length;
		ssize_t sent;

		memset(packet, 0, sizeof(packet));
		vnet->flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
		vnet->gso_type = VIRTIO_NET_HDR_GSO_NONE;
		vnet->hdr_len = htole16(ETH_HLEN + sizeof(*ipv6) +
					sizeof(*options) + sizeof(*fragment) +
					sizeof(*udp));
		vnet->csum_start = htole16(ETH_HLEN + sizeof(*ipv6) +
					   sizeof(*options) + sizeof(*fragment));
		vnet->csum_offset = htole16(offsetof(struct udphdr, check));

		memcpy(ether->ether_shost, source_mac, ETH_ALEN);
		memcpy(ether->ether_dhost, destination_mac, ETH_ALEN);
		ether->ether_type = htons(ETH_P_IPV6);

		ipv6->ip6_flow = htonl(6U << 28);
		ipv6->ip6_plen = htons(sizeof(*options) + sizeof(*fragment) +
					 fragment_length);
		ipv6->ip6_nxt = IPPROTO_DSTOPTS;
		ipv6->ip6_hops = 64;
		ipv6->ip6_src = source_ip;
		ipv6->ip6_dst = destination_ip;

		options->next_header = IPPROTO_FRAGMENT;
		options->header_length = 0;
		fragment->ip6f_nxt = IPPROTO_UDP;
		fragment->ip6f_offlg = htons((uint16_t)offset |
						(more ? 1U : 0U));
		fragment->ip6f_ident = fragment_id;
		memcpy(payload, udp_datagram + offset, fragment_length);

		if (frame_length - ETH_HLEN > IPV6_PACKET_MTU) {
			fprintf(stderr, "constructed fragment exceeds MTU\n");
			return EXIT_FAILURE;
		}
		sent = sendto(socket_fd, packet, send_length, 0,
			      (struct sockaddr *)&destination,
			      sizeof(destination));
		if (sent < 0)
			fail("sendto");
		if ((size_t)sent != send_length) {
			fprintf(stderr, "short packet send: %zd of %zu\n",
				sent, send_length);
			return EXIT_FAILURE;
		}
		offset += fragment_length;
	}

	if (close(socket_fd) < 0)
		fail("close");
	return EXIT_SUCCESS;
}
