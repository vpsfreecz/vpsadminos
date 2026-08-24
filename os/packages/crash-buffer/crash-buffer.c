#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define BUFFER_SIZE (256U * 1024U)

struct options {
  bool append;
  const char *complete_path;
  const char *timing_name;
  const char *timing_path;
  int64_t since_ms;
  const char *output_path;
};

static void usage(const char *program) {
  fprintf(stderr,
          "Usage: %s [--append] [--complete PATH] "
          "[--timing NAME PATH] [--since MS] OUTPUT\n",
          program);
}

static int64_t monotonic_ms(void) {
  struct timespec now;

  if (clock_gettime(CLOCK_BOOTTIME, &now) == -1) {
    perror("clock_gettime");
    return -1;
  }

  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int write_all(int fd, const void *data, size_t length) {
  const unsigned char *position = data;

  while (length > 0) {
    ssize_t written = write(fd, position, length);

    if (written == -1) {
      if (errno == EINTR)
        continue;

      return -1;
    }

    if (written == 0) {
      errno = EIO;
      return -1;
    }

    position += written;
    length -= (size_t)written;
  }

  return 0;
}

static int append_timing(const struct options *options, int64_t started_ms,
                         int64_t finished_ms) {
  char line[256];
  int fd;
  int length;

  if (options->timing_path == NULL)
    return 0;

  fd = open(options->timing_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd == -1) {
    perror(options->timing_path);
    return -1;
  }

  if (options->since_ms >= 0) {
    length = snprintf(line, sizeof(line), "initialization %" PRId64 "\n",
                      started_ms - options->since_ms);
    if (length < 0 || (size_t)length >= sizeof(line) ||
        write_all(fd, line, (size_t)length) == -1) {
      perror(options->timing_path);
      close(fd);
      return -1;
    }
  }

  length = snprintf(line, sizeof(line), "%s %" PRId64 "\n",
                    options->timing_name, finished_ms - started_ms);
  if (length < 0 || (size_t)length >= sizeof(line) ||
      write_all(fd, line, (size_t)length) == -1 || close(fd) == -1) {
    perror(options->timing_path);
    return -1;
  }

  return 0;
}

static int create_completion_marker(const char *path) {
  static const char success[] = "0\n";
  int fd;

  if (path == NULL)
    return 0;

  fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd == -1 || write_all(fd, success, sizeof(success) - 1) == -1 ||
      close(fd) == -1) {
    perror(path);
    return -1;
  }

  return 0;
}

static int parse_options(int argc, char **argv, struct options *options) {
  int i;

  memset(options, 0, sizeof(*options));
  options->since_ms = -1;

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--append") == 0) {
      options->append = true;
    } else if (strcmp(argv[i], "--complete") == 0 && i + 1 < argc) {
      options->complete_path = argv[++i];
    } else if (strcmp(argv[i], "--timing") == 0 && i + 2 < argc) {
      options->timing_name = argv[++i];
      options->timing_path = argv[++i];
    } else if (strcmp(argv[i], "--since") == 0 && i + 1 < argc) {
      char *end;

      errno = 0;
      options->since_ms = strtoll(argv[++i], &end, 10);
      if (errno != 0 || *end != '\0' || options->since_ms < 0)
        return -1;
    } else if (argv[i][0] == '-' || options->output_path != NULL) {
      return -1;
    } else {
      options->output_path = argv[i];
    }
  }

  if (options->output_path == NULL)
    return -1;

  if ((options->timing_name == NULL) != (options->timing_path == NULL))
    return -1;

  if (options->since_ms >= 0 && options->timing_path == NULL)
    return -1;

  return 0;
}

int main(int argc, char **argv) {
  struct options options;
  unsigned char *buffer;
  int flags = O_WRONLY | O_CREAT;
  int output_fd;
  int64_t started_ms;
  int64_t finished_ms;
  int status = EXIT_FAILURE;

  if (parse_options(argc, argv, &options) == -1) {
    usage(argv[0]);
    return EXIT_FAILURE;
  }

  buffer = malloc(BUFFER_SIZE);
  if (buffer == NULL) {
    perror("malloc");
    return EXIT_FAILURE;
  }

  started_ms = monotonic_ms();
  if (started_ms < 0)
    goto out_free;

  flags |= options.append ? O_APPEND : O_TRUNC;
  output_fd = open(options.output_path, flags, 0644);
  if (output_fd == -1) {
    perror(options.output_path);
    goto out_free;
  }

  for (;;) {
    ssize_t received = read(STDIN_FILENO, buffer, BUFFER_SIZE);

    if (received == 0)
      break;

    if (received == -1) {
      if (errno == EINTR)
        continue;

      perror("read");
      goto out_close;
    }

    if (write_all(output_fd, buffer, (size_t)received) == -1) {
      perror(options.output_path);
      goto out_close;
    }
  }

  if (close(output_fd) == -1) {
    output_fd = -1;
    perror(options.output_path);
    goto out_free;
  }
  output_fd = -1;

  finished_ms = monotonic_ms();
  if (finished_ms < 0 ||
      append_timing(&options, started_ms, finished_ms) == -1 ||
      create_completion_marker(options.complete_path) == -1)
    goto out_free;

  status = EXIT_SUCCESS;
  goto out_free;

out_close:
  if (close(output_fd) == -1)
    perror(options.output_path);
out_free:
  free(buffer);
  return status;
}
