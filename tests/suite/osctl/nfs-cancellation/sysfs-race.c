#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	unsigned long long attempts = 0, unready = 0, writes = 0, errors = 0;
	DIR *dir;

	if (argc != 2)
		return 2;
	dir = opendir("/sys/fs/nfs");
	if (!dir) {
		perror("opendir NFS sysfs");
		return 1;
	}
	while (access(argv[1], F_OK)) {
		struct dirent *entry;

		rewinddir(dir);
		while ((entry = readdir(dir))) {
			char path[512];
			int fd, error;
			ssize_t ret;

			if (entry->d_name[0] == '.' || !strcmp(entry->d_name, "net"))
				continue;
			snprintf(path, sizeof(path), "/sys/fs/nfs/%s/shutdown", entry->d_name);
			fd = open(path, O_WRONLY);
			if (fd < 0)
				continue;
			attempts++;
			ret = write(fd, "1\n", 2);
			error = errno;
			close(fd);
			if (ret == 2)
				writes++;
			else if (error == EAGAIN)
				unready++;
			else if (error != ENOENT && error != ENODEV)
				errors++;
		}
	}
	closedir(dir);
	printf("{\"attempts\":%llu,\"unready\":%llu,\"writes\":%llu,\"errors\":%llu}\n",
	       attempts, unready, writes, errors);
	return errors ? 1 : 0;
}
