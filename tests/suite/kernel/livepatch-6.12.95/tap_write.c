// SPDX-License-Identifier: GPL-2.0

#include <errno.h>
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	static const unsigned char ethernet_header[] = {
		0x02, 0x00, 0x00, 0x00, 0x00, 0x01,
		0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
		0x08, 0x00,
	};
	struct ifreq ifr = { 0 };
	unsigned char *frame;
	char *end;
	long requested;
	ssize_t written;
	int fd;

	if (argc != 3) {
		fprintf(stderr, "usage: %s IFNAME LENGTH\n", argv[0]);
		return 2;
	}
	if (strlen(argv[1]) >= IFNAMSIZ) {
		fprintf(stderr, "interface name is too long\n");
		return 2;
	}

	errno = 0;
	requested = strtol(argv[2], &end, 10);
	if (errno || *end != '\0' || requested <= 0 || requested > 65535) {
		fprintf(stderr, "invalid frame length: %s\n", argv[2]);
		return 2;
	}

	frame = calloc(1, (size_t)requested);
	if (!frame) {
		perror("calloc");
		return 2;
	}
	if ((size_t)requested >= sizeof(ethernet_header))
		memcpy(frame, ethernet_header, sizeof(ethernet_header));

	fd = open("/dev/net/tun", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open /dev/net/tun");
		free(frame);
		return 2;
	}

	strcpy(ifr.ifr_name, argv[1]);
	ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
	if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
		perror("TUNSETIFF");
		close(fd);
		free(frame);
		return 2;
	}

	/* by-name contract: the attached name must match the request */
	if (strcmp(ifr.ifr_name, argv[1]) != 0) {
		fprintf(stderr, "TUNSETIFF attached '%s', expected '%s'\n",
			ifr.ifr_name, argv[1]);
		close(fd);
		free(frame);
		return 2;
	}

	written = write(fd, frame, (size_t)requested);
	if (written != requested) {
		if (written < 0)
			perror("write");
		else
			fprintf(stderr, "short write: %zd of %ld\n", written,
				requested);
		close(fd);
		free(frame);
		return 1;
	}

	close(fd);
	free(frame);
	return 0;
}
