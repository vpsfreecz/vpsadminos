import ../../make-test.nix (
  { pkgs }:
  let
    tracework = pkgs.stdenv.mkDerivation {
      pname = "vpsadminos-tracework";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "tracework.c" ''
        #include <fcntl.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <time.h>
        #include <unistd.h>

        static volatile uint64_t sink;

        static void spin_leaf(unsigned long rounds)
        {
          for (unsigned long i = 0; i < rounds; i++)
            sink += (i * 1103515245UL + 12345UL) >> 8;
        }

        static void spin_branch(unsigned long rounds)
        {
          spin_leaf(rounds);
          spin_leaf(rounds / 2 + 1);
        }

        static void touch_marker(void)
        {
          int fd = open("/tmp/vpsadminos-tracing-marker", O_RDONLY | O_CLOEXEC);
          if (fd >= 0) {
            char buf[32];
            (void)read(fd, buf, sizeof(buf));
            close(fd);
          }
        }

        int main(int argc, char **argv)
        {
          int seconds = 2;

          if (argc > 1)
            seconds = atoi(argv[1]);
          if (seconds < 1)
            seconds = 1;

          time_t end = time(NULL) + seconds;
          do {
            touch_marker();
            spin_branch(250000);
          } while (time(NULL) < end);

          printf("%llu\n", (unsigned long long)sink);
          return 0;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O0 -g -fno-omit-frame-pointer "$src" -o tracework
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 tracework $out/bin/tracework
        runHook postInstall
      '';
    };

    bpfMapSmoke = pkgs.stdenv.mkDerivation {
      pname = "vpsadminos-bpf-map-smoke";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "bpf-map-smoke.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <linux/bpf.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/syscall.h>
        #include <unistd.h>

        static int create_array_map_errno(void)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint64_t);
          attr.max_entries = 1;

          fd = syscall(SYS_bpf, BPF_MAP_CREATE, &attr, sizeof(attr));
          if (fd < 0)
            return errno;

          close(fd);
          return 0;
        }

        int main(int argc, char **argv)
        {
          int expect_eperm = argc == 2 && strcmp(argv[1], "--expect-eperm") == 0;
          int err = create_array_map_errno();

          printf("bpf_map_create_errno=%d\n", err);

          if (expect_eperm)
            return err == EPERM ? 0 : 1;

          return err == 0 ? 0 : 1;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o bpf-map-smoke
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 bpf-map-smoke $out/bin/bpf-map-smoke
        runHook postInstall
      '';
    };

    perfFdLeakProbe = pkgs.stdenv.mkDerivation {
      pname = "vpsadminos-perf-fd-leak-probe";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "perf-fd-leak-probe.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <fcntl.h>
        #include <linux/bpf.h>
        #include <linux/perf_event.h>
        #include <poll.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/ioctl.h>
        #include <sys/mman.h>
        #include <sys/socket.h>
        #include <sys/stat.h>
        #include <sys/syscall.h>
        #include <sys/un.h>
        #include <unistd.h>

        static void die_errno(const char *what)
        {
          fprintf(stderr, "%s failed: errno=%d\n", what, errno);
          exit(1);
        }

        static void fill_unix_addr(struct sockaddr_un *addr, const char *path)
        {
          size_t len = strlen(path);

          if (len >= sizeof(addr->sun_path)) {
            fprintf(stderr, "unix socket path too long: %s\n", path);
            exit(2);
          }

          memset(addr, 0, sizeof(*addr));
          addr->sun_family = AF_UNIX;
          memcpy(addr->sun_path, path, len + 1);
        }

        static int perf_event_open(struct perf_event_attr *attr, pid_t pid,
                                   int cpu, int group_fd, unsigned long flags)
        {
          return syscall(SYS_perf_event_open, attr, pid, cpu, group_fd, flags);
        }

        static int bpf_cmd(enum bpf_cmd cmd, union bpf_attr *attr)
        {
          return syscall(SYS_bpf, cmd, attr, sizeof(*attr));
        }

        static int open_host_perf_event(void)
        {
          struct perf_event_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.type = PERF_TYPE_SOFTWARE;
          attr.size = sizeof(attr);
          attr.config = PERF_COUNT_SW_CPU_CLOCK;
          attr.disabled = 1;
          attr.exclude_hv = 1;
          attr.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED |
                             PERF_FORMAT_TOTAL_TIME_RUNNING |
                             PERF_FORMAT_ID;

          fd = perf_event_open(&attr, 0, -1, -1, PERF_FLAG_FD_CLOEXEC);
          if (fd < 0)
            die_errno("perf_event_open");

          return fd;
        }

        static int send_fd_over_socket(const char *socket_path, int fd)
        {
          struct sockaddr_un addr;
          struct msghdr msg;
          struct cmsghdr *cmsg;
          struct iovec iov;
          char data = 'P';
          char control[CMSG_SPACE(sizeof(int))];
          int sock;

          sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
          if (sock < 0)
            die_errno("socket");

          fill_unix_addr(&addr, socket_path);
          if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            die_errno(socket_path);

          memset(&msg, 0, sizeof(msg));
          memset(control, 0, sizeof(control));
          iov.iov_base = &data;
          iov.iov_len = sizeof(data);
          msg.msg_iov = &iov;
          msg.msg_iovlen = 1;
          msg.msg_control = control;
          msg.msg_controllen = sizeof(control);

          cmsg = CMSG_FIRSTHDR(&msg);
          cmsg->cmsg_level = SOL_SOCKET;
          cmsg->cmsg_type = SCM_RIGHTS;
          cmsg->cmsg_len = CMSG_LEN(sizeof(int));
          memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
          msg.msg_controllen = CMSG_SPACE(sizeof(int));

          if (sendmsg(sock, &msg, 0) < 0)
            die_errno("sendmsg");

          close(sock);
          return 0;
        }

        static int recv_fd_over_socket(const char *socket_path)
        {
          struct sockaddr_un addr;
          struct msghdr msg;
          struct cmsghdr *cmsg;
          struct iovec iov;
          char data;
          char control[CMSG_SPACE(sizeof(int))];
          int sock, conn, fd = -1;

          sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
          if (sock < 0)
            die_errno("socket");

          fill_unix_addr(&addr, socket_path);
          unlink(socket_path);
          if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            die_errno(socket_path);
          if (chmod(socket_path, 0666) < 0)
            die_errno(socket_path);
          if (listen(sock, 1) < 0)
            die_errno("listen");

          conn = accept4(sock, NULL, NULL, SOCK_CLOEXEC);
          if (conn < 0)
            die_errno("accept4");

          memset(&msg, 0, sizeof(msg));
          memset(control, 0, sizeof(control));
          iov.iov_base = &data;
          iov.iov_len = sizeof(data);
          msg.msg_iov = &iov;
          msg.msg_iovlen = 1;
          msg.msg_control = control;
          msg.msg_controllen = sizeof(control);

          if (recvmsg(conn, &msg, 0) < 0)
            die_errno("recvmsg");

          for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
            if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
              memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
              break;
            }
          }

          close(conn);
          close(sock);

          if (fd < 0) {
            fprintf(stderr, "no file descriptor received\n");
            exit(1);
          }

          return fd;
        }

        static int fstat_errno(int fd)
        {
          struct stat st;

          if (fstat(fd, &st) == 0)
            return 0;
          return errno;
        }

        static int read_errno(int fd)
        {
          uint64_t values[4];

          if (read(fd, values, sizeof(values)) >= 0)
            return 0;
          return errno;
        }

        static int ioctl_enable_errno(int fd)
        {
          if (ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) == 0)
            return 0;
          return errno;
        }

        static int ioctl_id_errno(int fd)
        {
          uint64_t id = 0;

          if (ioctl(fd, PERF_EVENT_IOC_ID, &id) == 0)
            return 0;
          return errno;
        }

        static int perf_open_with_group_errno(int group_fd, unsigned long flags)
        {
          struct perf_event_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.type = PERF_TYPE_SOFTWARE;
          attr.size = sizeof(attr);
          attr.config = PERF_COUNT_SW_TASK_CLOCK;
          attr.disabled = 1;
          attr.exclude_hv = 1;

          fd = perf_event_open(&attr, 0, -1, group_fd,
                               flags | PERF_FLAG_FD_CLOEXEC);
          if (fd >= 0) {
            close(fd);
            return 0;
          }

          return errno;
        }

        static int open_container_perf_event(void)
        {
          struct perf_event_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.type = PERF_TYPE_SOFTWARE;
          attr.size = sizeof(attr);
          attr.config = PERF_COUNT_SW_TASK_CLOCK;
          attr.disabled = 1;
          attr.exclude_kernel = 1;
          attr.exclude_hv = 1;

          return perf_event_open(&attr, 0, -1, -1, PERF_FLAG_FD_CLOEXEC);
        }

        static int ioctl_set_output_errno(int output_fd, int *create_err)
        {
          int err, fd;

          fd = open_container_perf_event();
          if (fd < 0) {
            *create_err = errno;
            return errno;
          }
          *create_err = 0;

          if (ioctl(fd, PERF_EVENT_IOC_SET_OUTPUT, output_fd) == 0) {
            close(fd);
            return 0;
          }

          err = errno;
          close(fd);
          return err;
        }

        static int mmap_errno(int fd)
        {
          long page_size = sysconf(_SC_PAGESIZE);
          void *addr;

          if (page_size <= 0)
            page_size = 4096;

          addr = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
          if (addr != MAP_FAILED) {
            munmap(addr, page_size);
            return 0;
          }

          return errno;
        }

        static int poll_revents(int fd, int *poll_errno)
        {
          struct pollfd pfd;
          int ret;

          memset(&pfd, 0, sizeof(pfd));
          pfd.fd = fd;
          pfd.events = POLLIN | POLLOUT;

          ret = poll(&pfd, 1, 0);
          if (ret < 0) {
            *poll_errno = errno;
            return 0;
          }

          *poll_errno = 0;
          return pfd.revents;
        }

        static int fasync_errno(int fd)
        {
          int flags;

          if (fcntl(fd, F_SETOWN, getpid()) < 0)
            return errno;

          flags = fcntl(fd, F_GETFL);
          if (flags < 0)
            return errno;

          if (fcntl(fd, F_SETFL, flags | O_ASYNC) == 0)
            return 0;

          return errno;
        }

        static int create_perf_event_array(void)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_PERF_EVENT_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint32_t);
          attr.max_entries = 1;

          return bpf_cmd(BPF_MAP_CREATE, &attr);
        }

        static int perf_array_update_errno(int perf_fd, int *create_err)
        {
          union bpf_attr attr;
          uint32_t key = 0;
          uint32_t value = (uint32_t)perf_fd;
          int map_fd;

          map_fd = create_perf_event_array();
          if (map_fd < 0) {
            *create_err = errno;
            return errno;
          }
          *create_err = 0;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&value;
          attr.flags = BPF_ANY;

          if (bpf_cmd(BPF_MAP_UPDATE_ELEM, &attr) == 0) {
            close(map_fd);
            return 0;
          }

          close(map_fd);
          return errno;
        }

        static int task_fd_query_errno(int fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.task_fd_query.pid = getpid();
          attr.task_fd_query.fd = fd;

          if (bpf_cmd(BPF_TASK_FD_QUERY, &attr) == 0)
            return 0;

          return errno;
        }

        static int expected_denial_errno(int err)
        {
          return err == EACCES || err == EPERM;
        }

        static int cpu_wide_kprobe_errno(int pmu_type)
        {
          struct perf_event_attr attr;
          const char *func = "tcp_v4_connect";
          int fd, rerr, mmap_err;

          memset(&attr, 0, sizeof(attr));
          attr.type = pmu_type;
          attr.size = sizeof(attr);
          attr.config = 0;
          attr.sample_period = 1;
          attr.sample_type = PERF_SAMPLE_IP;
          attr.wakeup_events = 1;
          attr.exclude_hv = 1;
          attr.kprobe_func = (uint64_t)(uintptr_t)func;

          fd = perf_event_open(&attr, -1, 0, -1, PERF_FLAG_FD_CLOEXEC);
          if (fd < 0) {
            printf("container_cpu_wide_kprobe_open_errno=%d\n", errno);
            return expected_denial_errno(errno) ? 0 : 1;
          }

          printf("container_cpu_wide_kprobe_open_errno=0\n");
          rerr = read_errno(fd);
          mmap_err = mmap_errno(fd);
          printf("container_cpu_wide_kprobe_read_errno=%d\n", rerr);
          printf("container_cpu_wide_kprobe_mmap_errno=%d\n", mmap_err);
          close(fd);

          return expected_denial_errno(rerr) &&
            expected_denial_errno(mmap_err) ? 0 : 1;
        }

        static int tracepoint_open_errno(int tracepoint_id)
        {
          struct perf_event_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.type = PERF_TYPE_TRACEPOINT;
          attr.size = sizeof(attr);
          attr.config = tracepoint_id;
          attr.sample_period = 1;
          attr.disabled = 1;
          attr.exclude_hv = 1;

          fd = perf_event_open(&attr, -1, 0, -1, PERF_FLAG_FD_CLOEXEC);
          if (fd < 0) {
            printf("container_perf_tracepoint_open_errno=%d\n", errno);
            return expected_denial_errno(errno) ? 0 : 1;
          }

          printf("container_perf_tracepoint_open_errno=0\n");
          close(fd);
          return 1;
        }

        int main(int argc, char **argv)
        {
          int fd, staterr, rerr, enable_err, id_err, group_err, fd_output_err, set_output_err, mmap_err, poll_errno, revents, async_err;
          int set_output_create_err;
          int perf_array_create_err, perf_array_update_err;
          int task_fd_query_err;

          if (argc != 3) {
            fprintf(stderr, "usage: %s send SOCKET_PATH | recv SOCKET_PATH\n", argv[0]);
            return 2;
          }

          if (strcmp(argv[1], "send") == 0) {
            fd = open_host_perf_event();
            send_fd_over_socket(argv[2], fd);
            close(fd);
            return 0;
          }

          if (strcmp(argv[1], "cpu-wide-kprobe") == 0)
            return cpu_wide_kprobe_errno(atoi(argv[2]));

          if (strcmp(argv[1], "tracepoint-open") == 0)
            return tracepoint_open_errno(atoi(argv[2]));

          if (strcmp(argv[1], "recv") != 0) {
            fprintf(stderr, "unknown mode: %s\n", argv[1]);
            return 2;
          }

          fd = recv_fd_over_socket(argv[2]);
          staterr = fstat_errno(fd);
          rerr = read_errno(fd);
          enable_err = ioctl_enable_errno(fd);
          id_err = ioctl_id_errno(fd);
          group_err = perf_open_with_group_errno(fd, 0);
          fd_output_err = perf_open_with_group_errno(fd, PERF_FLAG_FD_OUTPUT);
          set_output_err = ioctl_set_output_errno(fd, &set_output_create_err);
          mmap_err = mmap_errno(fd);
          revents = poll_revents(fd, &poll_errno);
          async_err = fasync_errno(fd);
          perf_array_update_err = perf_array_update_errno(fd, &perf_array_create_err);
          task_fd_query_err = task_fd_query_errno(fd);

          printf("leaked_host_perf_fstat_errno=%d\n", staterr);
          printf("leaked_host_perf_read_errno=%d\n", rerr);
          printf("leaked_host_perf_ioctl_enable_errno=%d\n", enable_err);
          printf("leaked_host_perf_ioctl_id_errno=%d\n", id_err);
          printf("leaked_host_perf_group_open_errno=%d\n", group_err);
          printf("leaked_host_perf_fd_output_open_errno=%d\n", fd_output_err);
          printf("container_perf_set_output_create_errno=%d\n", set_output_create_err);
          printf("leaked_host_perf_ioctl_set_output_errno=%d\n", set_output_err);
          printf("leaked_host_perf_mmap_errno=%d\n", mmap_err);
          printf("leaked_host_perf_poll_errno=%d\n", poll_errno);
          printf("leaked_host_perf_poll_revents=%#x\n", revents);
          printf("leaked_host_perf_fasync_errno=%d\n", async_err);
          printf("perf_array_create_errno=%d\n", perf_array_create_err);
          printf("leaked_host_perf_array_update_errno=%d\n", perf_array_update_err);
          printf("leaked_host_perf_task_fd_query_errno=%d\n", task_fd_query_err);

          close(fd);

          return staterr == 0 &&
            expected_denial_errno(rerr) &&
            expected_denial_errno(enable_err) &&
            expected_denial_errno(id_err) &&
            expected_denial_errno(group_err) &&
            expected_denial_errno(fd_output_err) &&
            set_output_create_err == 0 &&
            expected_denial_errno(set_output_err) &&
            expected_denial_errno(mmap_err) &&
            poll_errno == 0 &&
            (revents & POLLERR) &&
            expected_denial_errno(async_err) &&
            perf_array_create_err == 0 &&
            expected_denial_errno(perf_array_update_err) &&
            expected_denial_errno(task_fd_query_err) ? 0 : 1;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o perf-fd-leak-probe
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 perf-fd-leak-probe $out/bin/perf-fd-leak-probe
        runHook postInstall
      '';
    };

    btfFdLeakProbe = pkgs.stdenv.mkDerivation {
      pname = "vpsadminos-btf-fd-leak-probe";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "btf-fd-leak-probe.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <fcntl.h>
        #include <linux/bpf.h>
        #include <linux/btf.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/socket.h>
        #include <sys/stat.h>
        #include <sys/syscall.h>
        #include <sys/un.h>
        #include <unistd.h>

        static void die_errno(const char *what)
        {
          fprintf(stderr, "%s failed: errno=%d\n", what, errno);
          exit(1);
        }

        static int expected_denial_errno(int err)
        {
          return err == EACCES || err == EPERM;
        }

        static void fill_unix_addr(struct sockaddr_un *addr, const char *path)
        {
          size_t len = strlen(path);

          if (len >= sizeof(addr->sun_path)) {
            fprintf(stderr, "unix socket path too long: %s\n", path);
            exit(2);
          }

          memset(addr, 0, sizeof(*addr));
          addr->sun_family = AF_UNIX;
          memcpy(addr->sun_path, path, len + 1);
        }

        static void send_fd_over_socket(const char *socket_path, int fd)
        {
          struct sockaddr_un addr;
          struct msghdr msg;
          struct cmsghdr *cmsg;
          struct iovec iov;
          char data = 'B';
          char control[CMSG_SPACE(sizeof(int))];
          int sock;

          sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
          if (sock < 0)
            die_errno("socket");

          fill_unix_addr(&addr, socket_path);
          if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            die_errno(socket_path);

          memset(&msg, 0, sizeof(msg));
          memset(control, 0, sizeof(control));
          iov.iov_base = &data;
          iov.iov_len = sizeof(data);
          msg.msg_iov = &iov;
          msg.msg_iovlen = 1;
          msg.msg_control = control;
          msg.msg_controllen = sizeof(control);

          cmsg = CMSG_FIRSTHDR(&msg);
          cmsg->cmsg_level = SOL_SOCKET;
          cmsg->cmsg_type = SCM_RIGHTS;
          cmsg->cmsg_len = CMSG_LEN(sizeof(int));
          memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
          msg.msg_controllen = CMSG_SPACE(sizeof(int));

          if (sendmsg(sock, &msg, 0) < 0)
            die_errno("sendmsg");

          close(sock);
        }

        static int open_fd_receiver(const char *socket_path)
        {
          struct sockaddr_un addr;
          int sock;

          sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
          if (sock < 0)
            die_errno("socket");

          fill_unix_addr(&addr, socket_path);
          unlink(socket_path);
          if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            die_errno(socket_path);
          if (chmod(socket_path, 0666) < 0)
            die_errno(socket_path);
          if (listen(sock, 1) < 0)
            die_errno("listen");

          return sock;
        }

        static int recv_fd_over_socket(int sock)
        {
          struct msghdr msg;
          struct cmsghdr *cmsg;
          struct iovec iov;
          char data;
          char control[CMSG_SPACE(sizeof(int))];
          int conn, fd = -1;

          conn = accept4(sock, NULL, NULL, SOCK_CLOEXEC);
          if (conn < 0)
            die_errno("accept4");

          memset(&msg, 0, sizeof(msg));
          memset(control, 0, sizeof(control));
          iov.iov_base = &data;
          iov.iov_len = sizeof(data);
          msg.msg_iov = &iov;
          msg.msg_iovlen = 1;
          msg.msg_control = control;
          msg.msg_controllen = sizeof(control);

          if (recvmsg(conn, &msg, 0) < 0)
            die_errno("recvmsg");

          for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
            if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
              memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
              break;
            }
          }

          close(conn);
          close(sock);

          if (fd < 0) {
            fprintf(stderr, "no file descriptor received\n");
            exit(1);
          }

          return fd;
        }

        static int load_minimal_btf(void)
        {
          struct btf_raw {
            struct btf_header hdr;
            struct btf_type type;
            uint32_t int_data;
            char strs[5];
          } __attribute__((packed)) raw;
          union bpf_attr attr;
          int fd;

          memset(&raw, 0, sizeof(raw));
          raw.hdr.magic = BTF_MAGIC;
          raw.hdr.version = BTF_VERSION;
          raw.hdr.hdr_len = sizeof(struct btf_header);
          raw.hdr.type_len = sizeof(struct btf_type) + sizeof(uint32_t);
          raw.hdr.str_off = raw.hdr.type_len;
          raw.hdr.str_len = sizeof(raw.strs);
          raw.type.name_off = 1;
          raw.type.info = BTF_KIND_INT << 24;
          raw.type.size = 4;
          raw.int_data = (BTF_INT_SIGNED << 24) | 32;
          memcpy(raw.strs, "\0int", sizeof(raw.strs));

          memset(&attr, 0, sizeof(attr));
          attr.btf = (uint64_t)(uintptr_t)&raw;
          attr.btf_size = sizeof(raw);

          fd = syscall(SYS_bpf, BPF_BTF_LOAD, &attr, sizeof(attr));
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int fstat_errno(int fd)
        {
          struct stat st;

          if (fstat(fd, &st) == 0)
            return 0;
          return errno;
        }

        static int btf_fdinfo_visible(int fd)
        {
          char path[64], buf[4096];
          ssize_t len;
          int info_fd;

          snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", fd);
          info_fd = open(path, O_RDONLY | O_CLOEXEC);
          if (info_fd < 0)
            return 0;

          len = read(info_fd, buf, sizeof(buf) - 1);
          close(info_fd);
          if (len <= 0)
            return 0;

          buf[len] = '\0';
          return strstr(buf, "btf_id:") != NULL;
        }

        static int btf_info_errno(int fd)
        {
          struct bpf_btf_info info;
          union bpf_attr attr;
          uint8_t data[1024];
          char name[64];

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          memset(data, 0, sizeof(data));
          memset(name, 0, sizeof(name));
          info.btf = (uint64_t)(uintptr_t)data;
          info.btf_size = sizeof(data);
          info.name = (uint64_t)(uintptr_t)name;
          info.name_len = sizeof(name);
          attr.info.bpf_fd = fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (syscall(SYS_bpf, BPF_OBJ_GET_INFO_BY_FD, &attr, sizeof(attr)) == 0)
            return 0;

          return errno;
        }

        static int map_create_with_btf_errno(int btf_fd)
        {
          union bpf_attr attr;
          int map_fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint32_t);
          attr.max_entries = 1;
          attr.btf_fd = btf_fd;
          attr.btf_key_type_id = 1;
          attr.btf_value_type_id = 1;

          map_fd = syscall(SYS_bpf, BPF_MAP_CREATE, &attr, sizeof(attr));
          if (map_fd >= 0) {
            close(map_fd);
            return 0;
          }

          return errno;
        }

        int main(int argc, char **argv)
        {
          int fd, receiver, local_btf_fd, staterr, fdinfo_seen, info_err, map_err;
          int local_load_err, local_info_err, local_map_err;

          if (argc != 3) {
            fprintf(stderr, "usage: %s send SOCKET_PATH | recv SOCKET_PATH\n", argv[0]);
            return 2;
          }

          if (strcmp(argv[1], "send") == 0) {
            fd = load_minimal_btf();
            if (fd < 0) {
              fprintf(stderr, "host BTF load failed errno=%d\n", -fd);
              return 1;
            }
            send_fd_over_socket(argv[2], fd);
            close(fd);
            return 0;
          }

          if (strcmp(argv[1], "recv") != 0) {
            fprintf(stderr, "unknown mode: %s\n", argv[1]);
            return 2;
          }

          receiver = open_fd_receiver(argv[2]);
          local_load_err = 0;
          local_info_err = -1;
          local_map_err = -1;
          local_btf_fd = load_minimal_btf();
          if (local_btf_fd < 0) {
            local_load_err = -local_btf_fd;
          } else {
            local_info_err = btf_info_errno(local_btf_fd);
            local_map_err = map_create_with_btf_errno(local_btf_fd);
            close(local_btf_fd);
          }

          fd = recv_fd_over_socket(receiver);
          staterr = fstat_errno(fd);
          fdinfo_seen = btf_fdinfo_visible(fd);
          info_err = btf_info_errno(fd);
          map_err = map_create_with_btf_errno(fd);

          printf("container_btf_load_errno=%d\n", local_load_err);
          printf("container_btf_info_errno=%d\n", local_info_err);
          printf("container_btf_map_create_errno=%d\n", local_map_err);
          printf("leaked_host_btf_fstat_errno=%d\n", staterr);
          printf("leaked_host_btf_fdinfo_visible=%d\n", fdinfo_seen);
          printf("leaked_host_btf_info_errno=%d\n", info_err);
          printf("leaked_host_btf_map_create_errno=%d\n", map_err);

          close(fd);

          return local_load_err == 0 &&
            local_info_err == 0 &&
            local_map_err == 0 &&
            staterr == 0 &&
            fdinfo_seen == 0 &&
            expected_denial_errno(info_err) &&
            expected_denial_errno(map_err) ? 0 : 1;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o btf-fd-leak-probe
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 btf-fd-leak-probe $out/bin/btf-fd-leak-probe
        runHook postInstall
      '';
    };

    bpfLoadProbeSmoke = pkgs.stdenv.mkDerivation {
      pname = "vpsadminos-bpf-load-probe-smoke";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "bpf-load-probe-smoke.c" ''
                #define _GNU_SOURCE
        #include <errno.h>
                #include <fcntl.h>
                #include <stddef.h>
                #include <asm/ptrace.h>
                #include <linux/bpf.h>
                #include <linux/btf.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/mount.h>
        #include <sys/socket.h>
        #include <sys/syscall.h>
        #include <sys/stat.h>
        #include <unistd.h>

        static int load_prog_attach(enum bpf_prog_type type,
                                    enum bpf_attach_type attach_type,
                                    const char *name, int retval)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = retval,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = type;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.expected_attach_type = attach_type;
          if (name)
            snprintf(attr.prog_name, sizeof(attr.prog_name), "%s", name);

          fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
          if (fd < 0)
            return -errno;

                  return fd;
                }

        static int load_prog(enum bpf_prog_type type, const char *name, int retval)
        {
          return load_prog_attach(type, BPF_CGROUP_INET_INGRESS, name, retval);
        }

        static int load_cgroup_sock_addr_probe(int retval)
        {
          return load_prog_attach(BPF_PROG_TYPE_CGROUP_SOCK_ADDR,
                                  BPF_CGROUP_INET4_CONNECT,
                                  NULL, retval);
        }

                static int load_raw_ctx_kprobe_prog(void)
                {
                  struct bpf_insn insns[] = {
                    {
                      .code = BPF_LDX | BPF_DW | BPF_MEM,
                      .dst_reg = BPF_REG_0,
                      .src_reg = BPF_REG_1,
                      .off = offsetof(struct pt_regs, rdi),
                    },
                    {
                      .code = BPF_JMP | BPF_EXIT,
                    },
                  };
                  union bpf_attr attr;
                  int fd;

                  memset(&attr, 0, sizeof(attr));
                  attr.prog_type = BPF_PROG_TYPE_KPROBE;
                  attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
                  attr.insns = (uint64_t)(uintptr_t)insns;
                  attr.license = (uint64_t)(uintptr_t)"GPL";
                  snprintf(attr.prog_name, sizeof(attr.prog_name), "raw_ctx");

                  fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
                  if (fd < 0)
                    return -errno;

                  return fd;
                }

                static int load_minimal_btf(void)
                {
                  struct btf_raw {
                    struct btf_header hdr;
                    struct btf_type type;
                    uint32_t int_data;
                    char strs[5];
                  } __attribute__((packed)) raw;
                  union bpf_attr attr;
                  int fd;

                  memset(&raw, 0, sizeof(raw));
                  raw.hdr.magic = BTF_MAGIC;
                  raw.hdr.version = BTF_VERSION;
                  raw.hdr.hdr_len = sizeof(struct btf_header);
                  raw.hdr.type_len = sizeof(struct btf_type) + sizeof(uint32_t);
                  raw.hdr.str_off = raw.hdr.type_len;
                  raw.hdr.str_len = sizeof(raw.strs);
                  raw.type.name_off = 1;
                  raw.type.info = BTF_KIND_INT << 24;
                  raw.type.size = 4;
                  raw.int_data = (BTF_INT_SIGNED << 24) | 32;
                  memcpy(raw.strs, "\0int", sizeof(raw.strs));

                  memset(&attr, 0, sizeof(attr));
                  attr.btf = (uint64_t)(uintptr_t)&raw;
                  attr.btf_size = sizeof(raw);

                  fd = syscall(SYS_bpf, BPF_BTF_LOAD, &attr, sizeof(attr));
                  if (fd < 0)
                    return -errno;

                  return fd;
                }

                static int load_global_data_probe(int map_fd, int value)
                {
                  struct bpf_insn insns[] = {
                    {
                      .code = BPF_LD | BPF_DW | BPF_IMM,
                      .dst_reg = BPF_REG_1,
                      .src_reg = BPF_PSEUDO_MAP_VALUE,
                      .imm = map_fd,
                    },
                    {
                      .imm = 16,
                    },
                    {
                      .code = BPF_ST | BPF_DW | BPF_MEM,
                      .dst_reg = BPF_REG_1,
                      .imm = value,
                    },
                    {
                      .code = BPF_ALU64 | BPF_MOV | BPF_K,
                      .dst_reg = BPF_REG_0,
                    },
                    {
                      .code = BPF_JMP | BPF_EXIT,
                    },
                  };
                  union bpf_attr attr;
                  int fd;

                  memset(&attr, 0, sizeof(attr));
                  attr.prog_type = BPF_PROG_TYPE_SOCKET_FILTER;
                  attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
                  attr.insns = (uint64_t)(uintptr_t)insns;
                  attr.license = (uint64_t)(uintptr_t)"GPL";

                  fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
                  if (fd < 0)
                    return -errno;

                  return fd;
                }

                static int prog_test_run_errno(int fd)
                {
                  union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.test.prog_fd = fd;

          if (syscall(SYS_bpf, BPF_PROG_TEST_RUN, &attr, sizeof(attr)) == 0)
            return 0;

          return errno;
        }

        static int prog_info_errno(int fd)
        {
          struct bpf_prog_info info;
          union bpf_attr attr;

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          attr.info.bpf_fd = fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (syscall(SYS_bpf, BPF_OBJ_GET_INFO_BY_FD, &attr, sizeof(attr)) == 0)
            return 0;

          return errno;
        }

        static int obj_pin_errno(int fd)
        {
          const char *path = "/sys/fs/bpf/vpsadminos-libbpf-probe-pin";
          union bpf_attr attr;

          unlink(path);

          memset(&attr, 0, sizeof(attr));
          attr.bpf_fd = fd;
          attr.pathname = (uint64_t)(uintptr_t)path;

          if (syscall(SYS_bpf, BPF_OBJ_PIN, &attr, sizeof(attr)) == 0) {
            unlink(path);
            return 0;
          }

          return errno;
        }

        static int link_create_errno(int fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = fd;
          attr.link_create.target_fd = 0;
          attr.link_create.attach_type = BPF_PERF_EVENT;

          if (syscall(SYS_bpf, BPF_LINK_CREATE, &attr, sizeof(attr)) == 0)
            return 0;

          return errno;
        }

        static int get_next_id_errno(enum bpf_cmd cmd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));

          if (syscall(SYS_bpf, cmd, &attr, sizeof(attr)) == 0)
            return 0;

          return errno;
        }

        static int get_fd_by_id_errno(enum bpf_cmd cmd)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          switch (cmd) {
          case BPF_MAP_GET_FD_BY_ID:
            attr.map_id = 1;
            break;
          case BPF_PROG_GET_FD_BY_ID:
            attr.prog_id = 1;
            break;
          case BPF_LINK_GET_FD_BY_ID:
            attr.link_id = 1;
            break;
          case BPF_BTF_GET_FD_BY_ID:
            attr.btf_id = 1;
            break;
          default:
            return EINVAL;
          }

          fd = syscall(SYS_bpf, cmd, &attr, sizeof(attr));
          if (fd >= 0) {
            close(fd);
            return 0;
          }

          return errno;
        }

        static int get_map_id(int map_fd, uint32_t *id)
        {
          struct bpf_map_info info;
          union bpf_attr attr;

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          attr.info.bpf_fd = map_fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (syscall(SYS_bpf, BPF_OBJ_GET_INFO_BY_FD, &attr, sizeof(attr)) < 0)
            return errno;

          *id = info.id;
          return 0;
        }

        static int get_map_fd_by_id_errno(uint32_t id)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_id = id;

          fd = syscall(SYS_bpf, BPF_MAP_GET_FD_BY_ID, &attr, sizeof(attr));
          if (fd >= 0) {
            close(fd);
            return 0;
          }

          return errno;
        }

        static int load_kprobe_attach_prog(enum bpf_attach_type attach_type,
                                           const char *name)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_KPROBE;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.expected_attach_type = attach_type;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "%s", name);

          fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int load_raw_tracepoint_prog_with_token(int token_fd)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_RAW_TRACEPOINT;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.prog_flags = BPF_F_TOKEN_FD;
          attr.prog_token_fd = token_fd;

          fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof(attr));
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int btf_get_fd_by_id_with_token_errno(int token_fd)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.btf_id = 1;
          attr.open_flags = BPF_F_TOKEN_FD;
          attr.fd_by_id_token_fd = token_fd;

          fd = syscall(SYS_bpf, BPF_BTF_GET_FD_BY_ID, &attr, sizeof(attr));
          if (fd >= 0) {
            close(fd);
            return 0;
          }

          return errno;
        }

        static int create_broad_bpffs_token(void)
        {
          const char *path = "/tmp/vpsadminos-broad-bpffs-token";
          union bpf_attr attr;
          int dir_fd;
          int token_fd;
          int saved_errno;

          if (mkdir(path, 0700) < 0 && errno != EEXIST)
            return -errno;

          if (mount("bpf", path, "bpf", 0,
                    "delegate_cmds=any,delegate_maps=any,"
                    "delegate_progs=any,delegate_attachs=any") < 0)
            return -errno;

          dir_fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (dir_fd < 0) {
            saved_errno = errno;
            umount2(path, MNT_DETACH);
            return -saved_errno;
          }

          memset(&attr, 0, sizeof(attr));
          attr.token_create.bpffs_fd = dir_fd;
          token_fd = syscall(SYS_bpf, BPF_TOKEN_CREATE, &attr, sizeof(attr));
          saved_errno = errno;
          close(dir_fd);
          if (token_fd < 0) {
            umount2(path, MNT_DETACH);
            return -saved_errno;
          }

          return token_fd;
        }

        static int link_create_kprobe_multi_errno(int fd)
        {
          const char *sym = "tcp_v4_connect";
          union bpf_attr attr;
          int link_fd;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = fd;
          attr.link_create.attach_type = BPF_TRACE_KPROBE_MULTI;
          attr.link_create.kprobe_multi.syms = (uint64_t)(uintptr_t)&sym;
          attr.link_create.kprobe_multi.cnt = 1;

          link_fd = syscall(SYS_bpf, BPF_LINK_CREATE, &attr, sizeof(attr));
          if (link_fd >= 0) {
            close(link_fd);
            return 0;
          }

          return errno;
        }

        static int link_create_uprobe_multi_errno(int fd)
        {
          const char *path = "/run/current-system/sw/bin/true";
          unsigned long offset = 0;
          union bpf_attr attr;
          int link_fd;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = fd;
          attr.link_create.attach_type = BPF_TRACE_UPROBE_MULTI;
          attr.link_create.uprobe_multi.path = (uint64_t)(uintptr_t)path;
          attr.link_create.uprobe_multi.offsets = (uint64_t)(uintptr_t)&offset;
          attr.link_create.uprobe_multi.cnt = 1;

          link_fd = syscall(SYS_bpf, BPF_LINK_CREATE, &attr, sizeof(attr));
          if (link_fd >= 0) {
            close(link_fd);
            return 0;
          }

          return errno;
        }

        static int create_array_map(void)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint64_t);
          attr.max_entries = 1;

          fd = syscall(SYS_bpf, BPF_MAP_CREATE, &attr, sizeof(attr));
          if (fd < 0)
            return -errno;

                  return fd;
                }

                static int create_global_data_map(void)
                {
                  union bpf_attr attr;
                  int fd;

                  memset(&attr, 0, sizeof(attr));
                  attr.map_type = BPF_MAP_TYPE_ARRAY;
                  attr.key_size = sizeof(uint32_t);
                  attr.value_size = 32;
                  attr.max_entries = 1;
                  snprintf(attr.map_name, sizeof(attr.map_name), "libbpf_global");

                  fd = syscall(SYS_bpf, BPF_MAP_CREATE, &attr, sizeof(attr));
                  if (fd < 0)
                    return -errno;

                  return fd;
                }

                static int create_prog_array_map(void)
                {
                  union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_PROG_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint32_t);
          attr.max_entries = 1;

          fd = syscall(SYS_bpf, BPF_MAP_CREATE, &attr, sizeof(attr));
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int bind_map_errno(int prog_fd)
        {
          union bpf_attr attr;
          int map_fd;
          int err;

          map_fd = create_array_map();
          if (map_fd < 0) {
            fprintf(stderr, "array map create failed errno=%d\n", -map_fd);
            exit(1);
          }

          memset(&attr, 0, sizeof(attr));
          attr.prog_bind_map.prog_fd = prog_fd;
          attr.prog_bind_map.map_fd = map_fd;

          if (syscall(SYS_bpf, BPF_PROG_BIND_MAP, &attr, sizeof(attr)) == 0)
            err = 0;
          else
            err = errno;

          close(map_fd);
          return err;
        }

        static int prog_array_update_errno(int prog_fd)
        {
          union bpf_attr attr;
          uint32_t key = 0;
          uint32_t value = (uint32_t)prog_fd;
          int map_fd;
          int err;

          map_fd = create_prog_array_map();
          if (map_fd < 0) {
            fprintf(stderr, "prog array map create failed errno=%d\n", -map_fd);
            exit(1);
          }

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&value;
          attr.flags = BPF_ANY;

          if (syscall(SYS_bpf, BPF_MAP_UPDATE_ELEM, &attr, sizeof(attr)) == 0)
            err = 0;
          else
            err = errno;

          close(map_fd);
          return err;
        }

        static int socket_attach_errno(int fd)
        {
          int sock = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
          int err;

          if (sock < 0)
            return errno;

          if (setsockopt(sock, SOL_SOCKET, SO_ATTACH_BPF, &fd, sizeof(fd)) == 0)
            err = 0;
          else
            err = errno;

          close(sock);
          return err;
        }

        static int current_cgroup_fd(void)
        {
          char line[4096];
          FILE *f;
          int fd = -ENOENT;

          f = fopen("/proc/self/cgroup", "re");
          if (!f)
            return -errno;

          while (fgets(line, sizeof(line), f)) {
            char path[4096];
            char *cgpath;

            if (strncmp(line, "0::", 3) != 0)
              continue;

            cgpath = line + 3;
            cgpath[strcspn(cgpath, "\n")] = 0;
            snprintf(path, sizeof(path), "/sys/fs/cgroup%s", cgpath);
            fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (fd < 0)
              fd = -errno;
            break;
          }

          fclose(f);
          return fd;
        }

        static int cgroup_link_create_errno(int cgroup_fd, int prog_fd,
                                            enum bpf_attach_type attach_type)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = prog_fd;
          attr.link_create.target_fd = cgroup_fd;
          attr.link_create.attach_type = attach_type;

          if (syscall(SYS_bpf, BPF_LINK_CREATE, &attr, sizeof(attr)) == 0)
            return 0;

          return errno;
        }

        static int current_cgroup_link_create_errno(int prog_fd,
                                                    enum bpf_attach_type attach_type)
        {
          int cgroup_fd;
          int err;

          cgroup_fd = current_cgroup_fd();
          if (cgroup_fd < 0) {
            fprintf(stderr, "current cgroup open failed errno=%d\n", -cgroup_fd);
            exit(1);
          }

          err = cgroup_link_create_errno(cgroup_fd, prog_fd, attach_type);
          close(cgroup_fd);
          return err;
        }

        static int cgroup_prog_attach_errno(int prog_fd,
                                            enum bpf_attach_type attach_type)
        {
          union bpf_attr attr;
          int cgroup_fd;
          int err;

          cgroup_fd = current_cgroup_fd();
          if (cgroup_fd < 0) {
            fprintf(stderr, "current cgroup open failed errno=%d\n", -cgroup_fd);
            exit(1);
          }

          memset(&attr, 0, sizeof(attr));
          attr.target_fd = cgroup_fd;
          attr.attach_bpf_fd = prog_fd;
          attr.attach_type = attach_type;

          if (syscall(SYS_bpf, BPF_PROG_ATTACH, &attr, sizeof(attr)) == 0)
            err = 0;
          else
            err = errno;

          close(cgroup_fd);
          return err;
        }

        static void expect_errno(const char *name, int got, int expected)
        {
          printf("%s_errno=%d\n", name, got);
          if (got != expected) {
            fprintf(stderr, "%s got errno %d, expected %d\n", name, got, expected);
            exit(1);
          }
        }

        static void expect_nonzero_errno(const char *name, int got)
        {
          printf("%s_errno=%d\n", name, got);
          if (got == 0) {
            fprintf(stderr, "%s unexpectedly succeeded\n", name);
            exit(1);
          }
        }

                        int main(void)
                        {
                          int tracepoint_fd = load_prog(BPF_PROG_TYPE_TRACEPOINT, NULL, 0);
                          int sock_fd = load_prog(BPF_PROG_TYPE_SOCKET_FILTER, "libbpf_nametest", 0);
                          int sock_addr_fd = load_cgroup_sock_addr_probe(0);
                          int kprobe_multi_fd;
                          int uprobe_multi_fd;
                  int global_map_fd;
                  uint32_t global_map_id;
                  int global_fd;
                  int btf_fd;
                  int token_fd;
                  int raw_ctx_fd;
                  int err;

                  btf_fd = load_minimal_btf();
                  if (btf_fd < 0) {
                    fprintf(stderr, "minimal BTF load failed errno=%d\n", -btf_fd);
                    return 1;
                  }
                  printf("container_btf_load=1\n");
                  close(btf_fd);

                  if (tracepoint_fd < 0) {
                    fprintf(stderr, "tracepoint program load failed errno=%d\n", -tracepoint_fd);
                    return 1;
                  }
          printf("container_tracepoint_prog_load=1\n");

          if (sock_fd < 0) {
            fprintf(stderr, "socket filter probe load failed errno=%d\n", -sock_fd);
            return 1;
                  }
                  printf("container_libbpf_socket_filter_probe_load=1\n");

                  if (sock_addr_fd < 0) {
                    fprintf(stderr, "cgroup sock addr probe load failed errno=%d\n",
                            -sock_addr_fd);
                    return 1;
                  }
                  printf("container_libbpf_cgroup_sock_addr_probe_load=1\n");

                  global_map_fd = create_global_data_map();
                  if (global_map_fd < 0) {
                    fprintf(stderr, "global data map create failed errno=%d\n", -global_map_fd);
                    return 1;
                  }

                  err = get_map_id(global_map_fd, &global_map_id);
                  if (err != 0) {
                    fprintf(stderr, "global data map info failed errno=%d\n", err);
                    return 1;
                  }

                  expect_errno(
                    "container_same_map_get_fd_by_id",
                    get_map_fd_by_id_errno(global_map_id),
                    0
                  );

                  global_fd = load_global_data_probe(global_map_fd, 42);
                  if (global_fd < 0) {
                    fprintf(stderr, "global data probe load failed errno=%d\n", -global_fd);
                    return 1;
                  }
                          printf("container_libbpf_global_data_probe_load=1\n");

                          kprobe_multi_fd = load_kprobe_attach_prog(BPF_TRACE_KPROBE_MULTI,
                                                                   "kprobe_multi");
                          if (kprobe_multi_fd < 0) {
                            fprintf(stderr, "kprobe multi probe load failed errno=%d\n",
                                    -kprobe_multi_fd);
                            return 1;
                          }
                          printf("container_kprobe_multi_probe_load=1\n");

                          uprobe_multi_fd = load_kprobe_attach_prog(BPF_TRACE_UPROBE_MULTI,
                                                                   "uprobe_multi");
                          if (uprobe_multi_fd < 0) {
                            fprintf(stderr, "uprobe multi probe load failed errno=%d\n",
                                    -uprobe_multi_fd);
                            return 1;
                          }
                          printf("container_uprobe_multi_probe_load=1\n");

                          err = load_prog(BPF_PROG_TYPE_RAW_TRACEPOINT, NULL, 0);
                          expect_errno("container_raw_tracepoint_prog_load", -err, EPERM);

                          err = load_prog(BPF_PROG_TYPE_TRACING, NULL, 0);
                          expect_errno("container_tracing_prog_load", -err, EPERM);

          err = load_prog(BPF_PROG_TYPE_SYSCALL, NULL, 0);
          expect_errno("container_syscall_prog_load", -err, EPERM);

          token_fd = create_broad_bpffs_token();
          if (token_fd >= 0) {
            fprintf(stderr, "broad bpffs token unexpectedly created\n");
            close(token_fd);
            return 1;
          }
          expect_errno("container_broad_bpffs_token_create", -token_fd, EPERM);

          expect_errno(
            "container_map_get_next_id",
                            get_next_id_errno(BPF_MAP_GET_NEXT_ID),
                            EPERM
                          );
                          expect_errno(
                            "container_prog_get_next_id",
                            get_next_id_errno(BPF_PROG_GET_NEXT_ID),
                            EPERM
                          );
                          expect_errno(
                            "container_link_get_next_id",
                            get_next_id_errno(BPF_LINK_GET_NEXT_ID),
                            EPERM
                          );
                          expect_errno(
                            "container_btf_get_next_id",
                            get_next_id_errno(BPF_BTF_GET_NEXT_ID),
                            EPERM
                          );
          expect_nonzero_errno(
            "container_map_get_fd_by_unknown_id",
            get_map_fd_by_id_errno(UINT32_MAX)
          );
                          expect_errno(
                            "container_prog_get_fd_by_id",
                            get_fd_by_id_errno(BPF_PROG_GET_FD_BY_ID),
                            EPERM
                          );
                          expect_errno(
                            "container_link_get_fd_by_id",
                            get_fd_by_id_errno(BPF_LINK_GET_FD_BY_ID),
                            EPERM
                          );
                          expect_errno(
                            "container_btf_get_fd_by_id",
                            get_fd_by_id_errno(BPF_BTF_GET_FD_BY_ID),
                            EPERM
                          );

                  err = load_prog(BPF_PROG_TYPE_SOCKET_FILTER, "libbpf_nametest", 1);
                  expect_errno("container_libbpf_socket_filter_nonprobe_load", -err, EPERM);

                  err = load_cgroup_sock_addr_probe(1);
                  expect_errno("container_libbpf_cgroup_sock_addr_nonprobe_load",
                               -err, EPERM);

                  err = load_global_data_probe(global_map_fd, 43);
                  expect_errno("container_libbpf_global_data_nonprobe_load", -err, EPERM);

                  raw_ctx_fd = load_raw_ctx_kprobe_prog();
                  if (raw_ctx_fd < 0) {
                    fprintf(stderr, "raw ctx kprobe load failed errno=%d\n", -raw_ctx_fd);
                    return 1;
                  }
                  printf("container_raw_ctx_kprobe_load=1\n");
                  expect_errno(
                    "container_raw_ctx_kprobe_prog_array_update",
                    prog_array_update_errno(raw_ctx_fd),
                    EPERM
                  );
                  close(raw_ctx_fd);

          expect_errno(
            "container_libbpf_socket_filter_probe_test_run",
            prog_test_run_errno(sock_fd),
            EPERM
          );
          expect_errno(
            "container_libbpf_socket_filter_probe_info",
            prog_info_errno(sock_fd),
            EPERM
          );
          expect_nonzero_errno(
            "container_libbpf_socket_filter_probe_pin",
            obj_pin_errno(sock_fd)
          );
          expect_errno(
            "container_libbpf_socket_filter_probe_bind_map",
            bind_map_errno(sock_fd),
            EPERM
          );
          expect_errno(
            "container_libbpf_socket_filter_probe_prog_array_update",
            prog_array_update_errno(sock_fd),
            EPERM
          );
          expect_nonzero_errno(
            "container_libbpf_socket_filter_probe_attach",
                    socket_attach_errno(sock_fd)
                  );
                  expect_errno(
                    "container_libbpf_cgroup_sock_addr_probe_test_run",
                    prog_test_run_errno(sock_addr_fd),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_cgroup_sock_addr_probe_info",
                    prog_info_errno(sock_addr_fd),
                    EPERM
                  );
                  expect_nonzero_errno(
                    "container_libbpf_cgroup_sock_addr_probe_pin",
                    obj_pin_errno(sock_addr_fd)
                  );
                  expect_errno(
                    "container_libbpf_cgroup_sock_addr_probe_bind_map",
                    bind_map_errno(sock_addr_fd),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_cgroup_sock_addr_probe_prog_array_update",
                    prog_array_update_errno(sock_addr_fd),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_cgroup_sock_addr_probe_invalid_link_create",
                    cgroup_link_create_errno(-1, sock_addr_fd, BPF_CGROUP_INET4_CONNECT),
                    EBADF
                  );
                  expect_errno(
                    "container_libbpf_cgroup_sock_addr_probe_link_create",
                    current_cgroup_link_create_errno(sock_addr_fd,
                                                     BPF_CGROUP_INET4_CONNECT),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_cgroup_sock_addr_probe_prog_attach",
                    cgroup_prog_attach_errno(sock_addr_fd, BPF_CGROUP_INET4_CONNECT),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_global_data_probe_test_run",
                    prog_test_run_errno(global_fd),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_global_data_probe_info",
                    prog_info_errno(global_fd),
                    EPERM
                  );
                  expect_nonzero_errno(
                    "container_libbpf_global_data_probe_pin",
                    obj_pin_errno(global_fd)
                  );
                  expect_errno(
                    "container_libbpf_global_data_probe_bind_map",
                    bind_map_errno(global_fd),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_global_data_probe_prog_array_update",
                    prog_array_update_errno(global_fd),
                    EPERM
                  );
                  expect_errno(
                    "container_libbpf_global_data_probe_link_create",
                    link_create_errno(global_fd),
                    EPERM
                  );
                          expect_nonzero_errno(
                            "container_libbpf_global_data_probe_attach",
                            socket_attach_errno(global_fd)
                          );
                          expect_errno(
                            "container_kprobe_multi_link_create",
                            link_create_kprobe_multi_errno(kprobe_multi_fd),
                            EACCES
                          );
                          expect_errno(
                            "container_uprobe_multi_link_create",
                            link_create_uprobe_multi_errno(uprobe_multi_fd),
                            EACCES
                          );

                          close(tracepoint_fd);
                          close(sock_fd);
                          close(sock_addr_fd);
                          close(kprobe_multi_fd);
                          close(uprobe_multi_fd);
                          close(global_fd);
                          close(global_map_fd);
                          return 0;
                }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o bpf-load-probe-smoke
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 bpf-load-probe-smoke $out/bin/bpf-load-probe-smoke
        runHook postInstall
      '';
    };

    tcpConnectWork = pkgs.stdenv.mkDerivation {
      pname = "vpsadminos-tcp-connect-work";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "tcp-connect-work.c" ''
        #include <arpa/inet.h>
        #include <netinet/in.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/socket.h>
        #include <unistd.h>

        int main(int argc, char **argv)
        {
          struct sockaddr_in addr;
          int count = 20;

          if (argc > 1)
            count = atoi(argv[1]);
          if (count < 1)
            count = 1;

          memset(&addr, 0, sizeof(addr));
          addr.sin_family = AF_INET;
          addr.sin_port = htons(1);
          addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

          for (int i = 0; i < count; i++) {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
              perror("socket");
              return 1;
            }

            (void)connect(fd, (struct sockaddr *)&addr, sizeof(addr));
            close(fd);
          }

          return 0;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o tcp-connect-work
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 tcp-connect-work $out/bin/tcp-connect-work
        ln -s tcp-connect-work $out/bin/ctconnect
        ln -s tcp-connect-work $out/bin/peerconnect
        ln -s tcp-connect-work $out/bin/hostconnect
        ln -s tcp-connect-work $out/bin/tracing-tcp-connect-work
        runHook postInstall
      '';
    };

    mkTracingContainer = kernel: tracingPackages: {
      user = "testuser";

      shareStore = true;

      autostart.enable = true;

      startMenu.enable = false;

      prlimits.memlock = {
        soft = "unlimited";
        hard = "unlimited";
      };

      config =
        { pkgs, ... }:
        {
          documentation.enable = false;
          documentation.nixos.enable = false;

          environment.systemPackages = tracingPackages ++ [
            pkgs.coreutils
            pkgs.flamegraph
            pkgs.gawk
            pkgs.gnugrep
            pkgs.gnused
            pkgs.kmod
            pkgs.procps
            pkgs.python3
            pkgs.strace
            pkgs.util-linux
            bpfLoadProbeSmoke
            btfFdLeakProbe
            tcpConnectWork
            perfFdLeakProbe
            tracework
          ];

          system.systemBuilderCommands = ''
            mkdir -p $out/kernel-modules/lib/modules
            ln -s ${kernel.dev}/lib/modules/${kernel.modDirVersion} \
              $out/kernel-modules/lib/modules/${kernel.modDirVersion}
          '';
        };
    };
  in
  {
    name = "kernel-tracing-tools";

    description = ''
      Test vpsAdminOS tracing namespace tooling in containers
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, lib, ... }:
        let
          bccPythonSmoke = pkgs.writeShellScriptBin "bcc-python-smoke" ''
            set -eu
            export PYTHONPATH=${config.boot.kernelPackages.bcc}/lib/python${pkgs.python3.pythonVersion}/site-packages''${PYTHONPATH:+:}''${PYTHONPATH:-}
            exec ${pkgs.python3}/bin/python3 - <<'PY'
            import ctypes as ct
            from bcc import BPF

            bpf = BPF(text="BPF_HASH(counts, u32, u64, 4);")
            counts = bpf.get_table("counts")
            key = ct.c_uint(0)
            value = ct.c_ulonglong(42)
            counts[key] = value
            assert counts[key].value == 42
            print("bcc_map_value=%d" % counts[key].value)
            PY
          '';
          bccPerfEventSmoke = pkgs.writeShellScriptBin "bcc-perf-event-smoke" ''
            set -eu
            export PYTHONPATH=${config.boot.kernelPackages.bcc}/lib/python${pkgs.python3.pythonVersion}/site-packages''${PYTHONPATH:+:}''${PYTHONPATH:-}
            exec ${pkgs.python3}/bin/python3 - <<'PY'
            import ctypes as ct
            import fcntl
            import os
            import time
            from bcc import BPF, PerfSWConfig, PerfType
            from bcc.perf import Perf

            PERF_EVENT_IOC_SET_BPF = 0x40042408

            bpf = BPF(text=r"""
            BPF_HASH(counts, u32, u64, 1);

            int on_sample(struct bpf_perf_event_data *ctx)
            {
              u32 key = 0;
              u64 zero = 0;
              u64 *value = counts.lookup_or_init(&key, &zero);

              if (value)
                __sync_fetch_and_add(value, 1);

              return 0;
            }
            """)
            fn = bpf.load_func("on_sample", BPF.PERF_EVENT)

            attr = Perf.perf_event_attr()
            attr.type = PerfType.SOFTWARE
            attr.config = PerfSWConfig.CPU_CLOCK
            attr.freq = 1
            attr.sample_freq = 49
            attr.disabled = 1
            attr.exclude_kernel = 1
            attr.exclude_hv = 1

            fd = Perf.syscall(
              Perf.NR_PERF_EVENT_OPEN,
              ct.byref(attr),
              0,
              -1,
              -1,
              Perf.PERF_FLAG_FD_CLOEXEC,
            )
            if fd < 0:
              err = ct.get_errno()
              raise OSError(err, os.strerror(err))

            counts = bpf.get_table("counts")
            key = ct.c_uint(0)
            deadline = time.time() + 3.0
            value = 0

            try:
              fcntl.ioctl(fd, PERF_EVENT_IOC_SET_BPF, fn.fd)
              fcntl.ioctl(fd, Perf.PERF_EVENT_IOC_ENABLE, 0)

              while time.time() < deadline:
                for i in range(50000):
                  value += (i * 1103515245 + 12345) >> 8
                try:
                  samples = counts[key].value
                except KeyError:
                  samples = 0
                if samples > 0:
                  print("bcc_perf_event_samples=%d" % samples)
                  break
              else:
                raise RuntimeError("perf event BPF program did not observe any samples")
            finally:
              os.close(fd)
            PY
          '';
          bccIsolationSmoke = pkgs.writeShellScriptBin "bcc-isolation-smoke" ''
            set -eu
            export PYTHONPATH=${config.boot.kernelPackages.bcc}/lib/python${pkgs.python3.pythonVersion}/site-packages''${PYTHONPATH:+:}''${PYTHONPATH:-}
            exec ${pkgs.python3}/bin/python3 - <<'PY'
            from bcc import BPF

            def expect_denied(name, fn):
              try:
                fn()
              except Exception as e:
                print("bcc_denied_%s=%s" % (name, str(e).splitlines()[0]))
                return
              raise RuntimeError("%s unexpectedly succeeded" % name)

            def denied_kprobe():
              b = BPF(text=r"""
              int on_read(void *ctx)
              {
                return 0;
              }
              """)
              b.attach_kprobe(event="vfs_read", fn_name="on_read")

            def allowed_kprobe_same_namespace():
              import ctypes as ct
              import os
              import socket
              import sys
              import time

              b = BPF(text=r"""
              BPF_HASH(counts, u32, u64, 1);

              int on_connect(void *ctx)
              {
                u32 key = 0;
                u64 zero = 0;
                u64 *value = counts.lookup_or_init(&key, &zero);

                if (value)
                  __sync_fetch_and_add(value, 1);

                return 0;
              }
              """)
              b.attach_kprobe(event="tcp_v4_connect", fn_name="on_connect")

              counts = b.get_table("counts")
              key = ct.c_uint(0)
              samples = 0
              deadline = time.time() + 3.0
              while time.time() < deadline:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(0.2)
                try:
                  sock.connect(("127.0.0.1", 9))
                except OSError:
                  pass
                finally:
                  sock.close()

                try:
                  samples = counts[key].value
                except KeyError:
                  samples = 0

                if samples > 0:
                  break
                time.sleep(0.1)

              if samples <= 0:
                raise RuntimeError("allowlisted kprobe did not observe same-namespace tcp_v4_connect")

              print("bcc_allowed_kprobe_tcp_v4_connect_hits=%d" % samples)
              sys.stdout.flush()
              os._exit(0)

            def denied_raw_tracepoint():
              b = BPF(text=r"""
              int on_fork(void *ctx)
              {
                return 0;
              }
              """)
              b.attach_raw_tracepoint(tp="sched_process_fork", fn_name="on_fork")

            def denied_tracepoint():
              b = BPF(text=r"""
              int on_fork(void *ctx)
              {
                return 0;
              }
              """)
              b.attach_tracepoint(tp="sched:sched_process_fork", fn_name="on_fork")

            def denied_probe_read_kernel():
              b = BPF(text=r"""
              int on_wake(void *ctx)
              {
                unsigned long value = 0;
                bpf_probe_read_kernel(&value, sizeof(value), (void *)0xffffffff81000000ULL);
                return value != 0;
              }
              """)
              b.load_func("on_wake", BPF.KPROBE)

            def denied_current_task_pointer():
              b = BPF(text=r"""
              BPF_ARRAY(leaked_tasks, u32, u64, 1);

              int on_wake(void *ctx)
              {
                u32 key = 0;
                u64 task = (u64)bpf_get_current_task();

                leaked_tasks.update(&key, &task);
                return 0;
              }
              """)
              b.load_func("on_wake", BPF.KPROBE)

            def denied_retire_userns_raw_arg():
              b = BPF(text=r"""
              #include <uapi/linux/ptrace.h>
              int on_retire(struct pt_regs *ctx)
              {
                unsigned long userns = PT_REGS_PARM1(ctx);
                return userns != 0;
              }
              """)
              b.attach_kprobe(event="retire_userns_sysctls", fn_name="on_retire")

            def denied_free_user_ns_raw_arg():
              b = BPF(text=r"""
              #include <uapi/linux/ptrace.h>
              int on_free(struct pt_regs *ctx)
              {
                unsigned long work = PT_REGS_PARM1(ctx);
                return work != 0;
              }
              """)
              b.attach_kprobe(event="free_user_ns", fn_name="on_free")

            expect_denied("kprobe_forbidden_symbol", denied_kprobe)
            expect_denied("raw_tracepoint", denied_raw_tracepoint)
            expect_denied("tracepoint", denied_tracepoint)
            expect_denied("probe_read_kernel", denied_probe_read_kernel)
            expect_denied("current_task_pointer", denied_current_task_pointer)
            expect_denied("retire_userns_raw_arg", denied_retire_userns_raw_arg)
            expect_denied("free_user_ns_raw_arg", denied_free_user_ns_raw_arg)
            allowed_kprobe_same_namespace()
            PY
          '';
          bccToolsSmoke = pkgs.writeShellScriptBin "bcc-tools-smoke" ''
            set -eu

            work=/tmp/bcc-tools
            rm -rf "$work"
            mkdir -p "$work"

            dump_tool_logs() {
              name=$1
              for suffix in out err; do
                file="$work/$name.$suffix"
                [ -s "$file" ] || continue
                printf -- '--- %s\n' "$file" >&2
                cat "$file" >&2
              done
            }

            classify_tool() {
              name=$1
              shift
              out="$work/$name.out"
              err="$work/$name.err"

              set +e
              timeout 15 "$@" >"$out" 2>"$err"
              status=$?
              set -e

              if [ "$status" -eq 124 ]; then
                if [ -s "$out" ]; then
                  printf 'BCC tool timed out after producing output: %s\n' "$name" >&2
                  dump_tool_logs "$name"
                  exit 1
                fi

                printf 'bcc_tool_inert_%s_status=%s\n' "$name" "$status"
                return
              fi

              if [ "$status" -eq 0 ]; then
                printf 'BCC tool unexpectedly usable: %s status=%s\n' "$name" "$status" >&2
                dump_tool_logs "$name"
                exit 1
              fi

              printf 'bcc_tool_denied_%s_status=%s\n' "$name" "$status"
            }

                classify_funccount_uprobe() {
                  out="$work/funccount-uprobe.out"
                  err="$work/funccount-uprobe.err"
                  target=$(readlink -f "$(command -v tracework)")

              (
                end=$(( $(date +%s) + 5 ))
                while [ "$(date +%s)" -lt "$end" ]; do
                  tracework 1 >/dev/null
                done
              ) &
              workload=$!

              set +e
              timeout 20 funccount -d 5 "$target:main" >"$out" 2>"$err"
              status=$?
                  wait "$workload" 2>/dev/null || true
                  set -e

                  if grep -Eq '^main[[:space:]]+[1-9][0-9]*$' "$out"; then
                    printf 'BCC funccount uprobe unexpectedly observed same-namespace workload: status=%s\n' "$status" >&2
                    dump_tool_logs funccount-uprobe
                    exit 1
                  fi

                  printf 'bcc_tool_unsupported_funccount_uprobe_status=%s\n' "$status"
                }

            for tool in execsnoop funccount opensnoop runqlat tcpconnect; do
              command -v "$tool" >/dev/null
            done

                classify_funccount_uprobe
                classify_tool execsnoop execsnoop
                classify_tool opensnoop opensnoop
                classify_tool runqlat runqlat 1 1
            classify_tool tcpconnect tcpconnect
          '';
          bpftraceIsolationSmoke = pkgs.writeShellScriptBin "bpftrace-isolation-smoke" ''
            set -eu
            ulimit -l unlimited 2>/dev/null || true

            work=/tmp/bpftrace-isolation
            rm -rf "$work"
            mkdir -p "$work"

            before_ns=$(readlink /proc/self/ns/tracing)
            printf 'bpftrace_version=%s\n' "$(bpftrace --version | head -n 1)"

            dump_probe_logs() {
              name=$1
              for suffix in out err; do
                file="$work/$name.$suffix"
                [ -s "$file" ] || continue
                printf -- '--- %s\n' "$file" >&2
                cat "$file" >&2
              done
            }

            fail_probe() {
              name=$1
              status=$2
              printf 'bpftrace isolation failure: %s status=%s\n' "$name" "$status" >&2
              dump_probe_logs "$name"
              exit 1
            }

            expect_denied() {
              name=$1
              shift
              out="$work/$name.out"
              err="$work/$name.err"

              set +e
              timeout 15 "$@" >"$out" 2>"$err"
              status=$?
              set -e

              if [ "$status" -eq 0 ] || [ "$status" -eq 124 ]; then
                fail_probe "$name" "$status"
              fi

              printf 'bpftrace_denied_%s_status=%s\n' "$name" "$status"
            }

            expect_shell_denied() {
              name=$1
              script=$2
              out="$work/$name.out"
              err="$work/$name.err"

              set +e
              timeout 10 sh -lc "$script" >"$out" 2>"$err"
              status=$?
              set -e

              if [ "$status" -eq 0 ] || [ "$status" -eq 124 ]; then
                fail_probe "$name" "$status"
              fi

              printf 'tracefs_denied_%s_status=%s\n' "$name" "$status"
            }

            expect_not_listed() {
              name=$1
              probe=$2
              forbidden=$3
              out="$work/$name.out"
              err="$work/$name.err"

              set +e
              timeout 15 bpftrace -l "$probe" >"$out" 2>"$err"
              status=$?
              set -e

              if [ "$status" -eq 124 ]; then
                fail_probe "$name" "$status"
              fi
              if [ "$status" -eq 0 ] && grep -Fxq "$forbidden" "$out"; then
                fail_probe "$name" "$status"
              fi

              printf 'bpftrace_not_listed_%s_status=%s\n' "$name" "$status"
            }

            expect_shell_denied tracefs_kprobe_events \
              'printf "p:vpsadminos_pwn vfs_read\n" > /sys/kernel/tracing/kprobe_events'
            expect_shell_denied debugfs_kprobe_events \
              'printf "p:vpsadminos_pwn vfs_read\n" > /sys/kernel/debug/tracing/kprobe_events'
            expect_shell_denied tracefs_create_file \
              'touch /sys/kernel/tracing/vpsadminos-pwn'
            expect_shell_denied tracefs_available_write \
              'printf "vfs_read\n" > /sys/kernel/tracing/available_filter_functions'
            expect_shell_denied tracefs_mount \
              'mkdir -p /tmp/tracefs-pwn && mount -t tracefs tracefs /tmp/tracefs-pwn'
            expect_shell_denied debugfs_mount \
              'mkdir -p /tmp/debugfs-pwn && mount -t debugfs debugfs /tmp/debugfs-pwn'
            expect_shell_denied tracefs_unmount_remount \
              'unshare -m sh -lc "umount /sys/kernel/tracing && mount -t tracefs tracefs /sys/kernel/tracing"'
            expect_not_listed kprobe_vfs_read kprobe:vfs_read kprobe:vfs_read

            expect_denied kprobe_vfs_read \
              bpftrace -e 'kprobe:vfs_read { printf("unexpected kprobe\n"); exit(); }' -c true
            expect_denied tracepoint_execve \
              bpftrace -e 'tracepoint:syscalls:sys_enter_execve { printf("unexpected exec %s\n", str(args->filename)); exit(); }' -c true
            expect_denied rawtracepoint_fork \
              bpftrace -e 'rawtracepoint:sched_process_fork { printf("unexpected raw tracepoint\n"); exit(); }' -c true
            expect_denied lsm_file_open \
              bpftrace -e 'lsm:file_open { printf("unexpected lsm\n"); exit(); }' -c true
            expect_denied fentry_wake_up_new_task \
              bpftrace -e 'fentry:wake_up_new_task { printf("unexpected fentry\n"); exit(); }' -c true
            expect_denied fexit_wake_up_new_task \
              bpftrace -e 'fexit:wake_up_new_task { printf("unexpected fexit\n"); exit(); }' -c true
            expect_denied profile_cpu_wide \
              bpftrace -e 'profile:hz:99 { printf("unexpected profile\n"); exit(); }'
            expect_denied kernel_stack_profile \
              bpftrace -e 'profile:hz:99 { @[kstack] = count(); exit(); }'
            expect_denied hardware_cpu_wide \
              bpftrace -e 'hardware:cpu-cycles:1000000 { printf("unexpected hardware\n"); exit(); }'
            expect_denied software_cpu_wide \
              bpftrace -e 'software:cpu-clock:99 { printf("unexpected software\n"); exit(); }'
            expect_denied current_task_pointer \
              bpftrace -e 'kprobe:sched_fork { printf("%p\n", curtask); exit(); }' -c true
            expect_denied raw_pt_regs_arg0 \
              bpftrace -e 'kprobe:tcp_v4_connect { printf("%lx\n", arg0); exit(); }' -c true
            expect_denied retire_userns_raw_pt_regs_arg0 \
              bpftrace -e 'kprobe:retire_userns_sysctls { printf("%lx\n", arg0); exit(); }' -c true
            expect_denied free_user_ns_raw_pt_regs_arg0 \
              bpftrace -e 'kprobe:free_user_ns { printf("%lx\n", arg0); exit(); }' -c true
            expect_denied script_file_vfs_read \
              sh -lc 'printf "%s\n" "kprobe:vfs_read { printf(\"unexpected script\\n\"); exit(); }" > /tmp/bpftrace-script-file.bt; bpftrace /tmp/bpftrace-script-file.bt'
            expect_denied host_or_cross_exec_tracepoint \
              bpftrace -e 'tracepoint:sched:sched_process_exec { printf("unexpected exec %s\n", str(args->filename)); exit(); }'
            expect_denied host_exec_marker_tracepoint \
              bpftrace -e 'tracepoint:syscalls:sys_enter_execve /str(args->filename) == "/tmp/vpsadminos-host-bpftrace-marker"/ { printf("unexpected host exec %s\n", str(args->filename)); exit(); }'
            expect_denied peer_exec_marker_tracepoint \
              bpftrace -e 'tracepoint:syscalls:sys_enter_execve /str(args->filename) == "/tmp/vpsadminos-peer-bpftrace-marker"/ { printf("unexpected peer exec %s\n", str(args->filename)); exit(); }'

            after_ns=$(readlink /proc/self/ns/tracing)
            test "$after_ns" = "$before_ns"
            printf 'bpftrace_namespace_stable=%s\n' "$after_ns"
          '';
          bpftraceListSmoke = pkgs.writeShellScriptBin "bpftrace-list-smoke" ''
            set -eu
            ulimit -l unlimited 2>/dev/null || true

            if command -v bpftrace-real >/dev/null; then
              echo "bpftrace wrapper companion is present in PATH" >&2
              exit 1
            fi
            bpftrace_path=$(command -v bpftrace)
            if [ "$(head -c 2 "$bpftrace_path" 2>/dev/null || true)" = '#!' ]; then
              echo "bpftrace resolves to a wrapper script: $bpftrace_path" >&2
              exit 1
            fi
            printf 'bpftrace_unwrapped_path=%s\n' "$bpftrace_path"

            work=/tmp/bpftrace-list
            rm -rf "$work"
            mkdir -p "$work"

            timeout 30 bpftrace -l >"$work/all.out" 2>"$work/all.err"
            timeout 30 bpftrace -l 'kprobe:*' >"$work/kprobe.out" 2>"$work/kprobe.err"
            timeout 30 bpftrace -l 'tracepoint:*' >"$work/tracepoint.out" 2>"$work/tracepoint.err"
            timeout 30 bpftrace -q -l 'kprobe:*' >"$work/quiet-kprobe.out" 2>"$work/quiet-kprobe.err"

            for file in \
              /sys/kernel/tracing/available_filter_functions \
              /sys/kernel/tracing/available_events \
              /sys/kernel/debug/tracing/available_filter_functions \
              /sys/kernel/debug/tracing/available_events
            do
              test -f "$file"
              test -r "$file"
              if [ -w "$file" ]; then
                echo "projected trace discovery file is writable: $file" >&2
                exit 1
              fi
              printf 'tracefs_projected_readonly=%s\n' "$file"
            done
            test "$(wc -l </sys/kernel/tracing/available_events)" -eq 0
            test ! -e /sys/kernel/tracing/kprobe_events
            test ! -e /sys/kernel/debug/tracing/kprobe_events
            test ! -e /sys/kernel/tracing/set_event
                test ! -e /sys/kernel/debug/tracing/set_event
                if touch /sys/kernel/tracing/bpftrace-list-write-probe 2>/dev/null; then
                  echo "projected tracefs directory allowed file creation" >&2
                  exit 1
                fi

                for file in \
                  /sys/bus/event_source/devices/kprobe/type \
                  /sys/bus/event_source/devices/kprobe/format/retprobe \
                  /sys/bus/event_source/devices/uprobe/type \
                  /sys/bus/event_source/devices/uprobe/format/retprobe
                do
                  test -f "$file"
                  test -r "$file"
                  test -s "$file"
                  if [ -w "$file" ]; then
                    echo "projected PMU metadata file is writable: $file" >&2
                    exit 1
                  fi
                  printf 'pmu_filtered_readonly=%s\n' "$file"
                done
                grep -Eq '^[0-9]+$' /sys/bus/event_source/devices/kprobe/type
                grep -Eq '^[0-9]+$' /sys/bus/event_source/devices/uprobe/type
                grep -Eq '^config:[0-9]+$' /sys/bus/event_source/devices/kprobe/format/retprobe
                grep -Eq '^config:[0-9]+$' /sys/bus/event_source/devices/uprobe/format/retprobe
                findmnt -n -T /sys/bus/event_source -o SOURCE,FSTYPE,OPTIONS >"$work/event-source.mount"
                grep -Eq '[[:space:]]sysfs[[:space:]]' "$work/event-source.mount"
                if grep -Fq '/run/osctl/event-source' "$work/event-source.mount"; then
                  echo "PMU metadata is still using the tmpfs projection" >&2
                  exit 1
                fi
                find /sys/bus/event_source/devices -mindepth 1 -maxdepth 1 -printf '%f\n' | sort >"$work/pmu-devices.out"
                grep -Fxq kprobe "$work/pmu-devices.out"
                grep -Fxq uprobe "$work/pmu-devices.out"
                if grep -vxE '(kprobe|uprobe)' "$work/pmu-devices.out"; then
                  echo "unexpected PMU device visible through kernfs filter" >&2
                  exit 1
                fi
                for hidden_pmu in cpu software tracepoint breakpoint; do
                  test ! -e "/sys/bus/event_source/devices/$hidden_pmu"
                done
                if touch /sys/bus/event_source/vpsadminos-pwn 2>/dev/null; then
                  echo "filtered PMU metadata directory allowed file creation" >&2
                  exit 1
                fi

                kprobe_count=$(wc -l <"$work/kprobe.out")
            quiet_kprobe_count=$(wc -l <"$work/quiet-kprobe.out")
            tracepoint_count=$(wc -l <"$work/tracepoint.out")
            printf 'bpftrace_list_kprobe_count=%s\n' "$kprobe_count"
            printf 'bpftrace_list_quiet_kprobe_count=%s\n' "$quiet_kprobe_count"
            printf 'bpftrace_list_tracepoint_count=%s\n' "$tracepoint_count"

            test "$kprobe_count" -gt 0
            test "$kprobe_count" -le 512
            test "$quiet_kprobe_count" -eq "$kprobe_count"
            test "$tracepoint_count" -eq 0

                for typed_prefix in fentry fexit; do
                  grep "^$typed_prefix:vmlinux:" "$work/all.out" \
                    | sed "s/^$typed_prefix:vmlinux:/kprobe:/" \
                    >"$work/$typed_prefix-as-kprobe.out" || true
                  if [ -s "$work/$typed_prefix-as-kprobe.out" ]; then
                    if ! cmp -s "$work/kprobe.out" "$work/$typed_prefix-as-kprobe.out"; then
                      echo "$typed_prefix discovery differs from bounded kprobe targets" >&2
                      exit 1
                    fi
                  fi
                  printf 'bpftrace_list_%s_alias_count=%s\n' \
                    "$typed_prefix" "$(wc -l <"$work/$typed_prefix-as-kprobe.out")"
                done

                for prefix in \
                  iter: \
                  kfunc: \
                  lsm: \
                  profile: \
                  rawtracepoint: \
                  tracepoint:
            do
              if grep -q "^$prefix" "$work/all.out"; then
                echo "forbidden bpftrace list prefix present: $prefix" >&2
                exit 1
              fi
              printf 'bpftrace_list_prefix_absent=%s\n' "$prefix"
                done

                grep '^hardware:' "$work/all.out" >"$work/hardware.out" || true
                while IFS= read -r probe; do
                  case "$probe" in
                    hardware:backend-stalls:|hardware:branch-instructions:|hardware:branch-misses:|hardware:branches:|hardware:bus-cycles:|hardware:cache-misses:|hardware:cache-references:|hardware:cpu-cycles:|hardware:cycles:|hardware:frontend-stalls:|hardware:instructions:|hardware:ref-cycles:)
                      ;;
                    *)
                      echo "unexpected bpftrace hardware alias listed: $probe" >&2
                      exit 1
                      ;;
                  esac
                done <"$work/hardware.out"
                printf 'bpftrace_list_static_hardware_alias_count=%s\n' "$(wc -l <"$work/hardware.out")"

                grep '^software:' "$work/all.out" >"$work/software.out" || true
                while IFS= read -r probe; do
                  case "$probe" in
                software:alignment-faults:|software:bpf-output:|software:context-switches:|software:cpu-clock:|software:cpu-migrations:|software:cpu:|software:cs:|software:dummy:|software:emulation-faults:|software:faults:|software:major-faults:|software:minor-faults:|software:page-faults:|software:task-clock:)
                  ;;
                *)
                  echo "unexpected bpftrace software alias listed: $probe" >&2
                  exit 1
                  ;;
              esac
            done <"$work/software.out"
            printf 'bpftrace_list_static_software_alias_count=%s\n' "$(wc -l <"$work/software.out")"

            for forbidden in \
              kprobe:vfs_read \
              kprobe:do_sys_openat2 \
              kprobe:security_bpf \
              kprobe:bpf_prog_load \
              tracepoint:syscalls:sys_enter_execve \
              rawtracepoint:sched_process_fork
            do
              if grep -Fxq "$forbidden" \
                "$work/all.out" \
                "$work/kprobe.out" \
                "$work/tracepoint.out" \
                "$work/quiet-kprobe.out"; then
                echo "forbidden bpftrace probe listed: $forbidden" >&2
                exit 1
              fi
              printf 'bpftrace_list_forbidden_absent=%s\n' "$forbidden"
            done

            allowed=0
            for probe in \
              kprobe:sched_fork \
              kprobe:wake_up_new_task \
              kprobe:tcp_v4_connect \
              kprobe:tcp_v6_connect \
              kprobe:tcp_set_state \
              kprobe:tcp_close \
              kprobe:inet_csk_accept \
              kprobe:__x64_sys_connect \
              kprobe:__ia32_sys_connect \
              kprobe:__se_sys_connect \
              kprobe:__do_sys_connect \
              kprobe:sys_connect
            do
              if grep -Fxq "$probe" "$work/kprobe.out"; then
                printf 'bpftrace_list_allowed_probe=%s\n' "$probe"
                allowed=1
              fi
            done
            test "$allowed" = 1
          '';
          tracingPackages = [
            config.boot.kernelPackages.bcc
            config.boot.kernelPackages.perf
            pkgs.bpftrace
            bccIsolationSmoke
            bccToolsSmoke
            bccPythonSmoke
            bccPerfEventSmoke
            bpftraceIsolationSmoke
            bpftraceListSmoke
            bpfMapSmoke
          ];
          kernel = config.boot.kernelPackages.kernel;
        in
        {
          imports = lib.optionals (builtins.getEnv "VPSADMINOS_CONFIG" == "") [
            ../../../os/configs/tracing-tools-qemu.nix
          ];

          boot.qemu = {
            memory = lib.mkForce 4096;
            cpus = lib.mkForce 2;
            cpu = {
              cores = lib.mkForce 2;
              threads = lib.mkForce 1;
              sockets = lib.mkForce 1;
            };
          };

          osctl.pools.tank = {
            users.testuser = {
              uidMap = [ "0:500000:65536" ];
              gidMap = [ "0:600000:65536" ];
            };

            containers = {
              trace-tools = mkTracingContainer kernel tracingPackages;
              trace-peer = mkTracingContainer kernel tracingPackages;
            };
          };
        };
    };

    testScript = ''
      require 'shellwords'
      require 'tempfile'

      TEST_CT = 'trace-tools'
      PEER_CT = 'trace-peer'

      def self.with_ct_script(script, ctid:)
        prefix = "vpsadminos-ct-script-#{ctid.gsub(/[^A-Za-z0-9_]/, '_')}-"

        Tempfile.create([prefix, '.sh']) do |file|
          file.write("#!/bin/sh\n")
          file.write(script)
          file.flush
          file.close

          vm_path = "/tmp/#{File.basename(file.path)}"
          machine.push_file(file.path, vm_path)
          machine.succeeds("chmod 0700 #{Shellwords.escape(vm_path)}", timeout: 60)

          begin
            yield vm_path
          ensure
            machine.execute("rm -f #{Shellwords.escape(vm_path)}", timeout: 60)
          end
        end
      end

      def self.ct_script_command(path, ctid:)
        [
          'osctl',
          'ct',
          'runscript',
          ctid,
          path,
        ].shelljoin
      end

      def self.ct_sh(script, timeout: 120, ctid: TEST_CT)
        with_ct_script(script, ctid:) do |path|
          machine.succeeds(
            ct_script_command(path, ctid:),
            timeout:
          )
        end
      end

      def self.start_host_exec_marker_loop
        machine.succeeds(<<~'SH')
          set -eu
          marker=/tmp/vpsadminos-host-bpftrace-marker
          pidfile=/tmp/vpsadminos-host-bpftrace-marker.pid
          logfile=/tmp/vpsadminos-host-bpftrace-marker.log

          rm -f "$marker" "$pidfile" "$logfile"
          ln -sf /run/current-system/sw/bin/true "$marker"
          (
            end=$(( $(date +%s) + 240 ))
            while [ "$(date +%s)" -lt "$end" ]; do
              "$marker" || exit 1
              sleep 0.05
            done
          ) >"$logfile" 2>&1 &
          echo $! >"$pidfile"
        SH
      end

      def self.start_peer_exec_marker_loop
        ct_sh(<<~'SH', ctid: PEER_CT)
          set -eu
          marker=/tmp/vpsadminos-peer-bpftrace-marker
          pidfile=/tmp/vpsadminos-peer-bpftrace-marker.pid
          logfile=/tmp/vpsadminos-peer-bpftrace-marker.log

          rm -f "$marker" "$pidfile" "$logfile"
          ln -sf /run/current-system/sw/bin/true "$marker"
          (
            end=$(( $(date +%s) + 240 ))
            while [ "$(date +%s)" -lt "$end" ]; do
              "$marker" || exit 1
              sleep 0.05
            done
          ) >"$logfile" 2>&1 &
          echo $! >"$pidfile"
        SH
      end

      def self.stop_host_exec_marker_loop
        machine.succeeds(<<~'SH')
          set +e
          pidfile=/tmp/vpsadminos-host-bpftrace-marker.pid
          if [ -s "$pidfile" ]; then
            kill "$(cat "$pidfile")" 2>/dev/null || true
          fi
          rm -f /tmp/vpsadminos-host-bpftrace-marker /tmp/vpsadminos-host-bpftrace-marker.pid
        SH
      end

      def self.stop_peer_exec_marker_loop
        ct_sh(<<~'SH', ctid: PEER_CT)
          set +e
          pidfile=/tmp/vpsadminos-peer-bpftrace-marker.pid
          if [ -s "$pidfile" ]; then
            kill "$(cat "$pidfile")" 2>/dev/null || true
          fi
          rm -f /tmp/vpsadminos-peer-bpftrace-marker /tmp/vpsadminos-peer-bpftrace-marker.pid
        SH
      end

      def self.dump_tracing_debug
        machine.execute(<<~SH, timeout: 120)
          set +e
          echo '--- host tracing namespace ---'
          readlink /proc/self/ns/tracing
          echo '--- host tracing sysctls ---'
          cat /proc/sys/kernel/bpf_container_tracing_enabled 2>/dev/null
          cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null
          cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null
          cat /tmp/vpsadminos-host-bpftrace-marker.log 2>/dev/null
          echo '--- container status ---'
          osctl ct show #{TEST_CT}
          echo '--- container tracing state ---'
          osctl ct exec #{TEST_CT} sh -lc '
            set +e
            readlink /proc/self/ns/tracing
            cat /proc/sys/kernel/bpf_container_tracing_enabled 2>/dev/null
            cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null
            cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null
              findmnt -R /sys/kernel/tracing 2>/dev/null
              findmnt -R /sys/kernel/debug/tracing 2>/dev/null
              findmnt -R /sys/bus/event_source 2>/dev/null
              mount | grep -E "tracefs|debugfs"
              ls -la /sys/kernel/tracing 2>/dev/null
              ls -la /sys/kernel/debug/tracing 2>/dev/null
              find /sys/bus/event_source -maxdepth 4 -type f -print 2>/dev/null | while read -r f; do
                echo "--- $f"
                cat "$f" 2>/dev/null
              done
              head -n 20 /sys/kernel/tracing/available_filter_functions 2>/dev/null
            head -n 20 /sys/kernel/tracing/available_events 2>/dev/null
            modver=$(uname -r)
            ls -la "/run/booted-system/kernel-modules/lib/modules/$modver" 2>/dev/null
            ls -la "/run/booted-system/kernel-modules/lib/modules/$modver/build" 2>/dev/null
            for f in /tmp/bcc-tools/*.out /tmp/bcc-tools/*.err /tmp/execsnoop.* /tmp/opensnoop.* /tmp/runqlat.* /tmp/perf.* /tmp/bpftrace-isolation/*.out /tmp/bpftrace-isolation/*.err /tmp/bpftrace-list/*.out /tmp/bpftrace-list/*.err /tmp/bpftrace-scope.* /tmp/bpftrace-uprobe-scope.*; do
              [ -e "$f" ] || continue
              echo "--- $f"
              ls -l "$f"
              case "$f" in
                *.data|*.svg)
                  ;;
                *)
                  cat "$f"
                  ;;
              esac
            done
          '
        SH
      end

      def self.ct_sh_checked(script, timeout: 120, ctid: TEST_CT)
        status = nil
        output = nil
        with_ct_script(script, ctid:) do |path|
          status, output = machine.execute(
            ct_script_command(path, ctid:),
            timeout:
          )
        end
        return output if status == 0

        _, debug_output = dump_tracing_debug
        fail "container tracing command failed with status #{status}:\n#{output}\n#{debug_output}"
      end

      before(:suite) do
        machine.start
        machine.wait_for_osctl_pool('tank')
        machine.wait_for_osctl_container(TEST_CT)
        machine.wait_for_osctl_container(PEER_CT)
        machine.wait_until_succeeds("osctl ct exec #{TEST_CT} systemctl is-system-running", timeout: 180)
        machine.wait_until_succeeds("osctl ct exec #{PEER_CT} systemctl is-system-running", timeout: 180)
      end

      describe 'container tracing namespace tooling', order: :defined do
        it 'creates a dedicated container tracing namespace with constrained BPF enabled' do
          host_ns = machine.succeeds('readlink /proc/self/ns/tracing')[1].strip
          ct_ns = ct_sh('readlink /proc/self/ns/tracing')[1].strip

          expect(ct_ns).to match(/^tracing:\[\d+\]$/)
          expect(ct_ns).not_to eq(host_ns)

          ct_sh_checked(<<~'SH')
            set -eu
            test "$(cat /proc/sys/kernel/bpf_container_tracing_enabled)" = 1
            test "$(cat /proc/sys/kernel/unprivileged_bpf_disabled)" = 1
            test -d "/run/booted-system/kernel-modules/lib/modules/$(uname -r)/build"
            test -d "/run/booted-system/kernel-modules/lib/modules/$(uname -r)/source"
            missing=0
            for tool in python3 modprobe bpf-map-smoke bpf-load-probe-smoke btf-fd-leak-probe perf-fd-leak-probe bcc-isolation-smoke bcc-tools-smoke bcc-python-smoke bcc-perf-event-smoke bpftrace bpftrace-isolation-smoke bpftrace-list-smoke execsnoop opensnoop runqlat tcpconnect perf tracework tracing-tcp-connect-work hostconnect peerconnect ctconnect stackcollapse-perf.pl flamegraph.pl; do
              if ! command -v "$tool" >/dev/null; then
                echo "missing tool: $tool" >&2
                missing=1
              fi
            done
            test "$missing" = 0
            bpf-load-probe-smoke
          SH
        end

        it 'rejects broad bpftrace instrumentation from the tracing namespace' do
          start_host_exec_marker_loop
          start_peer_exec_marker_loop

          begin
            ct_sh_checked(<<~'SH', timeout: 300)
              set -eu
              bpftrace-isolation-smoke
            SH
          ensure
            stop_host_exec_marker_loop
            stop_peer_exec_marker_loop
          end
        end

        it 'lists only bounded bpftrace probe targets from the tracing namespace' do
          ct_sh_checked(<<~'SH', timeout: 300)
            set -eu
            bpftrace-list-smoke
          SH
        end

        it 'runs useful bpftrace kprobes only for tasks in the same tracing namespace' do
          begin
            ct_sh_checked(<<~'SH', timeout: 120)
              set -eu
              ulimit -l unlimited 2>/dev/null || true
              rm -f /tmp/bpftrace-scope.*

              start_probe() {
                label=$1
                probe=$2
                out=/tmp/bpftrace-scope.$label.out
                err=/tmp/bpftrace-scope.$label.err
                pidfile=/tmp/bpftrace-scope.$label.pid

                rm -f "$out" "$err" "$pidfile"
                program="$probe { printf(\"hit\\n\"); }"
                BPFTRACE_DEBUG_OUTPUT=1 \
                  taskset -c 0 bpftrace -q -v -e "$program" \
                  >"$out" \
                  2>"$err" &
                pid=$!
                echo "$pid" >"$pidfile"
                sleep 3

                state=$(ps -o stat= -p "$pid" 2>/dev/null | awk '{print $1}')
                case "$state" in
                  ""|Z*)
                    echo "bpftrace probe did not stay attached for $probe" >&2
                    cat "$out" >&2 2>/dev/null || true
                    cat "$err" >&2 2>/dev/null || true
                    wait "$pid" 2>/dev/null || true
                    return 1
                    ;;
                esac

                if grep -qx 'hit' "$out"; then
                  echo "bpftrace probe produced hits before workload for $probe" >&2
                  cat "$out" >&2
                  cat "$err" >&2 2>/dev/null || true
                  kill -INT "$pid" 2>/dev/null || true
                  wait "$pid" 2>/dev/null || true
                  return 1
                fi

                return 0
              }

              stop_probe() {
                label=$1
                pidfile=/tmp/bpftrace-scope.$label.pid
                [ -s "$pidfile" ] || return 0

                kill -INT "$(cat "$pidfile")" 2>/dev/null || true
                timeout 10 sh -c 'while kill -0 "$(cat "$0")" 2>/dev/null; do sleep 0.2; done' "$pidfile" || true
                if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
                  kill "$(cat "$pidfile")" 2>/dev/null || true
                fi
              }

                probe=kprobe:tcp_v4_connect
                bpftrace -l 'kprobe:*' 2>/tmp/bpftrace-scope-list.err | grep -Fxq "$probe"
                start_probe cross "$probe"
                printf '%s\n' "$probe" >/tmp/bpftrace-scope.probe
                test -s /tmp/bpftrace-scope.cross.pid
                test -s /tmp/bpftrace-scope.probe
                printf 'bpftrace_scope_started=1\n'
              SH

            machine.succeeds('taskset -c 0 ${tcpConnectWork}/bin/hostconnect 40', timeout: 120)
            ct_sh_checked('taskset -c 0 peerconnect 40', timeout: 120, ctid: PEER_CT)
            ct_sh_checked(<<~'SH', timeout: 120)
                set -eu
                sleep 2
                if [ -s /tmp/bpftrace-scope.cross.pid ]; then
                  kill -INT "$(cat /tmp/bpftrace-scope.cross.pid)"
                  timeout 10 sh -c 'while kill -0 "$(cat "$0")" 2>/dev/null; do sleep 0.2; done' /tmp/bpftrace-scope.cross.pid || true
                  if kill -0 "$(cat /tmp/bpftrace-scope.cross.pid)" 2>/dev/null; then
                    kill "$(cat /tmp/bpftrace-scope.cross.pid)" 2>/dev/null || true
                  fi
                else
                  echo "bpftrace cross-namespace kprobe pid file is missing" >&2
                  exit 1
                fi

                if grep -qx 'hit' /tmp/bpftrace-scope.cross.out; then
                echo "bpftrace printed before same-namespace workload ran" >&2
                cat /tmp/bpftrace-scope.cross.out >&2
                cat /tmp/bpftrace-scope.cross.err >&2 2>/dev/null || true
                exit 1
              fi
              printf 'bpftrace_scope_cross_namespace_hits=0\n'
            SH

            ct_sh_checked(<<~'SH', timeout: 120)
              set -eu
              probe=$(cat /tmp/bpftrace-scope.probe)

              program="$probe { printf(\"hit\\n\"); }"
              BPFTRACE_DEBUG_OUTPUT=1 \
                taskset -c 0 bpftrace -q -v -e "$program" \
                >/tmp/bpftrace-scope.same.out \
                2>/tmp/bpftrace-scope.same.err &
              echo $! >/tmp/bpftrace-scope.same.pid
              sleep 3

              state=$(ps -o stat= -p "$(cat /tmp/bpftrace-scope.same.pid)" 2>/dev/null | awk '{print $1}')
              case "$state" in
                ""|Z*)
                  echo "bpftrace same-namespace probe did not stay attached" >&2
                  cat /tmp/bpftrace-scope.same.out >&2 2>/dev/null || true
                  cat /tmp/bpftrace-scope.same.err >&2 2>/dev/null || true
                  exit 1
                  ;;
              esac

              taskset -c 0 ctconnect 40
              sleep 2
              kill -INT "$(cat /tmp/bpftrace-scope.same.pid)"
              timeout 10 sh -c 'while kill -0 "$(cat "$0")" 2>/dev/null; do sleep 0.2; done' /tmp/bpftrace-scope.same.pid || true
              if kill -0 "$(cat /tmp/bpftrace-scope.same.pid)" 2>/dev/null; then
                kill "$(cat /tmp/bpftrace-scope.same.pid)" 2>/dev/null || true
              fi

              if ! grep -qx 'hit' /tmp/bpftrace-scope.same.out; then
                echo "bpftrace did not see same-namespace connect workload" >&2
                cat /tmp/bpftrace-scope.same.out >&2 2>/dev/null || true
                cat /tmp/bpftrace-scope.same.err >&2 2>/dev/null || true
                exit 1
              fi

              printf 'bpftrace_scope_same_namespace_hits=%s\n' "$(grep -xc 'hit' /tmp/bpftrace-scope.same.out)"
            SH
          ensure
            ct_sh(<<~'SH')
              set +e
              for pidfile in /tmp/bpftrace-scope.*.pid; do
                [ -s "$pidfile" ] || continue
                kill -INT "$(cat "$pidfile")" 2>/dev/null || true
                sleep 1
                kill "$(cat "$pidfile")" 2>/dev/null || true
              done
            SH
          end
        end

        it 'runs useful bpftrace uprobes only for tasks in the same tracing namespace' do
          begin
            ct_sh_checked(<<~'SH', timeout: 120)
              set -eu
              ulimit -l unlimited 2>/dev/null || true
              rm -f /tmp/bpftrace-uprobe-scope.*

              target=$(readlink -f "$(command -v tracework)")
              probe="uprobe:$target:main"
              printf '%s\n' "$probe" >/tmp/bpftrace-uprobe-scope.probe

              program="$probe { printf(\"hit\\n\"); }"
              BPFTRACE_DEBUG_OUTPUT=1 \
                taskset -c 0 bpftrace -q -v -e "$program" \
                >/tmp/bpftrace-uprobe-scope.cross.out \
                2>/tmp/bpftrace-uprobe-scope.cross.err &
              echo $! >/tmp/bpftrace-uprobe-scope.cross.pid
              sleep 3

              state=$(ps -o stat= -p "$(cat /tmp/bpftrace-uprobe-scope.cross.pid)" 2>/dev/null | awk '{print $1}')
              case "$state" in
                ""|Z*)
                  echo "bpftrace uprobe did not stay attached" >&2
                  cat /tmp/bpftrace-uprobe-scope.cross.out >&2 2>/dev/null || true
                  cat /tmp/bpftrace-uprobe-scope.cross.err >&2 2>/dev/null || true
                  exit 1
                  ;;
              esac

              if grep -qx 'hit' /tmp/bpftrace-uprobe-scope.cross.out; then
                echo "bpftrace uprobe produced hits before workload" >&2
                cat /tmp/bpftrace-uprobe-scope.cross.out >&2
                cat /tmp/bpftrace-uprobe-scope.cross.err >&2 2>/dev/null || true
                exit 1
              fi
            SH

            ct_sh_checked('taskset -c 0 tracework 2', timeout: 120, ctid: PEER_CT)
            ct_sh_checked(<<~'SH', timeout: 120)
              set -eu
              sleep 1
              kill -INT "$(cat /tmp/bpftrace-uprobe-scope.cross.pid)"
              timeout 10 sh -c 'while kill -0 "$(cat "$0")" 2>/dev/null; do sleep 0.2; done' /tmp/bpftrace-uprobe-scope.cross.pid || true
              if kill -0 "$(cat /tmp/bpftrace-uprobe-scope.cross.pid)" 2>/dev/null; then
                kill "$(cat /tmp/bpftrace-uprobe-scope.cross.pid)" 2>/dev/null || true
              fi

              if grep -qx 'hit' /tmp/bpftrace-uprobe-scope.cross.out; then
                echo "bpftrace uprobe printed before same-namespace workload ran" >&2
                cat /tmp/bpftrace-uprobe-scope.cross.out >&2
                cat /tmp/bpftrace-uprobe-scope.cross.err >&2 2>/dev/null || true
                exit 1
              fi
              printf 'bpftrace_uprobe_scope_cross_namespace_hits=0\n'
            SH

            ct_sh_checked(<<~'SH', timeout: 120)
              set -eu
              probe=$(cat /tmp/bpftrace-uprobe-scope.probe)

              program="$probe { printf(\"hit\\n\"); }"
              BPFTRACE_DEBUG_OUTPUT=1 \
                taskset -c 0 bpftrace -q -v -e "$program" \
                >/tmp/bpftrace-uprobe-scope.same.out \
                2>/tmp/bpftrace-uprobe-scope.same.err &
              echo $! >/tmp/bpftrace-uprobe-scope.same.pid
              sleep 3

              state=$(ps -o stat= -p "$(cat /tmp/bpftrace-uprobe-scope.same.pid)" 2>/dev/null | awk '{print $1}')
              case "$state" in
                ""|Z*)
                  echo "bpftrace same-namespace uprobe did not stay attached" >&2
                  cat /tmp/bpftrace-uprobe-scope.same.out >&2 2>/dev/null || true
                  cat /tmp/bpftrace-uprobe-scope.same.err >&2 2>/dev/null || true
                  exit 1
                  ;;
              esac

              taskset -c 0 tracework 2
              sleep 1
              kill -INT "$(cat /tmp/bpftrace-uprobe-scope.same.pid)"
              timeout 10 sh -c 'while kill -0 "$(cat "$0")" 2>/dev/null; do sleep 0.2; done' /tmp/bpftrace-uprobe-scope.same.pid || true
              if kill -0 "$(cat /tmp/bpftrace-uprobe-scope.same.pid)" 2>/dev/null; then
                kill "$(cat /tmp/bpftrace-uprobe-scope.same.pid)" 2>/dev/null || true
              fi

              if ! grep -qx 'hit' /tmp/bpftrace-uprobe-scope.same.out; then
                echo "bpftrace uprobe did not see same-namespace workload" >&2
                cat /tmp/bpftrace-uprobe-scope.same.out >&2 2>/dev/null || true
                cat /tmp/bpftrace-uprobe-scope.same.err >&2 2>/dev/null || true
                exit 1
              fi

              printf 'bpftrace_uprobe_scope_same_namespace_hits=%s\n' "$(grep -xc 'hit' /tmp/bpftrace-uprobe-scope.same.out)"
            SH
          ensure
            ct_sh(<<~'SH')
              set +e
              for pidfile in /tmp/bpftrace-uprobe-scope.*.pid; do
                [ -s "$pidfile" ] || continue
                kill -INT "$(cat "$pidfile")" 2>/dev/null || true
                sleep 1
                kill "$(cat "$pidfile")" 2>/dev/null || true
              done
            SH
          end
        end

        it 'runs selected BCC programs inside the container tracing namespace' do
          ct_sh_checked(<<~'SH', timeout: 300)
            set -eu
            bpf-map-smoke
            unshare -Ur bpf-map-smoke --expect-eperm
            bcc-python-smoke
            bcc-perf-event-smoke
            bcc-isolation-smoke
            bcc-tools-smoke
          SH
        end

        it 'records perf callgraphs for a workload running in the container' do
          _, tracepoint_id = machine.succeeds(
            'cat /sys/kernel/tracing/events/sched/sched_process_exec/id'
          )
          tracepoint_id = tracepoint_id.strip

          _, original_perf_paranoid = machine.succeeds(
            'cat /proc/sys/kernel/perf_event_paranoid'
          )
          original_perf_paranoid = original_perf_paranoid.strip

          begin
            machine.succeeds("printf '%s\n' -1 > /proc/sys/kernel/perf_event_paranoid")

            ct_sh_checked(<<~SH, timeout: 300)
              set -eu
              echo marker >/tmp/vpsadminos-tracing-marker
              rm -f /tmp/perf.data /tmp/perf.script /tmp/perf.folded /tmp/perf.svg /tmp/perf.err /tmp/perf.list
              rm -f /tmp/perf.record.*.strace
              perf list --raw-dump >/tmp/perf.list 2>/tmp/perf.list.err || true
              printf 'perf_event_paranoid_inside_ct=%s\n' "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unavailable)"

              if perf record -q -a -e cycles:u -o /tmp/perf.cpuwide.data -- sleep 0.2 2>/tmp/perf.cpuwide.err; then
                echo "container CPU-wide perf record unexpectedly succeeded" >&2
                exit 1
              fi
              printf 'perf_cpu_wide_record_denied=1\n'
              printf 'perf_cpu_wide_record_denied_under_permissive_paranoid=1\n'

              if perf record -q -e cycles -o /tmp/perf.task-kernel.data -- tracework 1 2>/tmp/perf.task-kernel.err; then
                echo "container task-bound kernel perf record unexpectedly succeeded" >&2
                exit 1
              fi
              printf 'perf_task_kernel_record_denied=1\n'
              printf 'perf_task_kernel_record_denied_under_permissive_paranoid=1\n'

              kprobe_pmu_type=$(cat /sys/bus/event_source/devices/kprobe/type)
              perf-fd-leak-probe cpu-wide-kprobe "$kprobe_pmu_type" \
                >/tmp/perf.cpuwide-kprobe.out
              cat /tmp/perf.cpuwide-kprobe.out
              printf 'perf_cpu_wide_kprobe_denied=1\n'
              printf 'perf_cpu_wide_kprobe_denied_under_permissive_paranoid=1\n'

              tracepoint_id=#{Shellwords.escape(tracepoint_id)}
              perf-fd-leak-probe tracepoint-open "$tracepoint_id" \
                >/tmp/perf.tracepoint-open.out
              cat /tmp/perf.tracepoint-open.out
              printf 'perf_tracepoint_open_denied=1\n'

              record_perf() {
                event=$1
                if [ "$event" = default ]; then
                  perf record \
                    -q \
                    -B \
                    -N \
                    --no-bpf-event \
                    --no-buildid-mmap \
                    --all-user \
                    --user-callchains \
                    --synth mmap \
                    -F 99 \
                    -g \
                    --call-graph fp \
                    -o /tmp/perf.data \
                    -- tracework 3
                else
                  perf record \
                    -q \
                    -B \
                    -N \
                    --no-bpf-event \
                    --no-buildid-mmap \
                    --all-user \
                    --user-callchains \
                    --synth mmap \
                    -e "$event" \
                    -F 99 \
                    -g \
                    --call-graph fp \
                    -o /tmp/perf.data \
                    -- tracework 3
                fi
              }

              record_perf_straced() {
                event=$1
                safe_event=$(printf '%s' "$event" | tr -c 'A-Za-z0-9_.-' '_')
                if [ "$event" = default ]; then
                  strace -f -qq -s 256 \
                    -o "/tmp/perf.record.$safe_event.strace" \
                    -e trace=perf_event_open,ioctl,mmap,munmap,read,write,close,fcntl,poll,ppoll,openat,newfstatat \
                    perf record \
                      -q \
                      -B \
                      -N \
                      --no-bpf-event \
                      --no-buildid-mmap \
                      --all-user \
                      --user-callchains \
                      --synth mmap \
                      -F 99 \
                      -g \
                      --call-graph fp \
                      -o /tmp/perf.data \
                      -- tracework 3
                else
                  strace -f -qq -s 256 \
                    -o "/tmp/perf.record.$safe_event.strace" \
                    -e trace=perf_event_open,ioctl,mmap,munmap,read,write,close,fcntl,poll,ppoll,openat,newfstatat \
                    perf record \
                      -q \
                      -B \
                      -N \
                      --no-bpf-event \
                      --no-buildid-mmap \
                      --all-user \
                      --user-callchains \
                      --synth mmap \
                      -e "$event" \
                      -F 99 \
                      -g \
                      --call-graph fp \
                      -o /tmp/perf.data \
                      -- tracework 3
                fi
              }

              perf_ok=0
              for event in cpu-clock:u task-clock:u cycles:u instructions:u cpu-cycles:u; do
                rm -f /tmp/perf.data /tmp/perf.err
                safe_event=$(printf '%s' "$event" | tr -c 'A-Za-z0-9_.-' '_')
                rm -f "/tmp/perf.record.$safe_event.strace"

                if record_perf "$event" 2>/tmp/perf.err; then
                  echo "$event" >/tmp/perf.event
                  perf_ok=1
                  break
                else
                  status=$?
                fi

                echo "--- stock perf record failed for $event with status $status" >&2
                ls -l /tmp/perf.data 2>/dev/null >&2 || true
                cat /tmp/perf.err >&2

                echo "--- rerunning perf record under strace for $event" >&2
                rm -f /tmp/perf.data
                record_perf_straced "$event" 2>>/tmp/perf.err || true
                if [ -s "/tmp/perf.record.$safe_event.strace" ]; then
                  echo "--- perf record strace head for $event" >&2
                  sed -n '1,220p' "/tmp/perf.record.$safe_event.strace" >&2
                  echo "--- perf record strace tail for $event" >&2
                  tail -n 220 "/tmp/perf.record.$safe_event.strace" >&2
                else
                  echo "--- missing perf record strace for $event" >&2
                fi
              done
              test "$perf_ok" = 1
              printf 'perf_record_event=%s\n' "$(cat /tmp/perf.event)"
              printf 'perf_record_stock_unwrapped=1\n'
              printf 'perf_record_container_safe_options=-B -N --no-bpf-event --no-buildid-mmap --all-user --user-callchains --synth mmap\n'

              test -s /tmp/perf.data
              perf report -D -i /tmp/perf.data >/tmp/perf.dump 2>>/tmp/perf.err
              if grep -Eq 'PERF_RECORD_(BPF_EVENT|KSYMBOL)' /tmp/perf.dump; then
                echo "container perf data unexpectedly contains host sideband records" >&2
                exit 1
              fi
              printf 'perf_record_sideband_bpf_ksymbol_records=0\n'
              perf script -i /tmp/perf.data >/tmp/perf.script 2>>/tmp/perf.err
              test -s /tmp/perf.script
              if grep -Eq '(^|[[:space:]])ffffffff[0-9a-f]|\\[[^]]*kernel[^]]*\\]|kallsyms' /tmp/perf.script; then
                echo "container perf script unexpectedly contains kernel callchain data" >&2
                exit 1
              fi
              printf 'perf_record_kernel_callchain_records=0\n'
              grep -Eq 'tracework|spin_branch|spin_leaf' /tmp/perf.script
              stackcollapse-perf.pl /tmp/perf.script >/tmp/perf.folded 2>>/tmp/perf.err
              test -s /tmp/perf.folded
              grep -Eq 'tracework|spin_branch|spin_leaf' /tmp/perf.folded
              flamegraph.pl /tmp/perf.folded >/tmp/perf.svg 2>>/tmp/perf.err
              test -s /tmp/perf.svg
              grep -q '<svg' /tmp/perf.svg
            SH
          ensure
            machine.succeeds(
              "printf '%s\n' #{Shellwords.escape(original_perf_paranoid)} > /proc/sys/kernel/perf_event_paranoid"
            )
          end
        end

        it 'rejects leaked host BTF file descriptors in the container tracing namespace' do
          btf_leak_host_dir = '/run/tracing-tools-btf-fdleak'
          btf_leak_host_socket = "#{btf_leak_host_dir}/btf.sock"
          btf_leak_ct_socket = '/mnt/btf-fdleak/btf.sock'
          btf_leak_probe = '${btfFdLeakProbe}/bin/btf-fd-leak-probe'

          machine.succeeds("install -d -m 0777 #{Shellwords.escape(btf_leak_host_dir)}")
          machine.succeeds([
            'osctl', 'ct', 'mounts', 'new',
            '--fs', btf_leak_host_dir,
            '--type', 'bind',
            '--opts', 'bind,create=dir,rw',
            '--mountpoint', '/mnt/btf-fdleak',
            '--no-map-ids',
            TEST_CT,
          ].shelljoin, timeout: 120)

          machine.succeeds(<<~SH)
            rm -f /tmp/btf-fdleak-send.out /tmp/btf-fdleak-send.rc
            (
              timeout 45 sh -c 'until test -S "$1"; do sleep 0.1; done' \
                sh #{Shellwords.escape(btf_leak_host_socket)} &&
                #{[btf_leak_probe, 'send', btf_leak_host_socket].shelljoin}
              printf '%s\n' "$?" >/tmp/btf-fdleak-send.rc
            ) >/tmp/btf-fdleak-send.out 2>&1 &
          SH

          _, btf_leak_output = ct_sh(
            "#{Shellwords.escape(btf_leak_probe)} recv #{Shellwords.escape(btf_leak_ct_socket)}",
            timeout: 60
          )
          machine.wait_until_succeeds('test -s /tmp/btf-fdleak-send.rc', timeout: 10)
          machine.succeeds(
            'cat /tmp/btf-fdleak-send.out; test "$(cat /tmp/btf-fdleak-send.rc)" = 0'
          )

          fail "same-container BTF load failed:\n#{btf_leak_output}" unless btf_leak_output.include?('container_btf_load_errno=0')
          fail "same-container BTF info failed:\n#{btf_leak_output}" unless btf_leak_output.include?('container_btf_info_errno=0')
          fail "same-container BTF map create failed:\n#{btf_leak_output}" unless btf_leak_output.include?('container_btf_map_create_errno=0')
          fail "BTF fd-leak did not receive a valid fd:\n#{btf_leak_output}" unless btf_leak_output.include?('leaked_host_btf_fstat_errno=0')
          fail "BTF fd-leak exposed fdinfo:\n#{btf_leak_output}" unless btf_leak_output.include?('leaked_host_btf_fdinfo_visible=0')

          [
            ['info-by-fd', 'leaked_host_btf_info_errno'],
            ['map-create reuse', 'leaked_host_btf_map_create_errno'],
          ].each do |name, marker|
            denied = ["#{marker}=13", "#{marker}=1"].any? do |expected_marker|
              btf_leak_output.include?(expected_marker)
            end
            fail "BTF fd-leak #{name} was not denied safely:\n#{btf_leak_output}" unless denied
          end
        end

        it 'rejects leaked host perf event file descriptors in the container tracing namespace' do
          perf_leak_host_dir = '/run/tracing-tools-perf-fdleak'
          perf_leak_host_socket = "#{perf_leak_host_dir}/perf.sock"
          perf_leak_ct_socket = '/mnt/perf-fdleak/perf.sock'
          perf_leak_probe = '${perfFdLeakProbe}/bin/perf-fd-leak-probe'

          machine.succeeds("install -d -m 0777 #{Shellwords.escape(perf_leak_host_dir)}")
          machine.succeeds([
            'osctl', 'ct', 'mounts', 'new',
            '--fs', perf_leak_host_dir,
            '--type', 'bind',
            '--opts', 'bind,create=dir,rw',
            '--mountpoint', '/mnt/perf-fdleak',
            '--no-map-ids',
            TEST_CT,
          ].shelljoin, timeout: 120)

          machine.succeeds(<<~SH)
            rm -f /tmp/perf-fdleak-send.out /tmp/perf-fdleak-send.rc
            (
              timeout 45 sh -c 'until test -S "$1"; do sleep 0.1; done' \
                sh #{Shellwords.escape(perf_leak_host_socket)} &&
                #{[perf_leak_probe, 'send', perf_leak_host_socket].shelljoin}
              printf '%s\n' "$?" >/tmp/perf-fdleak-send.rc
            ) >/tmp/perf-fdleak-send.out 2>&1 &
          SH

          _, perf_leak_output = ct_sh(
            "#{Shellwords.escape(perf_leak_probe)} recv #{Shellwords.escape(perf_leak_ct_socket)}",
            timeout: 60
          )
          machine.wait_until_succeeds('test -s /tmp/perf-fdleak-send.rc', timeout: 10)
          machine.succeeds(
            'cat /tmp/perf-fdleak-send.out; test "$(cat /tmp/perf-fdleak-send.rc)" = 0'
          )

          fail "perf fd-leak did not receive a valid fd:\n#{perf_leak_output}" unless perf_leak_output.include?('leaked_host_perf_fstat_errno=0')

          [
            ['read', 'leaked_host_perf_read_errno'],
            ['ioctl-enable', 'leaked_host_perf_ioctl_enable_errno'],
            ['ioctl-id', 'leaked_host_perf_ioctl_id_errno'],
            ['group-open', 'leaked_host_perf_group_open_errno'],
            ['fd-output-open', 'leaked_host_perf_fd_output_open_errno'],
            ['ioctl-set-output', 'leaked_host_perf_ioctl_set_output_errno'],
            ['mmap', 'leaked_host_perf_mmap_errno'],
            ['fasync', 'leaked_host_perf_fasync_errno'],
            ['perf-event-array update', 'leaked_host_perf_array_update_errno'],
            ['task-fd-query', 'leaked_host_perf_task_fd_query_errno'],
          ].each do |name, marker|
            denied = ["#{marker}=13", "#{marker}=1"].any? do |expected_marker|
              perf_leak_output.include?(expected_marker)
            end
            fail "perf fd-leak #{name} was not denied safely:\n#{perf_leak_output}" unless denied
          end

          fail "perf fd-leak perf-event-array setup failed:\n#{perf_leak_output}" unless perf_leak_output.include?('perf_array_create_errno=0')
          fail "perf fd-leak set-output setup failed:\n#{perf_leak_output}" unless perf_leak_output.include?('container_perf_set_output_create_errno=0')
          fail "perf fd-leak poll returned an errno:\n#{perf_leak_output}" unless perf_leak_output.include?('leaked_host_perf_poll_errno=0')
          fail "perf fd-leak poll did not report POLLERR:\n#{perf_leak_output}" unless perf_leak_output.match?(/^leaked_host_perf_poll_revents=0x[0-9a-f]*8[0-9a-f]*$/)
        end
      end
    '';
  }
)
