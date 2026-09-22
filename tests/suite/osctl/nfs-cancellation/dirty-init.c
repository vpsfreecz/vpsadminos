#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static void fail(const char *operation)
{
	perror(operation);
	_exit(1);
}

static void marker(const char *path)
{
	int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0600);

	if (fd < 0 || close(fd))
		fail(path);
}

static void command(int fd, char expected)
{
	char value;
	ssize_t count;

	do {
		count = read(fd, &value, 1);
	} while (count < 0 && errno == EINTR);
	if (count != 1 || value != expected) {
		fprintf(stderr, "invalid init control command\n");
		_exit(1);
	}
}

int main(int argc, char **argv)
{
	const char data[] = "buffered data owned by PID1\n";
	int control, file;

	if (argc != 2 || getpid() != 1) {
		fprintf(stderr, "dirty-init must be PID1 with an NFS file argument\n");
		return 1;
	}

	if (mkfifo("/root/nfs-init-control", 0600))
		fail("mkfifo");
	control = open("/root/nfs-init-control", O_RDWR);
	if (control < 0)
		fail("open control");
	file = open(argv[1], O_CREAT | O_WRONLY | O_TRUNC, 0600);
	if (file < 0)
		fail("open NFS file");
	marker("/root/nfs-init-ready");

	command(control, 'd');
	if (write(file, data, sizeof(data) - 1) != sizeof(data) - 1)
		fail("write NFS file");
	marker("/root/nfs-init-written");
	command(control, 'e');

	/* No close(), libc cleanup, shell builtin or child: exit_files() must
	 * close the dirty NFS descriptor after the kernel sets PF_EXITING.
	 */
	_exit(0);
}
