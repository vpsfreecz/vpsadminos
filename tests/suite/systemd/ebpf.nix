import ../../make-test.nix (
  { pkgs, testArgs ? { } }:
  let
    lib = pkgs.lib;
    includeBtfSystemd = testArgs.includeBtfSystemd or false;

    systemdEbpfTools = pkgs.runCommand "systemd-ebpf-tools" { } ''
      mkdir -p $out/bin

      cat >$out/bin/systemd-ebpf-server <<'EOF'
      #!${pkgs.runtimeShell}
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import pathlib
      import socket
      import sys

      host = sys.argv[1]
      port = int(sys.argv[2])
      ready = pathlib.Path(sys.argv[3])

      sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
      sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      sock.bind((host, port))
      sock.listen(16)
      ready.write_text("ready\n")

      while True:
          conn, _ = sock.accept()
          with conn:
              conn.sendall(b"ok\n")
      PY
      EOF

      cat >$out/bin/systemd-ebpf-connect <<'EOF'
      #!${pkgs.runtimeShell}
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import errno
      import socket
      import sys

      host = sys.argv[1]
      port = int(sys.argv[2])
      expect = sys.argv[3]

      try:
          with socket.create_connection((host, port), timeout=1) as conn:
              conn.recv(16)
          allowed = True
          denied_errno = None
          denied_timeout = False
      except OSError as e:
          allowed = False
          denied_errno = e.errno
          denied_timeout = isinstance(e, socket.timeout)

      if expect == "allow":
          if allowed:
              print("connect_allowed=1")
              sys.exit(0)
          print(f"connect_allowed=0 errno={denied_errno}", file=sys.stderr)
          sys.exit(1)

      if expect == "deny":
          if denied_errno in (errno.EACCES, errno.EPERM):
              print(f"connect_denied_errno={denied_errno}")
              sys.exit(0)
          if denied_timeout:
              print("connect_denied_timeout=1")
              sys.exit(0)
          if allowed:
              print("connect unexpectedly succeeded", file=sys.stderr)
          else:
              print(f"connect failed with unexpected errno={denied_errno}", file=sys.stderr)
          sys.exit(1)

      print(f"unknown expectation {expect!r}", file=sys.stderr)
      sys.exit(2)
      PY
      EOF

      cat >$out/bin/systemd-ebpf-bind <<'EOF'
      #!${pkgs.runtimeShell}
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import errno
      import socket
      import sys

      host = sys.argv[1]
      port = int(sys.argv[2])
      expect = sys.argv[3]

      sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
      try:
          sock.bind((host, port))
          allowed = True
          denied_errno = None
      except OSError as e:
          allowed = False
          denied_errno = e.errno
      finally:
          sock.close()

      if expect == "allow":
          if allowed:
              print("bind_allowed=1")
              sys.exit(0)
          print(f"bind_allowed=0 errno={denied_errno}", file=sys.stderr)
          sys.exit(1)

      if expect == "deny":
          if denied_errno in (errno.EACCES, errno.EPERM):
              print(f"bind_denied_errno={denied_errno}")
              sys.exit(0)
          if allowed:
              print("bind unexpectedly succeeded", file=sys.stderr)
          else:
              print(f"bind failed with unexpected errno={denied_errno}", file=sys.stderr)
          sys.exit(1)

      print(f"unknown expectation {expect!r}", file=sys.stderr)
      sys.exit(2)
      PY
      EOF

      cat >$out/bin/systemd-ebpf-bound-iface <<'EOF'
      #!${pkgs.runtimeShell}
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import socket
      import sys

      SO_BINDTODEVICE = 25

      expect = sys.argv[1]

      sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
      raw = sock.getsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, 256)
      name = raw.split(b"\0", 1)[0].decode()
      sock.close()

      if name == expect:
          print(f"bound_interface={name}")
          sys.exit(0)

      print(f"bound_interface={name!r}, expected={expect!r}", file=sys.stderr)
      sys.exit(1)
      PY
      EOF

      cat >$out/bin/systemd-ebpf-device <<'EOF'
      #!${pkgs.runtimeShell}
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import errno
      import os
      import sys

      with open("/dev/null", "wb", buffering=0) as f:
          f.write(b"")

      try:
          fd = os.open("/dev/zero", os.O_RDONLY)
      except OSError as e:
          if e.errno in (errno.EACCES, errno.EPERM):
              print(f"device_zero_denied_errno={e.errno}")
              sys.exit(0)
          print(f"/dev/zero failed with unexpected errno={e.errno}", file=sys.stderr)
          sys.exit(1)
      else:
          os.close(fd)
          print("/dev/zero unexpectedly opened", file=sys.stderr)
          sys.exit(1)
      PY
      EOF

      cat >$out/bin/systemd-ebpf-open-proc <<'EOF'
      #!${pkgs.runtimeShell}
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import errno
      import sys

      try:
          with open("/proc/self/mounts", "rb") as f:
              f.read(1)
      except OSError as e:
          if e.errno in (errno.EACCES, errno.EPERM):
              print(f"proc_open_denied_errno={e.errno}")
              sys.exit(0)
          print(f"proc open failed with unexpected errno={e.errno}", file=sys.stderr)
          sys.exit(1)

      print("proc open unexpectedly succeeded", file=sys.stderr)
      sys.exit(1)
      PY
      EOF

      chmod +x $out/bin/*
    '';

    staticBusybox = pkgs.runCommand "systemd-ebpf-static-busybox" { } ''
      mkdir -p $out/bin
      cp -L ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/busybox
      chmod 0755 $out/bin/busybox
    '';

    systemdEbpfForeign = pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-foreign";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "systemd-ebpf-foreign.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <linux/bpf.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/stat.h>
        #include <sys/syscall.h>
        #include <unistd.h>

        static int bpf_cmd(enum bpf_cmd cmd, union bpf_attr *attr)
        {
          return syscall(SYS_bpf, cmd, attr, sizeof(*attr));
        }

        static int load_deny_skb_prog(enum bpf_attach_type attach_type)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_CGROUP_SKB;
          attr.expected_attach_type = attach_type;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_foreign");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0) {
            fprintf(stderr, "BPF_PROG_LOAD failed: errno=%d\n", errno);
            return -1;
          }

          return fd;
        }

        static int pin_prog(int fd, const char *path)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.pathname = (uint64_t)(uintptr_t)path;
          attr.bpf_fd = fd;

          (void)unlink(path);
          if (bpf_cmd(BPF_OBJ_PIN, &attr) < 0) {
            fprintf(stderr, "BPF_OBJ_PIN %s failed: errno=%d\n", path, errno);
            return -1;
          }

          return 0;
        }

        int main(int argc, char **argv)
        {
          const char *path;
          enum bpf_attach_type attach_type = BPF_CGROUP_INET_EGRESS;
          int fd;

          if (argc == 2) {
            path = argv[1];
          } else if (argc == 3) {
            if (strcmp(argv[1], "egress") == 0)
              attach_type = BPF_CGROUP_INET_EGRESS;
            else if (strcmp(argv[1], "ingress") == 0)
              attach_type = BPF_CGROUP_INET_INGRESS;
            else {
              fprintf(stderr, "unknown attach direction: %s\n", argv[1]);
              return 2;
            }
            path = argv[2];
          } else {
            fprintf(stderr, "usage: %s [ingress|egress] /sys/fs/bpf/PATH\n", argv[0]);
            return 2;
          }

          if (mkdir("/sys/fs/bpf", 0755) < 0 && errno != EEXIST) {
            fprintf(stderr, "mkdir /sys/fs/bpf failed: errno=%d\n", errno);
            return 1;
          }

          fd = load_deny_skb_prog(attach_type);
          if (fd < 0)
            return 1;

          if (pin_prog(fd, path) < 0) {
            close(fd);
            return 1;
          }

          printf("foreign_bpf_program_pinned=%s\n", path);
          close(fd);
          return 0;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o systemd-ebpf-foreign
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 systemd-ebpf-foreign $out/bin/systemd-ebpf-foreign
        runHook postInstall
      '';
    };

    systemdEbpfPrivateBpfDelegate = pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-private-bpf-delegate";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "systemd-ebpf-private-bpf-delegate.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <fcntl.h>
        #include <linux/bpf.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <string.h>
        #include <sys/syscall.h>
        #include <unistd.h>

        static int bpf_cmd(enum bpf_cmd cmd, union bpf_attr *attr)
        {
          return syscall(SYS_bpf, cmd, attr, sizeof(*attr));
        }

        static int create_token(int bpffs_fd)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.token_create.bpffs_fd = bpffs_fd;

          fd = bpf_cmd(BPF_TOKEN_CREATE, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int create_array_map_with_token(int token_fd)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint64_t);
          attr.max_entries = 1;
          attr.map_flags = BPF_F_TOKEN_FD;
          attr.map_token_fd = token_fd;
          snprintf(attr.map_name, sizeof(attr.map_name), "sd_privtok");

          fd = bpf_cmd(BPF_MAP_CREATE, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int ringbuf_map_create_errno_with_token(int token_fd)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_RINGBUF;
          attr.max_entries = 4096;
          attr.map_flags = BPF_F_TOKEN_FD;
          attr.map_token_fd = token_fd;
          snprintf(attr.map_name, sizeof(attr.map_name), "sd_privring");

          fd = bpf_cmd(BPF_MAP_CREATE, &attr);
          if (fd >= 0) {
            close(fd);
            return 0;
          }

          return errno;
        }

        static int raw_tracepoint_prog_load_errno_with_token(int token_fd)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          char license[] = "GPL";
          char log_buf[4096];
          union bpf_attr attr;
          int fd;

          memset(log_buf, 0, sizeof(log_buf));
          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_RAW_TRACEPOINT;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)license;
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          attr.log_size = sizeof(log_buf);
          attr.log_level = 1;
          attr.prog_flags = BPF_F_TOKEN_FD;
          attr.prog_token_fd = token_fd;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_rawtp");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd >= 0) {
            close(fd);
            return 0;
          }

          return errno;
        }

        static int map_update_errno(int map_fd, uint32_t key, uint64_t value)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&value;
          attr.flags = BPF_ANY;

          if (bpf_cmd(BPF_MAP_UPDATE_ELEM, &attr) == 0)
            return 0;

          return errno;
        }

        static int map_lookup_errno(int map_fd, uint32_t key, uint64_t *value)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)value;

          if (bpf_cmd(BPF_MAP_LOOKUP_ELEM, &attr) == 0)
            return 0;

          return errno;
        }

        int main(int argc, char **argv)
        {
          int deny_broad = argc == 2 && strcmp(argv[1], "deny-broad") == 0;
          const char *prefix = deny_broad ?
            "private_bpf_broad_delegate" :
            "private_bpf_delegate";
          uint64_t value = 0x7072697662706601ULL;
          uint64_t found = 0;
          uint32_t key = 0;
          int bpffs_fd;
          int token_fd;
          int map_fd;
          int rawtp_err;
          int ringbuf_err;
          int err;

          bpffs_fd = open("/sys/fs/bpf", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (bpffs_fd < 0) {
            printf("%s_bpffs_open_errno=%d\n", prefix, errno);
            return 1;
          }
          printf("%s_bpffs_open_errno=0\n", prefix);

          token_fd = create_token(bpffs_fd);
          if (token_fd < 0) {
            printf("%s_token_create_errno=%d\n", prefix, -token_fd);
            close(bpffs_fd);
            return deny_broad && (-token_fd == EPERM || -token_fd == EACCES) ? 0 : 1;
          }
          printf("%s_token_create_errno=0\n", prefix);

          if (deny_broad) {
            ringbuf_err = ringbuf_map_create_errno_with_token(token_fd);
            printf("%s_ringbuf_map_create_errno=%d\n", prefix, ringbuf_err);

            rawtp_err = raw_tracepoint_prog_load_errno_with_token(token_fd);
            printf("%s_raw_tracepoint_prog_load_errno=%d\n", prefix, rawtp_err);

            close(token_fd);
            close(bpffs_fd);

            return (ringbuf_err == EPERM || ringbuf_err == EACCES) &&
              (rawtp_err == EPERM || rawtp_err == EACCES) ? 0 : 1;
          }

          map_fd = create_array_map_with_token(token_fd);
          if (map_fd < 0) {
            printf("%s_array_map_create_errno=%d\n", prefix, -map_fd);
            close(token_fd);
            close(bpffs_fd);
            return 1;
          }
          printf("%s_array_map_create_errno=0\n", prefix);

          err = map_update_errno(map_fd, key, value);
          printf("%s_array_map_update_errno=%d\n", prefix, err);
          if (err) {
            close(map_fd);
            close(token_fd);
            close(bpffs_fd);
            return 1;
          }

          err = map_lookup_errno(map_fd, key, &found);
          printf("%s_array_map_lookup_errno=%d\n", prefix, err);
          printf("%s_array_map_lookup_value=0x%llx\n", prefix,
                 (unsigned long long)found);

          ringbuf_err = ringbuf_map_create_errno_with_token(token_fd);
          printf("%s_ringbuf_map_create_errno=%d\n", prefix, ringbuf_err);

          close(map_fd);
          close(token_fd);
          close(bpffs_fd);

          return err == 0 &&
            found == value &&
            (ringbuf_err == EPERM || ringbuf_err == EACCES) ? 0 : 1;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o systemd-ebpf-private-bpf-delegate
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 systemd-ebpf-private-bpf-delegate \
          $out/bin/systemd-ebpf-private-bpf-delegate
        runHook postInstall
      '';
    };

    systemdEbpfFdLeakProbe = pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-fd-leak-probe";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "systemd-ebpf-fd-leak-probe.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <arpa/inet.h>
        #include <fcntl.h>
        #include <limits.h>
        #include <linux/bpf.h>
        #include <linux/btf.h>
        #include <netinet/in.h>
        #include <stddef.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/mman.h>
        #include <sys/mount.h>
        #include <sys/socket.h>
        #include <sys/stat.h>
        #include <sys/syscall.h>
        #include <sys/un.h>
        #include <unistd.h>

        static int bpf_cmd(enum bpf_cmd cmd, union bpf_attr *attr)
        {
          return syscall(SYS_bpf, cmd, attr, sizeof(*attr));
        }

        #define INSN_ALU64_IMM(OP, DST, IMM) \
          ((struct bpf_insn){ .code = BPF_ALU64 | BPF_OP(OP) | BPF_K, .dst_reg = (DST), .imm = (IMM) })
        #define INSN_ALU64_REG(OP, DST, SRC) \
          ((struct bpf_insn){ .code = BPF_ALU64 | BPF_OP(OP) | BPF_X, .dst_reg = (DST), .src_reg = (SRC) })
        #define INSN_MOV64_IMM(DST, IMM) INSN_ALU64_IMM(BPF_MOV, DST, IMM)
        #define INSN_MOV64_REG(DST, SRC) \
          ((struct bpf_insn){ .code = BPF_ALU64 | BPF_MOV | BPF_X, .dst_reg = (DST), .src_reg = (SRC) })
        #define INSN_ST_MEM(SIZE, DST, OFF, IMM) \
          ((struct bpf_insn){ .code = BPF_ST | BPF_SIZE(SIZE) | BPF_MEM, .dst_reg = (DST), .off = (OFF), .imm = (IMM) })
        #define INSN_STX_MEM(SIZE, DST, SRC, OFF) \
          ((struct bpf_insn){ .code = BPF_STX | BPF_SIZE(SIZE) | BPF_MEM, .dst_reg = (DST), .src_reg = (SRC), .off = (OFF) })
        #define INSN_LDX_MEM(SIZE, DST, SRC, OFF) \
          ((struct bpf_insn){ .code = BPF_LDX | BPF_SIZE(SIZE) | BPF_MEM, .dst_reg = (DST), .src_reg = (SRC), .off = (OFF) })
        #define INSN_JMP_IMM(OP, DST, IMM, OFF) \
          ((struct bpf_insn){ .code = BPF_JMP | BPF_OP(OP) | BPF_K, .dst_reg = (DST), .off = (OFF), .imm = (IMM) })
        #define INSN_CALL(FUNC) \
          ((struct bpf_insn){ .code = BPF_JMP | BPF_CALL, .imm = (FUNC) })
        #define INSN_EXIT() \
          ((struct bpf_insn){ .code = BPF_JMP | BPF_EXIT })
        #define INSN_LD_MAP_FD(DST, FD) \
          ((struct bpf_insn){ .code = BPF_LD | BPF_DW | BPF_IMM, .dst_reg = (DST), .src_reg = BPF_PSEUDO_MAP_FD, .imm = (FD) }), \
          ((struct bpf_insn){ .code = 0 })
        #define INSN_LD_PSEUDO_FUNC(DST, OFF) \
          ((struct bpf_insn){ .code = BPF_LD | BPF_DW | BPF_IMM, .dst_reg = (DST), .src_reg = BPF_PSEUDO_FUNC, .imm = (OFF) }), \
          ((struct bpf_insn){ .code = 0 })

        #define RAW_BTF_INFO_ENC(KIND, KIND_FLAG, VLEN) \
          (((!!(KIND_FLAG)) << 31) | ((KIND) << 24) | ((VLEN) & 0xffff))
        #define RAW_BTF_TYPE_ENC(NAME, INFO, SIZE_OR_TYPE) \
          (NAME), (INFO), (SIZE_OR_TYPE)
        #define RAW_BTF_INT_ENC(ENCODING, BITS_OFFSET, NR_BITS) \
          ((ENCODING) << 24 | (BITS_OFFSET) << 16 | (NR_BITS))
        #define RAW_BTF_TYPE_INT_ENC(NAME, ENCODING, BITS_OFFSET, BITS, SZ) \
          RAW_BTF_TYPE_ENC((NAME), RAW_BTF_INFO_ENC(BTF_KIND_INT, 0, 0), (SZ)), \
          RAW_BTF_INT_ENC((ENCODING), (BITS_OFFSET), (BITS))
        #define RAW_BTF_PTR_ENC(TYPE) \
          RAW_BTF_TYPE_ENC(0, RAW_BTF_INFO_ENC(BTF_KIND_PTR, 0, 0), (TYPE))
        #define RAW_BTF_FUNC_PROTO_ENC(RET_TYPE, NARGS) \
          RAW_BTF_TYPE_ENC(0, RAW_BTF_INFO_ENC(BTF_KIND_FUNC_PROTO, 0, (NARGS)), (RET_TYPE))
        #define RAW_BTF_FUNC_PROTO_ARG_ENC(NAME, TYPE) \
          (NAME), (TYPE)
        #define RAW_BTF_FUNC_ENC(NAME, FUNC_PROTO) \
          RAW_BTF_TYPE_ENC((NAME), RAW_BTF_INFO_ENC(BTF_KIND_FUNC, 0, 0), (FUNC_PROTO))

        static void die_errno(const char *what)
        {
          fprintf(stderr, "%s failed: errno=%d\n", what, errno);
          exit(1);
        }

        static void print_ns_link(const char *label, const char *name)
        {
          char path[128];
          char target[256];
          ssize_t len;

          snprintf(path, sizeof(path), "/proc/%s/ns/%s", label, name);
          len = readlink(path, target, sizeof(target) - 1);
          if (len < 0) {
            printf("ns_%s_%s_errno=%d\n", label, name, errno);
            return;
          }

          target[len] = '\0';
          printf("ns_%s_%s=%s\n", label, name, target);
        }

        static void print_query_namespace_state(void)
        {
          static const char * const names[] = {
            "user",
            "pid",
            "pid_for_children",
            "cgroup",
            "syslog",
            "tracing",
            "lsm",
          };
          size_t i;

          for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
            print_ns_link("self", names[i]);
          for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
            print_ns_link("1", names[i]);
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

        static int send_fd_over_socket(const char *socket_path, int fd)
        {
          struct sockaddr_un addr;
          struct msghdr msg;
          struct cmsghdr *cmsg;
          struct iovec iov;
          char data = 'F';
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

        static int send_fd_u32_over_socket(const char *socket_path, int fd, uint32_t value)
        {
          struct sockaddr_un addr;
          struct msghdr msg;
          struct cmsghdr *cmsg;
          struct iovec iov;
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
          iov.iov_base = &value;
          iov.iov_len = sizeof(value);
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

        static int recv_fd_u32_over_socket(const char *socket_path, uint32_t *value)
        {
          struct sockaddr_un addr;
          struct msghdr msg;
          struct cmsghdr *cmsg;
          struct iovec iov;
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
          *value = 0;
          iov.iov_base = value;
          iov.iov_len = sizeof(*value);
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


        static int load_allow_egress_prog(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 1,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_CGROUP_SKB;
          attr.expected_attach_type = BPF_CGROUP_INET_EGRESS;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_fdleak");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0)
            die_errno("BPF_PROG_LOAD");

          return fd;
        }

        static int load_raw_tracepoint_prog(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 0,
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
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_rawtp");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0)
            die_errno("BPF_PROG_LOAD raw_tracepoint");

          return fd;
        }

        static int query_errno(int cgroup_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.query.target_fd = cgroup_fd;
          attr.query.attach_type = BPF_CGROUP_INET_EGRESS;

          if (bpf_cmd(BPF_PROG_QUERY, &attr) == 0)
            return 0;
          return errno;
        }

        static int query_attach_count(int cgroup_fd, enum bpf_attach_type attach_type,
                                      __u32 flags, __u32 *count)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.query.target_fd = cgroup_fd;
          attr.query.attach_type = attach_type;
          attr.query.query_flags = flags;

          if (bpf_cmd(BPF_PROG_QUERY, &attr) == 0) {
            *count = attr.query.prog_cnt;
            return 0;
          }

          *count = 0;
          return errno;
        }

        static int query_attach_ids(int cgroup_fd, enum bpf_attach_type attach_type,
                                    __u32 flags, __u32 *ids, __u32 capacity,
                                    __u32 *count)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.query.target_fd = cgroup_fd;
          attr.query.attach_type = attach_type;
          attr.query.query_flags = flags;
          attr.query.prog_cnt = capacity;
          attr.query.prog_ids = (uint64_t)(uintptr_t)ids;

          if (bpf_cmd(BPF_PROG_QUERY, &attr) == 0) {
            *count = attr.query.prog_cnt;
            return 0;
          }

          *count = attr.query.prog_cnt;
          return errno;
        }

        static void print_id_list(const char *name, const __u32 *ids,
                                  __u32 count, __u32 capacity)
        {
          __u32 i;

          printf("%s=", name);
          for (i = 0; i < count && i < capacity; i++)
            printf("%s%u", i ? "," : "", ids[i]);
          printf("\n");
        }

        static int prog_id_errno(int prog_fd, __u32 *id)
        {
          struct bpf_prog_info info;
          union bpf_attr attr;

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          attr.info.bpf_fd = prog_fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (bpf_cmd(BPF_OBJ_GET_INFO_BY_FD, &attr) == 0) {
            *id = info.id;
            return 0;
          }

          *id = 0;
          return errno;
        }

        static char *current_cgroup_path(void)
        {
          char line[4096], *path, *nl, *ret;
          FILE *f;
          size_t len;

          f = fopen("/proc/self/cgroup", "re");
          if (!f)
            die_errno("/proc/self/cgroup");

          while (fgets(line, sizeof(line), f)) {
            path = strstr(line, "::");
            if (!path)
              continue;

            path += 2;
            nl = strchr(path, '\n');
            if (nl)
              *nl = '\0';

            if (strcmp(path, "/") == 0)
              path = "";

            len = strlen("/sys/fs/cgroup") + strlen(path) + 1;
            ret = malloc(len);
            if (!ret) {
              fclose(f);
              fprintf(stderr, "malloc failed\n");
              exit(1);
            }

            snprintf(ret, len, "/sys/fs/cgroup%s", path);
            fclose(f);
            return ret;
          }

          fclose(f);
          fprintf(stderr, "cgroup v2 path not found in /proc/self/cgroup\n");
          exit(1);
        }

        static int expected_bind_denial_errno(int err)
        {
          return err == EACCES || err == EPERM;
        }

        static int create_cgroup_link_type(int cgroup_fd, int prog_fd,
                                           enum bpf_attach_type attach_type);
        static int fstat_errno(int fd);
        static int detach_errno(int cgroup_fd, int prog_fd);
        static int expected_denial_errno(int err);
        static int prog_info_errno(int prog_fd);
        static int prog_fdinfo_visible(int fd);

        static void print_cap_status_file(const char *label, const char *path)
        {
          char key[64], value[128], line[256];
          FILE *f;

          f = fopen(path, "r");
          if (!f) {
            printf("cap_%s_open_errno=%d\n", label, errno);
            return;
          }

          while (fgets(line, sizeof(line), f)) {
            if (sscanf(line, "%63[^:]: %127s", key, value) != 2)
              continue;
            if (strncmp(key, "Cap", 3) != 0)
              continue;

            printf("cap_%s_%s=%s\n", label, key, value);
          }

          fclose(f);
        }

        static int cap_status(void)
        {
          print_cap_status_file("pid1", "/proc/1/status");
          print_cap_status_file("self", "/proc/self/status");
          print_query_namespace_state();
          return 0;
        }

        struct socket_bind_rule_smoke {
          uint32_t address_family;
          uint32_t protocol;
          uint32_t nr_ports;
          uint32_t port_min;
        };

        static int create_socket_bind_rule_map(const char *name)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(struct socket_bind_rule_smoke);
          attr.max_entries = 1;
          snprintf(attr.map_name, sizeof(attr.map_name), "%s", name);

          return bpf_cmd(BPF_MAP_CREATE, &attr);
        }

        static int update_socket_bind_rule_map(int map_fd, const struct socket_bind_rule_smoke *rule)
        {
          union bpf_attr attr;
          uint32_t key = 0;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)rule;
          attr.flags = BPF_ANY;

          if (bpf_cmd(BPF_MAP_UPDATE_ELEM, &attr) == 0)
            return 0;
          return errno;
        }

        static int load_socket_bind_like_prog(int deny_map_fd, char *log_buf, size_t log_size)
        {
          struct bpf_insn insns[] = {
            INSN_MOV64_REG(BPF_REG_6, BPF_REG_1),
            INSN_ST_MEM(BPF_W, BPF_REG_10, -4, 0),
            INSN_LD_MAP_FD(BPF_REG_1, deny_map_fd),
            INSN_MOV64_REG(BPF_REG_2, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_2, -4),
            INSN_CALL(BPF_FUNC_map_lookup_elem),
            INSN_JMP_IMM(BPF_JEQ, BPF_REG_0, 0, 11),
            INSN_LDX_MEM(BPF_W, BPF_REG_1, BPF_REG_6, offsetof(struct bpf_sock_addr, user_family)),
            INSN_JMP_IMM(BPF_JNE, BPF_REG_1, AF_INET, 9),
            INSN_LDX_MEM(BPF_W, BPF_REG_1, BPF_REG_6, offsetof(struct bpf_sock_addr, family)),
            INSN_JMP_IMM(BPF_JNE, BPF_REG_1, AF_INET, 7),
            INSN_LDX_MEM(BPF_W, BPF_REG_1, BPF_REG_6, offsetof(struct bpf_sock_addr, protocol)),
            INSN_LDX_MEM(BPF_W, BPF_REG_1, BPF_REG_6, offsetof(struct bpf_sock_addr, user_port)),
            INSN_LDX_MEM(BPF_W, BPF_REG_1, BPF_REG_0, offsetof(struct socket_bind_rule_smoke, address_family)),
            INSN_JMP_IMM(BPF_JEQ, BPF_REG_1, AF_UNSPEC, 1),
            INSN_JMP_IMM(BPF_JNE, BPF_REG_1, AF_INET, 2),
            INSN_MOV64_IMM(BPF_REG_0, 0),
            INSN_EXIT(),
            INSN_MOV64_IMM(BPF_REG_0, 1),
            INSN_EXIT(),
          };
          union bpf_attr attr;
          int fd;

          memset(log_buf, 0, log_size);
          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_CGROUP_SOCK_ADDR;
          attr.expected_attach_type = BPF_CGROUP_INET4_BIND;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.log_level = 1;
          attr.log_size = log_size;
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_bind4_like");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int socket_bind_like_smoke(const char *host, int port)
        {
          struct socket_bind_rule_smoke allow_rule = {
            .address_family = 0xffffffffu,
          };
          struct socket_bind_rule_smoke deny_rule = {
            .address_family = AF_UNSPEC,
          };
          char log_buf[32768];
          __u32 count, effective_count;
          int allow_map_fd, deny_map_fd, prog_fd, cgroup_fd, link_fd, probe_link_fd;
          int allow_update_errno, deny_update_errno, probeerr, qerr, qefferr;
          struct sockaddr_in addr;
          char *cgroup_path;
          int binderr = 0;
          int sock;

          allow_map_fd = create_socket_bind_rule_map("sd_b_allow");
          printf("socket_bind_like_allow_map_create_errno=%d\n",
                 allow_map_fd >= 0 ? 0 : errno);
          if (allow_map_fd < 0)
            return 1;

          allow_update_errno = update_socket_bind_rule_map(allow_map_fd, &allow_rule);
          printf("socket_bind_like_allow_map_update_errno=%d\n", allow_update_errno);
          if (allow_update_errno != 0) {
            close(allow_map_fd);
            return 1;
          }

          deny_map_fd = create_socket_bind_rule_map("sd_b_deny");
          printf("socket_bind_like_deny_map_create_errno=%d\n",
                 deny_map_fd >= 0 ? 0 : errno);
          if (deny_map_fd < 0) {
            close(allow_map_fd);
            return 1;
          }

          deny_update_errno = update_socket_bind_rule_map(deny_map_fd, &deny_rule);
          printf("socket_bind_like_deny_map_update_errno=%d\n", deny_update_errno);
          if (deny_update_errno != 0) {
            close(deny_map_fd);
            close(allow_map_fd);
            return 1;
          }

          prog_fd = load_socket_bind_like_prog(deny_map_fd, log_buf, sizeof(log_buf));
          if (prog_fd < 0) {
            printf("socket_bind_like_prog_load_errno=%d\n", -prog_fd);
            printf("socket_bind_like_prog_load_log_begin\n%s\nsocket_bind_like_prog_load_log_end\n", log_buf);
            close(deny_map_fd);
            close(allow_map_fd);
            return 1;
          }

          printf("socket_bind_like_prog_load_errno=0\n");

          probe_link_fd = create_cgroup_link_type(-1, prog_fd, BPF_CGROUP_INET4_BIND);
          if (probe_link_fd >= 0) {
            close(probe_link_fd);
            probeerr = 0;
          } else {
            probeerr = errno;
          }
          printf("socket_bind_like_invalid_link_errno=%d\n", probeerr);

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          link_fd = create_cgroup_link_type(cgroup_fd, prog_fd, BPF_CGROUP_INET4_BIND);
          if (link_fd < 0) {
            printf("socket_bind_like_link_errno=%d\n", errno);
            close(cgroup_fd);
            close(prog_fd);
            close(deny_map_fd);
            close(allow_map_fd);
            free(cgroup_path);
            return 1;
          }

          printf("socket_bind_like_link_errno=0\n");

          qerr = query_attach_count(cgroup_fd, BPF_CGROUP_INET4_BIND, 0, &count);
          qefferr = query_attach_count(cgroup_fd, BPF_CGROUP_INET4_BIND,
                                       BPF_F_QUERY_EFFECTIVE, &effective_count);
          printf("socket_bind_like_query_errno=%d count=%u effective_errno=%d effective_count=%u\n",
                 qerr, count, qefferr, effective_count);

          sock = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
          if (sock < 0)
            die_errno("socket");

          memset(&addr, 0, sizeof(addr));
          addr.sin_family = AF_INET;
          addr.sin_port = htons((uint16_t)port);
          if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
            fprintf(stderr, "invalid IPv4 address: %s\n", host);
            close(sock);
            close(link_fd);
            close(cgroup_fd);
            close(prog_fd);
            close(deny_map_fd);
            close(allow_map_fd);
            free(cgroup_path);
            return 2;
          }

          if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            binderr = errno;

          printf("socket_bind_like_cgroup_path=%s\n", cgroup_path);
          printf("socket_bind_like_bind_errno=%d\n", binderr);

          close(sock);
          close(link_fd);
          close(cgroup_fd);
          close(prog_fd);
          close(deny_map_fd);
          close(allow_map_fd);
          free(cgroup_path);

          return probeerr == EBADF &&
            expected_bind_denial_errno(binderr) ? 0 : 1;
        }

        static int bind_state_test(const char *host, int port, const char *expect)
        {
          __u32 v4_count, v4_effective_count, v6_count, v6_effective_count;
          int cgroup_fd, q4err, q4efferr, q6err, q6efferr;
          struct sockaddr_in addr;
          char *cgroup_path;
          int binderr = 0;
          int sock;

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          q4err = query_attach_count(cgroup_fd, BPF_CGROUP_INET4_BIND, 0, &v4_count);
          q4efferr = query_attach_count(cgroup_fd, BPF_CGROUP_INET4_BIND,
                                        BPF_F_QUERY_EFFECTIVE, &v4_effective_count);
          q6err = query_attach_count(cgroup_fd, BPF_CGROUP_INET6_BIND, 0, &v6_count);
          q6efferr = query_attach_count(cgroup_fd, BPF_CGROUP_INET6_BIND,
                                        BPF_F_QUERY_EFFECTIVE, &v6_effective_count);

          printf("bind_cgroup_path=%s\n", cgroup_path);
          printf("bind_query_v4_errno=%d count=%u effective_errno=%d effective_count=%u\n",
                 q4err, v4_count, q4efferr, v4_effective_count);
          printf("bind_query_v6_errno=%d count=%u effective_errno=%d effective_count=%u\n",
                 q6err, v6_count, q6efferr, v6_effective_count);

          sock = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
          if (sock < 0)
            die_errno("socket");

          memset(&addr, 0, sizeof(addr));
          addr.sin_family = AF_INET;
          addr.sin_port = htons((uint16_t)port);
          if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
            fprintf(stderr, "invalid IPv4 address: %s\n", host);
            close(sock);
            close(cgroup_fd);
            free(cgroup_path);
            return 2;
          }

          if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            binderr = errno;

          printf("bind_probe_errno=%d\n", binderr);

          close(sock);
          close(cgroup_fd);
          free(cgroup_path);

          if (strcmp(expect, "allow") == 0)
            return binderr == 0 ? 0 : 1;
          if (strcmp(expect, "deny") == 0)
            return expected_bind_denial_errno(binderr) ? 0 : 1;

          fprintf(stderr, "unknown expectation: %s\n", expect);
          return 2;
        }

        static int load_deny_bind4_prog(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_CGROUP_SOCK_ADDR;
          attr.expected_attach_type = BPF_CGROUP_INET4_BIND;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_bind4t");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int load_deny_device_prog(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_CGROUP_DEVICE;
          attr.expected_attach_type = BPF_CGROUP_DEVICE;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_devdeny");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int create_cgroup_link_type(int cgroup_fd, int prog_fd,
                                           enum bpf_attach_type attach_type)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = prog_fd;
          attr.link_create.target_fd = cgroup_fd;
          attr.link_create.attach_type = attach_type;

          return bpf_cmd(BPF_LINK_CREATE, &attr);
        }

        static int device_open_denial_errno(void)
        {
          int fd;

          fd = open("/dev/zero", O_RDONLY | O_CLOEXEC);
          if (fd >= 0) {
            close(fd);
            return 0;
          }

          return errno;
        }

        static int device_policy_service_smoke(void)
        {
          __u32 count, effective_count;
          char *cgroup_path;
          int cgroup_fd, qerr, qefferr, null_fd, zeroerr;

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          qerr = query_attach_count(cgroup_fd, BPF_CGROUP_DEVICE, 0, &count);
          qefferr = query_attach_count(cgroup_fd, BPF_CGROUP_DEVICE,
                                       BPF_F_QUERY_EFFECTIVE, &effective_count);
          printf("device_policy_cgroup_path=%s\n", cgroup_path);
          printf("device_policy_query_errno=%d count=%u effective_errno=%d effective_count=%u\n",
                 qerr, count, qefferr, effective_count);

          null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
          if (null_fd < 0) {
            printf("device_null_open_errno=%d\n", errno);
            close(cgroup_fd);
            free(cgroup_path);
            return 1;
          }
          close(null_fd);
          printf("device_null_open_errno=0\n");

          zeroerr = device_open_denial_errno();
          if (zeroerr == EACCES || zeroerr == EPERM) {
            printf("device_zero_denied_errno=%d\n", zeroerr);
            close(cgroup_fd);
            free(cgroup_path);
            return qerr == 0 && qefferr == 0 && effective_count > 0 ? 0 : 1;
          }

          if (zeroerr == 0)
            printf("device_zero_opened_unexpectedly=1\n");
          else
            printf("device_zero_unexpected_errno=%d\n", zeroerr);

          close(cgroup_fd);
          free(cgroup_path);
          return 1;
        }

        static int device_direct_link_smoke(void)
        {
          __u32 count, effective_count;
          int cgroup_fd, prog_fd, link_fd, probe_link_fd;
          int loaderr, probeerr, qerr, qefferr, zeroerr;
          char *cgroup_path;

          prog_fd = load_deny_device_prog();
          if (prog_fd < 0) {
            loaderr = -prog_fd;
            printf("direct_device_prog_load_errno=%d\n", loaderr);
            return 1;
          }
          printf("direct_device_prog_load_errno=0\n");

          probe_link_fd = create_cgroup_link_type(-1, prog_fd, BPF_CGROUP_DEVICE);
          if (probe_link_fd >= 0) {
            close(probe_link_fd);
            probeerr = 0;
          } else {
            probeerr = errno;
          }
          printf("direct_device_invalid_link_errno=%d\n", probeerr);

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          link_fd = create_cgroup_link_type(cgroup_fd, prog_fd, BPF_CGROUP_DEVICE);
          if (link_fd < 0) {
            printf("direct_device_link_errno=%d\n", errno);
            close(cgroup_fd);
            close(prog_fd);
            free(cgroup_path);
            return 1;
          }
          printf("direct_device_link_errno=0\n");

          qerr = query_attach_count(cgroup_fd, BPF_CGROUP_DEVICE, 0, &count);
          qefferr = query_attach_count(cgroup_fd, BPF_CGROUP_DEVICE,
                                       BPF_F_QUERY_EFFECTIVE, &effective_count);
          printf("direct_device_cgroup_path=%s\n", cgroup_path);
          printf("direct_device_query_errno=%d count=%u effective_errno=%d effective_count=%u\n",
                 qerr, count, qefferr, effective_count);

          zeroerr = device_open_denial_errno();
          if (zeroerr == EACCES || zeroerr == EPERM)
            printf("direct_device_zero_denied_errno=%d\n", zeroerr);
          else if (zeroerr == 0)
            printf("direct_device_zero_opened_unexpectedly=1\n");
          else
            printf("direct_device_zero_unexpected_errno=%d\n", zeroerr);

          close(link_fd);
          close(cgroup_fd);
          close(prog_fd);
          free(cgroup_path);

          return probeerr == EBADF &&
            qerr == 0 &&
            qefferr == 0 &&
            effective_count > 0 &&
            (zeroerr == EACCES || zeroerr == EPERM) ? 0 : 1;
        }

        static int bind4_direct_link_smoke(const char *host, int port)
        {
          __u32 count, effective_count;
          int cgroup_fd, prog_fd, link_fd, probe_link_fd;
          int loaderr = 0, probeerr = 0, linkerr = 0, qerr, qefferr;
          struct sockaddr_in addr;
          char *cgroup_path;
          int binderr = 0;
          int sock;

          prog_fd = load_deny_bind4_prog();
          if (prog_fd < 0) {
            loaderr = -prog_fd;
            printf("direct_bind4_prog_load_errno=%d\n", loaderr);
            return 1;
          }

          printf("direct_bind4_prog_load_errno=0\n");

          probe_link_fd = create_cgroup_link_type(-1, prog_fd, BPF_CGROUP_INET4_BIND);
          if (probe_link_fd >= 0) {
            close(probe_link_fd);
            probeerr = 0;
          } else {
            probeerr = errno;
          }
          printf("direct_bind4_invalid_link_errno=%d\n", probeerr);

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          link_fd = create_cgroup_link_type(cgroup_fd, prog_fd, BPF_CGROUP_INET4_BIND);
          if (link_fd < 0) {
            linkerr = errno;
            printf("direct_bind4_link_errno=%d\n", linkerr);
            close(cgroup_fd);
            close(prog_fd);
            free(cgroup_path);
            return 1;
          }

          printf("direct_bind4_link_errno=0\n");

          qerr = query_attach_count(cgroup_fd, BPF_CGROUP_INET4_BIND, 0, &count);
          qefferr = query_attach_count(cgroup_fd, BPF_CGROUP_INET4_BIND,
                                       BPF_F_QUERY_EFFECTIVE, &effective_count);
          printf("direct_bind4_query_errno=%d count=%u effective_errno=%d effective_count=%u\n",
                 qerr, count, qefferr, effective_count);

          sock = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
          if (sock < 0)
            die_errno("socket");

          memset(&addr, 0, sizeof(addr));
          addr.sin_family = AF_INET;
          addr.sin_port = htons((uint16_t)port);
          if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
            fprintf(stderr, "invalid IPv4 address: %s\n", host);
            close(sock);
            close(link_fd);
            close(cgroup_fd);
            close(prog_fd);
            free(cgroup_path);
            return 2;
          }

          if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            binderr = errno;

          printf("direct_bind4_cgroup_path=%s\n", cgroup_path);
          printf("direct_bind4_bind_errno=%d\n", binderr);

          close(sock);
          close(link_fd);
          close(cgroup_fd);
          close(prog_fd);
          free(cgroup_path);

          return probeerr == EBADF &&
            expected_bind_denial_errno(binderr) ? 0 : 1;
        }

        static int query_current_egress_effective(void)
        {
          __u32 direct_ids[8] = { 0 };
          __u32 effective_ids[8] = { 0 };
          __u32 direct_count, effective_count;
          int cgroup_fd, qerr, qefferr;
          char *cgroup_path;

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          qerr = query_attach_ids(cgroup_fd, BPF_CGROUP_INET_EGRESS, 0,
                                  direct_ids, sizeof(direct_ids) / sizeof(direct_ids[0]),
                                  &direct_count);
          qefferr = query_attach_ids(cgroup_fd, BPF_CGROUP_INET_EGRESS,
                                     BPF_F_QUERY_EFFECTIVE, effective_ids,
                                     sizeof(effective_ids) / sizeof(effective_ids[0]),
                                     &effective_count);

          printf("cgroup_query_current_path=%s\n", cgroup_path);
          print_query_namespace_state();
          printf("cgroup_query_egress_errno=%d count=%u first_id=%u\n",
                 qerr, direct_count, direct_ids[0]);
          print_id_list("cgroup_query_egress_ids", direct_ids, direct_count,
                        sizeof(direct_ids) / sizeof(direct_ids[0]));
          printf("cgroup_query_egress_effective_errno=%d count=%u first_id=%u\n",
                 qefferr, effective_count, effective_ids[0]);
          print_id_list("cgroup_query_egress_effective_ids", effective_ids,
                        effective_count,
                        sizeof(effective_ids) / sizeof(effective_ids[0]));

          close(cgroup_fd);
          free(cgroup_path);

          return qerr == 0 &&
            qefferr == 0 ? 0 : 1;
        }

        static int attach_errno(int cgroup_fd, int prog_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.target_fd = cgroup_fd;
          attr.attach_bpf_fd = prog_fd;
          attr.attach_type = BPF_CGROUP_INET_EGRESS;
          attr.attach_flags = BPF_F_ALLOW_MULTI;

          if (bpf_cmd(BPF_PROG_ATTACH, &attr) == 0)
            return 0;
          return errno;
        }

        static int link_create_errno(int cgroup_fd, int prog_fd)
        {
          union bpf_attr attr;
          int link_fd;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = prog_fd;
          attr.link_create.target_fd = cgroup_fd;
          attr.link_create.attach_type = BPF_CGROUP_INET_EGRESS;

          link_fd = bpf_cmd(BPF_LINK_CREATE, &attr);
          if (link_fd >= 0) {
            close(link_fd);
            return 0;
          }
          return errno;
        }

        static int create_cgroup_link(int cgroup_fd, int prog_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = prog_fd;
          attr.link_create.target_fd = cgroup_fd;
          attr.link_create.attach_type = BPF_CGROUP_INET_EGRESS;

          return bpf_cmd(BPF_LINK_CREATE, &attr);
        }

        static int load_host_cgroup_link(int cgroup_fd)
        {
          int prog_fd, link_fd;
          __u32 prog_id = 0;
          int info_err;

          prog_fd = load_allow_egress_prog();
          info_err = prog_id_errno(prog_fd, &prog_id);
          if (info_err != 0) {
            close(prog_fd);
            errno = info_err;
            return -1;
          }

          printf("host_effective_cgroup_prog_id=%u\n", prog_id);

          link_fd = create_cgroup_link(cgroup_fd, prog_fd);
          if (link_fd < 0)
            die_errno("BPF_LINK_CREATE");

          close(prog_fd);
          return link_fd;
        }

        static int create_map(enum bpf_map_type map_type, const char *name);
        static int cgroup_array_map_update_errno(int map_fd, int cgroup_fd);

        static int send_container_prog(const char *socket_path)
        {
          int prog_fd, staterr;
          __u32 prog_id = 0;
          int info_err;

          prog_fd = load_allow_egress_prog();
          if (prog_fd < 0)
            die_errno("BPF_PROG_LOAD container egress");

          staterr = fstat_errno(prog_fd);
          info_err = prog_id_errno(prog_fd, &prog_id);
          printf("container_prog_send_fstat_errno=%d\n", staterr);
          printf("container_prog_send_info_errno=%d\n", info_err);
          printf("container_prog_send_prog_id=%u\n", prog_id);
          fflush(stdout);

          send_fd_over_socket(socket_path, prog_fd);
          close(prog_fd);

          return staterr == 0 && info_err == 0 ? 0 : 1;
        }

        static int recv_container_prog_host_attach(const char *cgroup_path,
                                                   const char *socket_path)
        {
          int prog_fd, cgroup_fd;
          int staterr, fdinfo_seen, info_err, open_err = 0;
          int attach_err = 0, link_err = 0, detach_err = 0;

          prog_fd = recv_fd_over_socket(socket_path);
          staterr = fstat_errno(prog_fd);
          fdinfo_seen = prog_fdinfo_visible(prog_fd);
          info_err = prog_info_errno(prog_fd);

          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0) {
            open_err = errno;
          } else {
            attach_err = attach_errno(cgroup_fd, prog_fd);
            link_err = link_create_errno(cgroup_fd, prog_fd);
            if (attach_err == 0)
              detach_err = detach_errno(cgroup_fd, prog_fd);
            close(cgroup_fd);
          }

          printf("container_prog_host_fstat_errno=%d\n", staterr);
          printf("container_prog_host_fdinfo_visible=%d\n", fdinfo_seen);
          printf("container_prog_host_info_errno=%d\n", info_err);
          printf("container_prog_host_cgroup_open_errno=%d\n", open_err);
          printf("container_prog_host_attach_errno=%d\n", attach_err);
          printf("container_prog_host_link_create_errno=%d\n", link_err);
          printf("container_prog_host_detach_errno=%d\n", detach_err);

          close(prog_fd);

          return staterr == 0 &&
            open_err == 0 &&
            expected_denial_errno(attach_err) &&
            expected_denial_errno(link_err) ? 0 : 1;
        }

        static int send_container_cgroup_array(const char *socket_path)
        {
          char *cgroup_path;
          int map_fd, cgroup_fd, same_ct_update_err;

          map_fd = create_map(BPF_MAP_TYPE_CGROUP_ARRAY, "sd_ct_cgarr");
          if (map_fd < 0)
            die_errno("BPF_MAP_CREATE container cgroup array");

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          same_ct_update_err = cgroup_array_map_update_errno(map_fd, cgroup_fd);
          printf("container_cgroup_array_send_self_update_errno=%d\n",
                 same_ct_update_err);
          fflush(stdout);

          if (same_ct_update_err != 0) {
            close(cgroup_fd);
            close(map_fd);
            free(cgroup_path);
            return 1;
          }

          send_fd_over_socket(socket_path, map_fd);

          close(cgroup_fd);
          close(map_fd);
          free(cgroup_path);

          return 0;
        }

        static int recv_container_cgroup_array_host_update(const char *cgroup_path,
                                                           const char *socket_path)
        {
          int map_fd, cgroup_fd;
          int staterr, open_err = 0, update_err = 0;

          map_fd = recv_fd_over_socket(socket_path);
          staterr = fstat_errno(map_fd);

          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0) {
            open_err = errno;
          } else {
            update_err = cgroup_array_map_update_errno(map_fd, cgroup_fd);
            close(cgroup_fd);
          }

          printf("container_cgroup_array_host_fstat_errno=%d\n", staterr);
          printf("container_cgroup_array_host_cgroup_open_errno=%d\n", open_err);
          printf("container_cgroup_array_host_update_errno=%d\n", update_err);

          close(map_fd);

          return staterr == 0 &&
            open_err == 0 &&
            expected_denial_errno(update_err) ? 0 : 1;
        }

        static int load_host_raw_tracepoint_link(void)
        {
          const char *tp_name = "sched_process_fork";
          union bpf_attr attr;
          int prog_fd, link_fd, saved_errno;

          prog_fd = load_raw_tracepoint_prog();

          memset(&attr, 0, sizeof(attr));
          attr.raw_tracepoint.name = (uint64_t)(uintptr_t)tp_name;
          attr.raw_tracepoint.prog_fd = prog_fd;

          link_fd = bpf_cmd(BPF_RAW_TRACEPOINT_OPEN, &attr);
          if (link_fd < 0) {
            saved_errno = errno;
            close(prog_fd);
            errno = saved_errno;
            die_errno("BPF_RAW_TRACEPOINT_OPEN");
          }

          close(prog_fd);
          return link_fd;
        }

        static int hold_host_cgroup_egress_link(const char *cgroup_path,
                                                const char *ready_path,
                                                const char *stop_path)
        {
          int cgroup_fd, link_fd;
          FILE *ready;

          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          printf("host_effective_cgroup_opened=1\n");
          printf("host_effective_cgroup_link_create_start=1\n");
          fflush(stdout);

          link_fd = load_host_cgroup_link(cgroup_fd);
          close(cgroup_fd);

          if (link_fd < 0)
            die_errno("load_host_cgroup_link");

          printf("host_effective_cgroup_link_fd=%d\n", link_fd);
          printf("host_effective_cgroup_path=%s\n", cgroup_path);
          fflush(stdout);

          ready = fopen(ready_path, "we");
          if (!ready)
            die_errno(ready_path);
          fprintf(ready, "ready\n");
          fclose(ready);

          while (access(stop_path, F_OK) != 0)
            usleep(100000);

          close(link_fd);
          printf("host_effective_cgroup_link_closed=1\n");
          return 0;
        }

        static int link_info_errno(int link_fd)
        {
          struct bpf_link_info info;
          union bpf_attr attr;

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          attr.info.bpf_fd = link_fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (bpf_cmd(BPF_OBJ_GET_INFO_BY_FD, &attr) == 0)
            return 0;
          return errno;
        }

        static int link_update_errno(int link_fd, int prog_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.link_update.link_fd = link_fd;
          attr.link_update.new_prog_fd = prog_fd;

          if (bpf_cmd(BPF_LINK_UPDATE, &attr) == 0)
            return 0;
          return errno;
        }

        static int link_detach_errno(int link_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.link_detach.link_fd = link_fd;

          if (bpf_cmd(BPF_LINK_DETACH, &attr) == 0)
            return 0;
          return errno;
        }

        static int link_iter_create_errno(int link_fd)
        {
          union bpf_attr attr;
          int iter_fd;

          memset(&attr, 0, sizeof(attr));
          attr.iter_create.link_fd = link_fd;

          iter_fd = bpf_cmd(BPF_ITER_CREATE, &attr);
          if (iter_fd >= 0) {
            close(iter_fd);
            return 0;
          }
          return errno;
        }

        static int link_pin_errno(int link_fd)
        {
          const char *path = "/sys/fs/bpf/systemd-ebpf-leaked-host-link";
          union bpf_attr attr;

          unlink(path);
          memset(&attr, 0, sizeof(attr));
          attr.pathname = (uint64_t)(uintptr_t)path;
          attr.bpf_fd = link_fd;

          if (bpf_cmd(BPF_OBJ_PIN, &attr) == 0) {
            unlink(path);
            return 0;
          }
          return errno;
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

          fd = bpf_cmd(BPF_BTF_LOAD, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int create_btf_array_map(const char *name)
        {
          union bpf_attr attr;
          int btf_fd, map_fd, saved_errno;

          btf_fd = load_minimal_btf();
          if (btf_fd < 0)
            return btf_fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_ARRAY;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint32_t);
          attr.max_entries = 1;
          attr.btf_fd = btf_fd;
          attr.btf_key_type_id = 1;
          attr.btf_value_type_id = 1;
          snprintf(attr.map_name, sizeof(attr.map_name), "%s", name);

          map_fd = bpf_cmd(BPF_MAP_CREATE, &attr);
          saved_errno = errno;
          close(btf_fd);
          errno = saved_errno;

          return map_fd;
        }

        static int pin_fd_path(int fd, const char *path)
        {
          union bpf_attr attr;

          unlink(path);
          memset(&attr, 0, sizeof(attr));
          attr.pathname = (uint64_t)(uintptr_t)path;
          attr.bpf_fd = fd;

          if (bpf_cmd(BPF_OBJ_PIN, &attr) == 0)
            return 0;
          return errno;
        }

        static int mount_temp_bpffs(char *dir, size_t dir_size)
        {
          int saved_errno;

          if (snprintf(dir, dir_size, "/run/systemd-ebpf-host-bpffs-%ld",
                       (long)getpid()) >= (int)dir_size)
            return -ENAMETOOLONG;

          if (mkdir(dir, 0700) < 0)
            return -errno;

          if (mount("bpf", dir, "bpf", MS_NOSUID | MS_NODEV | MS_NOEXEC,
                    "mode=700") == 0)
            return 0;

          saved_errno = errno;
          rmdir(dir);
          dir[0] = '\0';
          return -saved_errno;
        }

        static void cleanup_temp_bpffs(const char *dir)
        {
          if (!dir[0])
            return;

          umount2(dir, MNT_DETACH);
          rmdir(dir);
        }

        static int send_pinned_map_file(const char *socket_path)
        {
          char mount_dir[128] = "";
          char path[PATH_MAX];
          int map_fd, file_fd, pin_err, saved_errno;

          pin_err = mount_temp_bpffs(mount_dir, sizeof(mount_dir));
          if (pin_err < 0) {
            errno = -pin_err;
            die_errno("mount host bpffs");
          }

          if (snprintf(path, sizeof(path), "%s/systemd-ebpf-host-readable-map",
                       mount_dir) >= (int)sizeof(path)) {
            cleanup_temp_bpffs(mount_dir);
            errno = ENAMETOOLONG;
            die_errno("host bpffs pin path");
          }

          map_fd = create_btf_array_map("sd_bpffs_read");
          if (map_fd < 0) {
            cleanup_temp_bpffs(mount_dir);
            errno = -map_fd;
            die_errno("BPF_MAP_CREATE BTF array");
          }

          pin_err = pin_fd_path(map_fd, path);
          if (pin_err != 0) {
            close(map_fd);
            cleanup_temp_bpffs(mount_dir);
            errno = pin_err;
            die_errno("BPF_OBJ_PIN BTF array");
          }

          file_fd = open(path, O_RDONLY | O_CLOEXEC);
          saved_errno = errno;
          unlink(path);
          if (file_fd < 0) {
            close(map_fd);
            cleanup_temp_bpffs(mount_dir);
            errno = saved_errno;
            die_errno("open pinned BTF array");
          }

          send_fd_over_socket(socket_path, file_fd);
          close(file_fd);
          close(map_fd);
          cleanup_temp_bpffs(mount_dir);
          return 0;
        }

        static int fd_read_errno(int fd)
        {
          char buf[256];

          if (read(fd, buf, sizeof(buf)) >= 0)
            return 0;
          return errno;
        }

        static int recv_pinned_map_file(const char *socket_path)
        {
          int fd, staterr, read_err;

          fd = recv_fd_over_socket(socket_path);
          staterr = fstat_errno(fd);
          read_err = fd_read_errno(fd);

          printf("leaked_bpffs_map_file_fstat_errno=%d\n", staterr);
          printf("leaked_bpffs_map_file_read_errno=%d\n", read_err);

          close(fd);

          return staterr == 0 && read_err == EACCES ? 0 : 1;
        }

        static int detach_errno(int cgroup_fd, int prog_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.target_fd = cgroup_fd;
          attr.attach_bpf_fd = prog_fd;
          attr.attach_type = BPF_CGROUP_INET_EGRESS;

          if (bpf_cmd(BPF_PROG_DETACH, &attr) == 0)
            return 0;
          return errno;
        }

        static int create_map_flags(enum bpf_map_type map_type, const char *name,
                                    uint32_t map_flags)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = map_type;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint32_t);
          attr.max_entries = 1;
          attr.map_flags = map_flags;
          snprintf(attr.map_name, sizeof(attr.map_name), "%s", name);

          return bpf_cmd(BPF_MAP_CREATE, &attr);
        }

        static int create_map(enum bpf_map_type map_type, const char *name)
        {
          return create_map_flags(map_type, name, 0);
        }

        static int create_arena_map(const char *name)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_ARENA;
          attr.max_entries = 1;
          attr.map_flags = BPF_F_MMAPABLE;
          snprintf(attr.map_name, sizeof(attr.map_name), "%s", name);

          return bpf_cmd(BPF_MAP_CREATE, &attr);
        }

        static int create_ringbuf_map(const char *name)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_RINGBUF;
          attr.max_entries = 4096;
          snprintf(attr.map_name, sizeof(attr.map_name), "%s", name);

          return bpf_cmd(BPF_MAP_CREATE, &attr);
        }

        static int map_create_errno(enum bpf_map_type map_type, const char *name)
        {
          int map_fd;

          map_fd = create_map(map_type, name);
          if (map_fd >= 0) {
            close(map_fd);
            return 0;
          }

          return errno;
        }

        static int map_info_errno(int map_fd)
        {
          struct bpf_map_info info;
          union bpf_attr attr;

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          attr.info.bpf_fd = map_fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (bpf_cmd(BPF_OBJ_GET_INFO_BY_FD, &attr) == 0)
            return 0;
          return errno;
        }

        static int map_id_errno(int map_fd, uint32_t *id)
        {
          struct bpf_map_info info;
          union bpf_attr attr;

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          attr.info.bpf_fd = map_fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (bpf_cmd(BPF_OBJ_GET_INFO_BY_FD, &attr) == 0) {
            *id = info.id;
            return 0;
          }
          return errno;
        }

        static int map_get_fd_by_id_errno(uint32_t id)
        {
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_id = id;

          fd = bpf_cmd(BPF_MAP_GET_FD_BY_ID, &attr);
          if (fd >= 0) {
            close(fd);
            return 0;
          }
          return errno;
        }

        static int map_lookup_errno(int map_fd)
        {
          union bpf_attr attr;
          uint32_t key = 0;
          uint32_t value = 0;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&value;

          if (bpf_cmd(BPF_MAP_LOOKUP_ELEM, &attr) == 0)
            return 0;
          return errno;
        }

        static int map_update_errno(int map_fd)
        {
          union bpf_attr attr;
          uint32_t key = 0;
          uint32_t value = 1;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&value;
          attr.flags = BPF_ANY;

          if (bpf_cmd(BPF_MAP_UPDATE_ELEM, &attr) == 0)
            return 0;
          return errno;
        }

        static int map_mmap_errno(int map_fd)
        {
          long page_size = sysconf(_SC_PAGESIZE);
          void *addr;

          if (page_size <= 0)
            page_size = 4096;

          addr = mmap(NULL, page_size, PROT_READ, MAP_SHARED, map_fd, 0);
          if (addr != MAP_FAILED) {
            munmap(addr, page_size);
            return 0;
          }

          return errno;
        }

        static int map_mmap_offset_errno(int map_fd)
        {
          long page_size = sysconf(_SC_PAGESIZE);
          void *addr;

          if (page_size <= 0)
            page_size = 4096;

          addr = mmap(NULL, page_size, PROT_READ, MAP_SHARED, map_fd,
                      page_size);
          if (addr != MAP_FAILED) {
            munmap(addr, page_size);
            return 0;
          }

          return errno;
        }

        static int map_lookup_batch_errno(int map_fd)
        {
          union bpf_attr attr;
          uint32_t out_batch = 0;
          uint32_t keys[1] = { 0 };
          uint32_t values[1] = { 0 };

          memset(&attr, 0, sizeof(attr));
          attr.batch.map_fd = map_fd;
          attr.batch.out_batch = (uint64_t)(uintptr_t)&out_batch;
          attr.batch.keys = (uint64_t)(uintptr_t)keys;
          attr.batch.values = (uint64_t)(uintptr_t)values;
          attr.batch.count = 1;

          if (bpf_cmd(BPF_MAP_LOOKUP_BATCH, &attr) == 0)
            return 0;
          return errno;
        }

        static int map_update_batch_errno(int map_fd)
        {
          union bpf_attr attr;
          uint32_t keys[1] = { 0 };
          uint32_t values[1] = { 2 };

          memset(&attr, 0, sizeof(attr));
          attr.batch.map_fd = map_fd;
          attr.batch.keys = (uint64_t)(uintptr_t)keys;
          attr.batch.values = (uint64_t)(uintptr_t)values;
          attr.batch.count = 1;
          attr.batch.elem_flags = BPF_ANY;

          if (bpf_cmd(BPF_MAP_UPDATE_BATCH, &attr) == 0)
            return 0;
          return errno;
        }

        static int map_delete_batch_errno(int map_fd)
        {
          union bpf_attr attr;
          uint32_t keys[1] = { 0 };

          memset(&attr, 0, sizeof(attr));
          attr.batch.map_fd = map_fd;
          attr.batch.keys = (uint64_t)(uintptr_t)keys;
          attr.batch.count = 1;

          if (bpf_cmd(BPF_MAP_DELETE_BATCH, &attr) == 0)
            return 0;
          return errno;
        }

        static int map_freeze_errno(int map_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;

          if (bpf_cmd(BPF_MAP_FREEZE, &attr) == 0)
            return 0;
          return errno;
        }

        static int map_pin_errno(int map_fd)
        {
          const char *path = "/sys/fs/bpf/systemd-ebpf-leaked-host-map";
          union bpf_attr attr;

          unlink(path);
          memset(&attr, 0, sizeof(attr));
          attr.pathname = (uint64_t)(uintptr_t)path;
          attr.bpf_fd = map_fd;

          if (bpf_cmd(BPF_OBJ_PIN, &attr) == 0) {
            unlink(path);
            return 0;
          }
          return errno;
        }

        static int prog_info_errno(int prog_fd)
        {
          struct bpf_prog_info info;
          union bpf_attr attr;

          memset(&info, 0, sizeof(info));
          memset(&attr, 0, sizeof(attr));
          attr.info.bpf_fd = prog_fd;
          attr.info.info_len = sizeof(info);
          attr.info.info = (uint64_t)(uintptr_t)&info;

          if (bpf_cmd(BPF_OBJ_GET_INFO_BY_FD, &attr) == 0)
            return 0;
          return errno;
        }

        static int prog_test_run_errno(int prog_fd)
        {
          union bpf_attr attr;

          memset(&attr, 0, sizeof(attr));
          attr.test.prog_fd = prog_fd;

          if (bpf_cmd(BPF_PROG_TEST_RUN, &attr) == 0)
            return 0;
          return errno;
        }

        static int prog_bind_map_errno(int prog_fd, int *create_err)
        {
          union bpf_attr attr;
          int map_fd;

          map_fd = create_map(BPF_MAP_TYPE_ARRAY, "sd_bind_map");
          if (map_fd < 0) {
            *create_err = errno;
            return errno;
          }
          *create_err = 0;

          memset(&attr, 0, sizeof(attr));
          attr.prog_bind_map.prog_fd = prog_fd;
          attr.prog_bind_map.map_fd = map_fd;

          if (bpf_cmd(BPF_PROG_BIND_MAP, &attr) == 0) {
            close(map_fd);
            return 0;
          }

          close(map_fd);
          return errno;
        }

        static int prog_pin_errno(int prog_fd)
        {
          const char *path = "/sys/fs/bpf/systemd-ebpf-leaked-host-prog";
          union bpf_attr attr;

          unlink(path);
          memset(&attr, 0, sizeof(attr));
          attr.pathname = (uint64_t)(uintptr_t)path;
          attr.bpf_fd = prog_fd;

          if (bpf_cmd(BPF_OBJ_PIN, &attr) == 0) {
            unlink(path);
            return 0;
          }
          return errno;
        }

        static int cgroup_array_update_errno(int cgroup_fd, int *create_err)
        {
          union bpf_attr attr;
          uint32_t key = 0;
          uint32_t value = cgroup_fd;
          int map_fd;

          map_fd = create_map(BPF_MAP_TYPE_CGROUP_ARRAY, "sd_cg_leak");
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

        static int cgroup_array_map_update_errno(int map_fd, int cgroup_fd)
        {
          union bpf_attr attr;
          uint32_t key = 0;
          uint32_t value = cgroup_fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&value;
          attr.flags = BPF_ANY;

          if (bpf_cmd(BPF_MAP_UPDATE_ELEM, &attr) == 0)
            return 0;
          return errno;
        }

        static int fstat_errno(int fd)
        {
          struct stat st;

          if (fstat(fd, &st) == 0)
            return 0;
          return errno;
        }

        static int fdinfo_contains_any(int fd, const char *const *needles, size_t nneedles)
        {
          char path[64], buf[4096];
          ssize_t nread;
          size_t i;
          int info_fd, saved_errno;

          snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", fd);
          info_fd = open(path, O_RDONLY | O_CLOEXEC);
          if (info_fd < 0)
            return -errno;

          nread = read(info_fd, buf, sizeof(buf) - 1);
          saved_errno = errno;
          close(info_fd);
          if (nread < 0)
            return -saved_errno;

          buf[nread] = '\0';
          for (i = 0; i < nneedles; i++) {
            if (strstr(buf, needles[i]))
              return 1;
          }

          return 0;
        }

        static int map_fdinfo_visible(int fd)
        {
          static const char *const needles[] = {
            "map_type:",
            "map_id:",
            "key_size:",
            "value_size:",
            "max_entries:",
          };

          return fdinfo_contains_any(fd, needles, sizeof(needles) / sizeof(needles[0]));
        }

        static int prog_fdinfo_visible(int fd)
        {
          static const char *const needles[] = {
            "prog_type:",
            "prog_id:",
            "prog_tag:",
            "verified_insns:",
          };

          return fdinfo_contains_any(fd, needles, sizeof(needles) / sizeof(needles[0]));
        }

        static int link_fdinfo_visible(int fd)
        {
          static const char *const needles[] = {
            "link_type:",
            "link_id:",
            "prog_id:",
            "cgroup_id:",
            "attach_type:",
          };

          return fdinfo_contains_any(fd, needles, sizeof(needles) / sizeof(needles[0]));
        }

        static int expected_denial_errno(int err)
        {
          return err == EACCES || err == EBADF;
        }

        static int expected_auth_denial_errno(int err)
        {
          return err == EACCES || err == EPERM;
        }

        static int expected_foreign_by_id_denial_errno(int err)
        {
          return expected_auth_denial_errno(err) || err == ENOENT;
        }

        static int load_socket_bind_libbpf_probe_prog(int retval)
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
          attr.prog_type = BPF_PROG_TYPE_CGROUP_SOCK_ADDR;
          attr.expected_attach_type = BPF_CGROUP_INET4_CONNECT;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int socket_bind_libbpf_probe_smoke(void)
        {
          int prog_fd, nonprobe_fd, invalid_link_fd, cgroup_link_fd;
          int invalid_link_err, cgroup_link_err, info_err, test_run_err, pin_err;
          int cgroup_fd;
          char *cgroup_path;

          prog_fd = load_socket_bind_libbpf_probe_prog(0);
          if (prog_fd < 0) {
            printf("socket_bind_libbpf_probe_load_errno=%d\n", -prog_fd);
            return 1;
          }
          printf("socket_bind_libbpf_probe_load_errno=0\n");

          nonprobe_fd = load_socket_bind_libbpf_probe_prog(1);
          if (nonprobe_fd >= 0) {
            close(nonprobe_fd);
            printf("socket_bind_libbpf_probe_nonprobe_load_errno=0\n");
            close(prog_fd);
            return 1;
          }
          printf("socket_bind_libbpf_probe_nonprobe_load_errno=%d\n", -nonprobe_fd);

          invalid_link_fd = create_cgroup_link_type(-1, prog_fd,
                                                    BPF_CGROUP_INET4_CONNECT);
          if (invalid_link_fd >= 0) {
            close(invalid_link_fd);
            invalid_link_err = 0;
          } else {
            invalid_link_err = errno;
          }
          printf("socket_bind_libbpf_probe_invalid_link_errno=%d\n",
                 invalid_link_err);

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          cgroup_link_fd = create_cgroup_link_type(cgroup_fd, prog_fd,
                                                   BPF_CGROUP_INET4_CONNECT);
          if (cgroup_link_fd >= 0) {
            close(cgroup_link_fd);
            cgroup_link_err = 0;
          } else {
            cgroup_link_err = errno;
          }
          printf("socket_bind_libbpf_probe_cgroup_path=%s\n", cgroup_path);
          printf("socket_bind_libbpf_probe_cgroup_link_errno=%d\n",
                 cgroup_link_err);

          info_err = prog_info_errno(prog_fd);
          test_run_err = prog_test_run_errno(prog_fd);
          pin_err = prog_pin_errno(prog_fd);
          printf("socket_bind_libbpf_probe_info_errno=%d\n", info_err);
          printf("socket_bind_libbpf_probe_test_run_errno=%d\n", test_run_err);
          printf("socket_bind_libbpf_probe_pin_errno=%d\n", pin_err);

          close(cgroup_fd);
          close(prog_fd);
          free(cgroup_path);

          return -nonprobe_fd == EPERM &&
            invalid_link_err == EBADF &&
            expected_auth_denial_errno(cgroup_link_err) &&
            expected_auth_denial_errno(info_err) &&
            expected_auth_denial_errno(test_run_err) &&
            pin_err != 0 ? 0 : 1;
        }

        static int cgroup_array_update_fd_errno(int map_fd, int cgroup_fd)
        {
          union bpf_attr attr;
          uint32_t key = 0;
          uint32_t value = (uint32_t)cgroup_fd;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&value;
          attr.flags = BPF_ANY;

          if (bpf_cmd(BPF_MAP_UPDATE_ELEM, &attr) == 0)
            return 0;
          return errno;
        }

        static int lookup_array_u32_errno(int map_fd, uint32_t *value)
        {
          union bpf_attr attr;
          uint32_t key = 0;

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = map_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)value;

          if (bpf_cmd(BPF_MAP_LOOKUP_ELEM, &attr) == 0)
            return 0;
          return errno;
        }

        static int read_sysctl_errno(const char *path)
        {
          char buf[64];
          int fd, err;

          fd = open(path, O_RDONLY | O_CLOEXEC);
          if (fd < 0)
            return errno;

          if (read(fd, buf, sizeof(buf)) >= 0) {
            close(fd);
            return 0;
          }

          err = errno;
          close(fd);
          return err;
        }

        static int write_sysctl_same_value_errno(const char *path)
        {
          char buf[64];
          ssize_t len, written;
          int fd, err;

          fd = open(path, O_RDONLY | O_CLOEXEC);
          if (fd < 0)
            return errno;

          len = read(fd, buf, sizeof(buf));
          err = errno;
          close(fd);
          if (len <= 0)
            return len < 0 ? err : EIO;

          fd = open(path, O_WRONLY | O_CLOEXEC);
          if (fd < 0)
            return errno;

          written = write(fd, buf, (size_t)len);
          err = errno;
          close(fd);
          if (written == len)
            return 0;
          return written < 0 ? err : EIO;
        }

        static int load_sysctl_loop_btf(void)
        {
          struct raw_btf {
            struct btf_header hdr;
            uint32_t types[25];
            char strs[25];
          } __attribute__((packed)) raw = {
            .hdr = {
              .magic = BTF_MAGIC,
              .version = BTF_VERSION,
              .hdr_len = sizeof(struct btf_header),
              .type_len = sizeof(((struct raw_btf *)0)->types),
              .str_off = sizeof(((struct raw_btf *)0)->types),
              .str_len = sizeof(((struct raw_btf *)0)->strs),
            },
            .types = {
              RAW_BTF_TYPE_INT_ENC(1, BTF_INT_SIGNED, 0, 32, 4),
              RAW_BTF_PTR_ENC(0),
              RAW_BTF_FUNC_PROTO_ENC(1, 1),
              RAW_BTF_FUNC_PROTO_ARG_ENC(7, 2),
              RAW_BTF_FUNC_PROTO_ENC(1, 2),
              RAW_BTF_FUNC_PROTO_ARG_ENC(5, 1),
              RAW_BTF_FUNC_PROTO_ARG_ENC(7, 2),
              RAW_BTF_FUNC_ENC(20, 3),
              RAW_BTF_FUNC_ENC(11, 4),
            },
            .strs = "\0int\0i\0ctx\0callback\0main",
          };
          union bpf_attr attr;
          int fd;

          memset(&attr, 0, sizeof(attr));
          attr.btf = (uint64_t)(uintptr_t)&raw;
          attr.btf_size = sizeof(raw);

          fd = bpf_cmd(BPF_BTF_LOAD, &attr);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int load_cgroup_sysctl_like_prog(int seen_map_fd, int cgroup_map_fd,
                                                int ringbuf_fd,
                                                char *log_buf, size_t log_size)
        {
          enum {
            SYSCTL_LOOP_MAIN_TYPE = 5,
            SYSCTL_LOOP_CALLBACK_TYPE = 6,
            SYSCTL_LOOP_CALLBACK_INSN = 59,
          };
          struct bpf_insn insns[] = {
            INSN_MOV64_REG(BPF_REG_6, BPF_REG_1),

            INSN_MOV64_REG(BPF_REG_1, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_1, -16),
            INSN_MOV64_IMM(BPF_REG_2, 16),
            INSN_CALL(BPF_FUNC_get_current_comm),

            INSN_CALL(BPF_FUNC_get_current_cgroup_id),

            INSN_ST_MEM(BPF_DW, BPF_REG_10, -96, 0),
            INSN_ST_MEM(BPF_DW, BPF_REG_10, -88, 0),
            INSN_ST_MEM(BPF_DW, BPF_REG_10, -80, 0),
            INSN_ST_MEM(BPF_DW, BPF_REG_10, -72, 0),
            INSN_ST_MEM(BPF_DW, BPF_REG_10, -64, 0),
            INSN_ST_MEM(BPF_DW, BPF_REG_10, -56, 0),
            INSN_ST_MEM(BPF_DW, BPF_REG_10, -48, 0),
            INSN_ST_MEM(BPF_DW, BPF_REG_10, -40, 0),

            INSN_MOV64_REG(BPF_REG_1, BPF_REG_6),
            INSN_MOV64_REG(BPF_REG_2, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_2, -96),
            INSN_MOV64_IMM(BPF_REG_3, 64),
            INSN_MOV64_IMM(BPF_REG_4, 0),
            INSN_CALL(BPF_FUNC_sysctl_get_name),

            INSN_MOV64_REG(BPF_REG_1, BPF_REG_6),
            INSN_MOV64_REG(BPF_REG_2, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_2, -96),
            INSN_MOV64_IMM(BPF_REG_3, 64),
            INSN_CALL(BPF_FUNC_sysctl_get_current_value),

            INSN_MOV64_REG(BPF_REG_1, BPF_REG_6),
            INSN_MOV64_REG(BPF_REG_2, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_2, -96),
            INSN_MOV64_IMM(BPF_REG_3, 64),
            INSN_CALL(BPF_FUNC_sysctl_get_new_value),

            INSN_LD_MAP_FD(BPF_REG_1, cgroup_map_fd),
            INSN_MOV64_IMM(BPF_REG_2, 0),
            INSN_CALL(BPF_FUNC_current_task_under_cgroup),

            INSN_ST_MEM(BPF_W, BPF_REG_10, -104, 0x53595343),
            INSN_LD_MAP_FD(BPF_REG_1, ringbuf_fd),
            INSN_MOV64_REG(BPF_REG_2, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_2, -104),
            INSN_MOV64_IMM(BPF_REG_3, 4),
            INSN_MOV64_IMM(BPF_REG_4, 0),
            INSN_CALL(BPF_FUNC_ringbuf_output),

            INSN_ST_MEM(BPF_W, BPF_REG_10, -100, 0),
            INSN_LD_MAP_FD(BPF_REG_1, seen_map_fd),
            INSN_MOV64_REG(BPF_REG_2, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_2, -100),
            INSN_CALL(BPF_FUNC_map_lookup_elem),
            INSN_JMP_IMM(BPF_JEQ, BPF_REG_0, 0, 2),
            INSN_MOV64_IMM(BPF_REG_1, 1),
            INSN_STX_MEM(BPF_W, BPF_REG_0, BPF_REG_1, 0),

            INSN_MOV64_IMM(BPF_REG_1, 1),
            INSN_LD_PSEUDO_FUNC(BPF_REG_2, 6),
            INSN_MOV64_IMM(BPF_REG_3, 0),
            INSN_MOV64_IMM(BPF_REG_4, 0),
            INSN_CALL(BPF_FUNC_loop),

            INSN_MOV64_IMM(BPF_REG_0, 1),
            INSN_EXIT(),

            INSN_MOV64_IMM(BPF_REG_0, 0),
            INSN_EXIT(),
          };
          struct bpf_func_info func_info[] = {
            { .insn_off = 0, .type_id = SYSCTL_LOOP_MAIN_TYPE },
            { .insn_off = SYSCTL_LOOP_CALLBACK_INSN,
              .type_id = SYSCTL_LOOP_CALLBACK_TYPE },
          };
          union bpf_attr attr;
          int btf_fd, fd, saved_errno;

          memset(log_buf, 0, log_size);
          btf_fd = load_sysctl_loop_btf();
          if (btf_fd < 0)
            return btf_fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_CGROUP_SYSCTL;
          attr.expected_attach_type = BPF_CGROUP_SYSCTL;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.prog_btf_fd = btf_fd;
          attr.func_info_rec_size = sizeof(func_info[0]);
          attr.func_info_cnt = sizeof(func_info) / sizeof(func_info[0]);
          attr.func_info = (uint64_t)(uintptr_t)func_info;
          attr.log_level = 1;
          attr.log_size = log_size;
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_sysctl");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          saved_errno = errno;
          close(btf_fd);
          errno = saved_errno;
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int load_cgroup_sysctl_var_stack_nonzero_write_prog(
            char *log_buf, size_t log_size)
        {
          enum {
            SYSCTL_LOOP_MAIN_TYPE = 5,
            SYSCTL_LOOP_CALLBACK_TYPE = 6,
            SYSCTL_LOOP_CALLBACK_INSN = 8,
          };
          struct bpf_insn insns[] = {
            INSN_MOV64_IMM(BPF_REG_1, 8),
            INSN_LD_PSEUDO_FUNC(BPF_REG_2, 6),
            INSN_MOV64_IMM(BPF_REG_3, 0),
            INSN_MOV64_IMM(BPF_REG_4, 0),
            INSN_CALL(BPF_FUNC_loop),
            INSN_MOV64_IMM(BPF_REG_0, 1),
            INSN_EXIT(),

            INSN_JMP_IMM(BPF_JSGE, BPF_REG_1, 0, 2),
            INSN_MOV64_IMM(BPF_REG_0, 0),
            INSN_EXIT(),
            INSN_JMP_IMM(BPF_JSGT, BPF_REG_1, 15, 4),
            INSN_MOV64_REG(BPF_REG_2, BPF_REG_10),
            INSN_ALU64_IMM(BPF_ADD, BPF_REG_2, -16),
            INSN_ALU64_REG(BPF_ADD, BPF_REG_2, BPF_REG_1),
            INSN_ST_MEM(BPF_B, BPF_REG_2, 0, 1),
            INSN_MOV64_IMM(BPF_REG_0, 0),
            INSN_EXIT(),
          };
          struct bpf_func_info func_info[] = {
            { .insn_off = 0, .type_id = SYSCTL_LOOP_MAIN_TYPE },
            { .insn_off = SYSCTL_LOOP_CALLBACK_INSN,
              .type_id = SYSCTL_LOOP_CALLBACK_TYPE },
          };
          union bpf_attr attr;
          int btf_fd, fd, saved_errno;

          memset(log_buf, 0, log_size);
          btf_fd = load_sysctl_loop_btf();
          if (btf_fd < 0)
            return btf_fd;

          memset(&attr, 0, sizeof(attr));
          attr.prog_type = BPF_PROG_TYPE_CGROUP_SYSCTL;
          attr.expected_attach_type = BPF_CGROUP_SYSCTL;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.prog_btf_fd = btf_fd;
          attr.func_info_rec_size = sizeof(func_info[0]);
          attr.func_info_cnt = sizeof(func_info) / sizeof(func_info[0]);
          attr.func_info = (uint64_t)(uintptr_t)func_info;
          attr.log_level = 1;
          attr.log_size = log_size;
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "sd_sysctl_nz");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          saved_errno = errno;
          close(btf_fd);
          errno = saved_errno;
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int cgroup_sysctl_like_smoke(void)
        {
          const char *sysctl_path = "/proc/sys/net/ipv4/conf/lo/forwarding";
          char log_buf[65536];
          char *cgroup_path = NULL;
          uint32_t seen = 0;
          int nonzero_var_write_fd;
          int seen_map_fd = -1, cgroup_map_fd = -1, ringbuf_fd = -1;
          int cgroup_fd = -1, prog_fd = -1, link_fd = -1, invalid_link_fd;
          int nonzero_var_write_errno = 0;
          int cgroup_update_errno = 0, invalid_link_errno = 0;
          int read_errno = 0, write_errno = 0, seen_lookup_errno = 0;
          int ret = 1;

          seen_map_fd = create_map(BPF_MAP_TYPE_ARRAY, "sd_sys_seen");
          printf("cgroup_sysctl_seen_map_create_errno=%d\n",
                 seen_map_fd >= 0 ? 0 : errno);
          if (seen_map_fd < 0)
            goto out;

          cgroup_map_fd = create_map(BPF_MAP_TYPE_CGROUP_ARRAY, "sd_sys_cg");
          printf("cgroup_sysctl_cgroup_map_create_errno=%d\n",
                 cgroup_map_fd >= 0 ? 0 : errno);
          if (cgroup_map_fd < 0)
            goto out;

          ringbuf_fd = create_ringbuf_map("sd_sys_ring");
          printf("cgroup_sysctl_ringbuf_map_create_errno=%d\n",
                 ringbuf_fd >= 0 ? 0 : errno);
          if (ringbuf_fd < 0)
            goto out;

          nonzero_var_write_fd =
            load_cgroup_sysctl_var_stack_nonzero_write_prog(log_buf,
                                                            sizeof(log_buf));
          if (nonzero_var_write_fd >= 0) {
            close(nonzero_var_write_fd);
            nonzero_var_write_errno = 0;
          } else {
            nonzero_var_write_errno = -nonzero_var_write_fd;
          }
          printf("cgroup_sysctl_var_stack_nonzero_write_prog_load_errno=%d\n",
                 nonzero_var_write_errno);
          if (nonzero_var_write_errno != EACCES &&
              nonzero_var_write_errno != EPERM) {
            printf("cgroup_sysctl_var_stack_nonzero_write_prog_load_log_begin\n%s\ncgroup_sysctl_var_stack_nonzero_write_prog_load_log_end\n",
                   log_buf);
            goto out;
          }

          cgroup_path = current_cgroup_path();
          cgroup_fd = open(cgroup_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          if (cgroup_fd < 0)
            die_errno(cgroup_path);

          cgroup_update_errno =
            cgroup_array_update_fd_errno(cgroup_map_fd, cgroup_fd);
          printf("cgroup_sysctl_cgroup_map_update_errno=%d\n",
                 cgroup_update_errno);
          if (cgroup_update_errno != 0)
            goto out;

          prog_fd = load_cgroup_sysctl_like_prog(seen_map_fd, cgroup_map_fd,
                                                 ringbuf_fd, log_buf,
                                                 sizeof(log_buf));
          if (prog_fd < 0) {
            printf("cgroup_sysctl_prog_load_errno=%d\n", -prog_fd);
            printf("cgroup_sysctl_prog_load_log_begin\n%s\ncgroup_sysctl_prog_load_log_end\n",
                   log_buf);
            goto out;
          }
          printf("cgroup_sysctl_prog_load_errno=0\n");

          invalid_link_fd = create_cgroup_link_type(-1, prog_fd,
                                                    BPF_CGROUP_SYSCTL);
          if (invalid_link_fd >= 0) {
            close(invalid_link_fd);
            invalid_link_errno = 0;
          } else {
            invalid_link_errno = errno;
          }
          printf("cgroup_sysctl_invalid_link_errno=%d\n", invalid_link_errno);

          link_fd = create_cgroup_link_type(cgroup_fd, prog_fd,
                                            BPF_CGROUP_SYSCTL);
          if (link_fd < 0) {
            printf("cgroup_sysctl_link_errno=%d\n", errno);
            goto out;
          }
          printf("cgroup_sysctl_link_errno=0\n");

          read_errno = read_sysctl_errno(sysctl_path);
          write_errno = write_sysctl_same_value_errno(sysctl_path);
          seen_lookup_errno = lookup_array_u32_errno(seen_map_fd, &seen);

          printf("cgroup_sysctl_cgroup_path=%s\n", cgroup_path);
          printf("cgroup_sysctl_trigger_path=%s\n", sysctl_path);
          printf("cgroup_sysctl_read_errno=%d\n", read_errno);
          printf("cgroup_sysctl_write_errno=%d\n", write_errno);
          printf("cgroup_sysctl_seen_lookup_errno=%d\n", seen_lookup_errno);
          printf("cgroup_sysctl_trigger_seen=%u\n", seen);

          ret = cgroup_update_errno == 0 &&
            invalid_link_errno == EBADF &&
            read_errno == 0 &&
            write_errno == 0 &&
            seen_lookup_errno == 0 &&
            seen == 1 ? 0 : 1;

        out:
          if (link_fd >= 0)
            close(link_fd);
          if (prog_fd >= 0)
            close(prog_fd);
          if (cgroup_fd >= 0)
            close(cgroup_fd);
          if (ringbuf_fd >= 0)
            close(ringbuf_fd);
          if (cgroup_map_fd >= 0)
            close(cgroup_map_fd);
          if (seen_map_fd >= 0)
            close(seen_map_fd);
          free(cgroup_path);

          return ret;
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

        static int recv_link_probe(const char *socket_path, const char *prefix)
        {
          int link_fd, prog_fd, staterr;
          int link_fdinfo_seen, link_info_err, link_update_err;
          int link_detach_err, link_iter_create_err, link_pin_err;
          int link_task_fd_query_err;

          link_fd = recv_fd_over_socket(socket_path);
          staterr = fstat_errno(link_fd);
          link_fdinfo_seen = link_fdinfo_visible(link_fd);
          prog_fd = load_allow_egress_prog();
          link_info_err = link_info_errno(link_fd);
          link_update_err = link_update_errno(link_fd, prog_fd);
          link_detach_err = link_detach_errno(link_fd);
          link_iter_create_err = link_iter_create_errno(link_fd);
          link_pin_err = link_pin_errno(link_fd);
          link_task_fd_query_err = task_fd_query_errno(link_fd);

          printf("%s_fstat_errno=%d\n", prefix, staterr);
          printf("%s_fdinfo_visible=%d\n", prefix, link_fdinfo_seen);
          printf("%s_info_errno=%d\n", prefix, link_info_err);
          printf("%s_update_errno=%d\n", prefix, link_update_err);
          printf("%s_detach_errno=%d\n", prefix, link_detach_err);
          printf("%s_iter_create_errno=%d\n", prefix, link_iter_create_err);
          printf("%s_pin_errno=%d\n", prefix, link_pin_err);
          printf("%s_task_fd_query_errno=%d\n", prefix, link_task_fd_query_err);

          close(prog_fd);
          close(link_fd);

          return staterr == 0 &&
            link_fdinfo_seen == 0 &&
            expected_denial_errno(link_info_err) &&
            expected_denial_errno(link_update_err) &&
            expected_denial_errno(link_detach_err) &&
            expected_denial_errno(link_iter_create_err) &&
            expected_denial_errno(link_pin_err) &&
            expected_auth_denial_errno(link_task_fd_query_err) ? 0 : 1;
        }

        int main(int argc, char **argv)
        {
          int cgroup_fd, prog_fd, map_fd, link_fd, staterr, qerr, aerr, lerr, derr, uerr;
          int link_fdinfo_seen, link_info_err, link_update_err, link_detach_err, link_iter_create_err, link_pin_err, link_task_fd_query_err;
          int map_fdinfo_seen, map_info_err, map_lookup_err, map_update_err, map_mmap_err, map_mmap_offset_err, map_lookup_batch_err, map_update_batch_err, map_delete_batch_err, map_freeze_err, map_pin_err, map_get_fd_by_id_err;
          int prog_fdinfo_seen, prog_info_err, prog_test_run_err, prog_link_create_err, prog_bind_map_err, prog_pin_err;
          int array_create_err, cgroup_array_create_err, prog_bind_map_create_err;
          uint32_t map_id;

          if (argc < 2) {
            fprintf(stderr, "usage: %s cap-status | bind-state-test HOST PORT allow|deny | direct-bind4-link-smoke HOST PORT | direct-device-link-smoke | device-policy-service-smoke | socket-bind-like-smoke HOST PORT | socket-bind-libbpf-probe-smoke | cgroup-sysctl-like-smoke | query-current-egress-effective | hold-host-cgroup-egress-link CGROUP_PATH READY_PATH STOP_PATH | recv-container-cgroup-array-host-update HOST_CGROUP_PATH SOCKET_PATH | recv-container-prog-host-attach HOST_CGROUP_PATH SOCKET_PATH | recv SOCKET_PATH | recv-link SOCKET_PATH | recv-raw-tp-link SOCKET_PATH | recv-map SOCKET_PATH | recv-map-arena SOCKET_PATH | recv-bpffs-map-file SOCKET_PATH | recv-prog SOCKET_PATH | send-container-cgroup-array SOCKET_PATH | send-container-prog SOCKET_PATH | send HOST_CGROUP_PATH SOCKET_PATH | send-link HOST_CGROUP_PATH SOCKET_PATH | send-raw-tp-link SOCKET_PATH | send-map SOCKET_PATH | send-map-arena SOCKET_PATH | send-bpffs-map-file SOCKET_PATH | send-prog SOCKET_PATH\n", argv[0]);
            return 2;
          }

          if (strcmp(argv[1], "cap-status") == 0) {
            if (argc != 2) {
              fprintf(stderr, "usage: %s cap-status\n", argv[0]);
              return 2;
            }

            return cap_status();
          }

          if (strcmp(argv[1], "bind-state-test") == 0) {
            if (argc != 5) {
              fprintf(stderr, "usage: %s bind-state-test HOST PORT allow|deny\n", argv[0]);
              return 2;
            }

            return bind_state_test(argv[2], atoi(argv[3]), argv[4]);
          }

          if (strcmp(argv[1], "direct-bind4-link-smoke") == 0) {
            if (argc != 4) {
              fprintf(stderr, "usage: %s direct-bind4-link-smoke HOST PORT\n", argv[0]);
              return 2;
            }

            return bind4_direct_link_smoke(argv[2], atoi(argv[3]));
          }

          if (strcmp(argv[1], "direct-device-link-smoke") == 0) {
            if (argc != 2) {
              fprintf(stderr, "usage: %s direct-device-link-smoke\n", argv[0]);
              return 2;
            }

            return device_direct_link_smoke();
          }

          if (strcmp(argv[1], "device-policy-service-smoke") == 0) {
            if (argc != 2) {
              fprintf(stderr, "usage: %s device-policy-service-smoke\n", argv[0]);
              return 2;
            }

            return device_policy_service_smoke();
          }

          if (strcmp(argv[1], "socket-bind-like-smoke") == 0) {
            if (argc != 4) {
              fprintf(stderr, "usage: %s socket-bind-like-smoke HOST PORT\n", argv[0]);
              return 2;
            }

            return socket_bind_like_smoke(argv[2], atoi(argv[3]));
          }

          if (strcmp(argv[1], "socket-bind-libbpf-probe-smoke") == 0) {
            if (argc != 2) {
              fprintf(stderr, "usage: %s socket-bind-libbpf-probe-smoke\n", argv[0]);
              return 2;
            }

            return socket_bind_libbpf_probe_smoke();
          }

          if (strcmp(argv[1], "cgroup-sysctl-like-smoke") == 0) {
            if (argc != 2) {
              fprintf(stderr, "usage: %s cgroup-sysctl-like-smoke\n", argv[0]);
              return 2;
            }

            return cgroup_sysctl_like_smoke();
          }

          if (strcmp(argv[1], "query-current-egress-effective") == 0) {
            if (argc != 2) {
              fprintf(stderr, "usage: %s query-current-egress-effective\n", argv[0]);
              return 2;
            }

            return query_current_egress_effective();
          }

          if (strcmp(argv[1], "hold-host-cgroup-egress-link") == 0) {
            if (argc != 5) {
              fprintf(stderr, "usage: %s hold-host-cgroup-egress-link CGROUP_PATH READY_PATH STOP_PATH\n", argv[0]);
              return 2;
            }

            return hold_host_cgroup_egress_link(argv[2], argv[3], argv[4]);
          }

          if (strcmp(argv[1], "send-container-prog") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s send-container-prog SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return send_container_prog(argv[2]);
          }

          if (strcmp(argv[1], "recv-container-prog-host-attach") == 0) {
            if (argc != 4) {
              fprintf(stderr, "usage: %s recv-container-prog-host-attach HOST_CGROUP_PATH SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return recv_container_prog_host_attach(argv[2], argv[3]);
          }

          if (strcmp(argv[1], "send-container-cgroup-array") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s send-container-cgroup-array SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return send_container_cgroup_array(argv[2]);
          }

          if (strcmp(argv[1], "recv-container-cgroup-array-host-update") == 0) {
            if (argc != 4) {
              fprintf(stderr, "usage: %s recv-container-cgroup-array-host-update HOST_CGROUP_PATH SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return recv_container_cgroup_array_host_update(argv[2], argv[3]);
          }

          if (strcmp(argv[1], "send-map") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s send-map SOCKET_PATH\n", argv[0]);
              return 2;
            }

            map_fd = create_map_flags(BPF_MAP_TYPE_ARRAY, "sd_host_map",
                                      BPF_F_MMAPABLE);
            if (map_fd < 0)
              die_errno("BPF_MAP_CREATE");

            map_info_err = map_id_errno(map_fd, &map_id);
            if (map_info_err != 0) {
              errno = map_info_err;
              die_errno("BPF_OBJ_GET_INFO_BY_FD");
            }

            send_fd_u32_over_socket(argv[2], map_fd, map_id);
            close(map_fd);
            return 0;
          }

          if (strcmp(argv[1], "send-map-arena") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s send-map-arena SOCKET_PATH\n", argv[0]);
              return 2;
            }

            map_fd = create_arena_map("sd_host_arena");
            if (map_fd < 0)
              die_errno("BPF_MAP_CREATE arena");

            send_fd_over_socket(argv[2], map_fd);
            close(map_fd);
            return 0;
          }

          if (strcmp(argv[1], "send-bpffs-map-file") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s send-bpffs-map-file SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return send_pinned_map_file(argv[2]);
          }

          if (strcmp(argv[1], "send-prog") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s send-prog SOCKET_PATH\n", argv[0]);
              return 2;
            }

            prog_fd = load_allow_egress_prog();
            send_fd_over_socket(argv[2], prog_fd);
            close(prog_fd);
            return 0;
          }

          if (strcmp(argv[1], "send-raw-tp-link") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s send-raw-tp-link SOCKET_PATH\n", argv[0]);
              return 2;
            }

            link_fd = load_host_raw_tracepoint_link();
            send_fd_over_socket(argv[2], link_fd);
            close(link_fd);
            return 0;
          }

          if (strcmp(argv[1], "send") == 0 || strcmp(argv[1], "send-link") == 0) {
            if (argc != 4) {
              fprintf(stderr, "usage: %s %s HOST_CGROUP_PATH SOCKET_PATH\n", argv[0], argv[1]);
              return 2;
            }

            cgroup_fd = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (cgroup_fd < 0)
              die_errno(argv[2]);

            if (strcmp(argv[1], "send-link") == 0) {
              link_fd = load_host_cgroup_link(cgroup_fd);
              send_fd_over_socket(argv[3], link_fd);
              close(link_fd);
            } else {
              send_fd_over_socket(argv[3], cgroup_fd);
            }
            close(cgroup_fd);
            return 0;
          }

          if (strcmp(argv[1], "recv-link") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s recv-link SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return recv_link_probe(argv[2], "leaked_link");
          }

          if (strcmp(argv[1], "recv-raw-tp-link") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s recv-raw-tp-link SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return recv_link_probe(argv[2], "leaked_raw_tp_link");
          }

          if (strcmp(argv[1], "recv-map") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s recv-map SOCKET_PATH\n", argv[0]);
              return 2;
            }

            map_fd = recv_fd_u32_over_socket(argv[2], &map_id);
            staterr = fstat_errno(map_fd);
            map_fdinfo_seen = map_fdinfo_visible(map_fd);
            map_info_err = map_info_errno(map_fd);
            map_get_fd_by_id_err = map_get_fd_by_id_errno(map_id);
            map_lookup_err = map_lookup_errno(map_fd);
            map_update_err = map_update_errno(map_fd);
            map_mmap_err = map_mmap_errno(map_fd);
            map_lookup_batch_err = map_lookup_batch_errno(map_fd);
            map_update_batch_err = map_update_batch_errno(map_fd);
            map_delete_batch_err = map_delete_batch_errno(map_fd);
            map_freeze_err = map_freeze_errno(map_fd);
            map_pin_err = map_pin_errno(map_fd);

            printf("leaked_map_fstat_errno=%d\n", staterr);
            printf("leaked_map_fdinfo_visible=%d\n", map_fdinfo_seen);
            printf("leaked_map_info_errno=%d\n", map_info_err);
            printf("leaked_map_get_fd_by_id_errno=%d\n", map_get_fd_by_id_err);
            printf("leaked_map_lookup_errno=%d\n", map_lookup_err);
            printf("leaked_map_update_errno=%d\n", map_update_err);
            printf("leaked_map_mmap_errno=%d\n", map_mmap_err);
            printf("leaked_map_lookup_batch_errno=%d\n", map_lookup_batch_err);
            printf("leaked_map_update_batch_errno=%d\n", map_update_batch_err);
            printf("leaked_map_delete_batch_errno=%d\n", map_delete_batch_err);
            printf("leaked_map_freeze_errno=%d\n", map_freeze_err);
            printf("leaked_map_pin_errno=%d\n", map_pin_err);

            close(map_fd);

            return staterr == 0 &&
              map_fdinfo_seen == 0 &&
              expected_denial_errno(map_info_err) &&
              expected_foreign_by_id_denial_errno(map_get_fd_by_id_err) &&
              expected_denial_errno(map_lookup_err) &&
              expected_denial_errno(map_update_err) &&
              expected_denial_errno(map_mmap_err) &&
              expected_denial_errno(map_lookup_batch_err) &&
              expected_denial_errno(map_update_batch_err) &&
              expected_denial_errno(map_delete_batch_err) &&
              expected_denial_errno(map_freeze_err) &&
              expected_denial_errno(map_pin_err) ? 0 : 1;
          }

          if (strcmp(argv[1], "recv-bpffs-map-file") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s recv-bpffs-map-file SOCKET_PATH\n", argv[0]);
              return 2;
            }

            return recv_pinned_map_file(argv[2]);
          }

          if (strcmp(argv[1], "recv-map-arena") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s recv-map-arena SOCKET_PATH\n", argv[0]);
              return 2;
            }

            map_fd = recv_fd_over_socket(argv[2]);
            staterr = fstat_errno(map_fd);
            map_fdinfo_seen = map_fdinfo_visible(map_fd);
            map_mmap_offset_err = map_mmap_offset_errno(map_fd);

            printf("leaked_arena_map_fstat_errno=%d\n", staterr);
            printf("leaked_arena_map_fdinfo_visible=%d\n", map_fdinfo_seen);
            printf("leaked_arena_map_mmap_offset_errno=%d\n", map_mmap_offset_err);

            close(map_fd);

            return staterr == 0 &&
              map_fdinfo_seen == 0 &&
              map_mmap_offset_err == EACCES ? 0 : 1;
          }

          if (strcmp(argv[1], "recv-prog") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s recv-prog SOCKET_PATH\n", argv[0]);
              return 2;
            }

            prog_fd = recv_fd_over_socket(argv[2]);
            cgroup_fd = open("/sys/fs/cgroup", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (cgroup_fd < 0)
              die_errno("/sys/fs/cgroup");

            staterr = fstat_errno(prog_fd);
            prog_fdinfo_seen = prog_fdinfo_visible(prog_fd);
            prog_info_err = prog_info_errno(prog_fd);
            prog_test_run_err = prog_test_run_errno(prog_fd);
            prog_link_create_err = link_create_errno(cgroup_fd, prog_fd);
            prog_bind_map_err = prog_bind_map_errno(prog_fd, &prog_bind_map_create_err);
            prog_pin_err = prog_pin_errno(prog_fd);

            printf("leaked_prog_fstat_errno=%d\n", staterr);
            printf("leaked_prog_fdinfo_visible=%d\n", prog_fdinfo_seen);
            printf("prog_bind_map_create_errno=%d\n", prog_bind_map_create_err);
            printf("leaked_prog_info_errno=%d\n", prog_info_err);
            printf("leaked_prog_test_run_errno=%d\n", prog_test_run_err);
            printf("leaked_prog_link_create_errno=%d\n", prog_link_create_err);
            printf("leaked_prog_bind_map_errno=%d\n", prog_bind_map_err);
            printf("leaked_prog_pin_errno=%d\n", prog_pin_err);

            close(cgroup_fd);
            close(prog_fd);

            return staterr == 0 &&
              prog_fdinfo_seen == 0 &&
              prog_bind_map_create_err == 0 &&
              expected_denial_errno(prog_info_err) &&
              expected_denial_errno(prog_test_run_err) &&
              expected_denial_errno(prog_link_create_err) &&
              expected_denial_errno(prog_bind_map_err) &&
              expected_denial_errno(prog_pin_err) ? 0 : 1;
          }

          if (strcmp(argv[1], "recv") == 0) {
            if (argc != 3) {
              fprintf(stderr, "usage: %s recv SOCKET_PATH\n", argv[0]);
              return 2;
            }

            cgroup_fd = recv_fd_over_socket(argv[2]);
          } else {
            fprintf(stderr, "unknown mode: %s\n", argv[1]);
            return 2;
          }

          staterr = fstat_errno(cgroup_fd);
          prog_fd = load_allow_egress_prog();
          array_create_err = map_create_errno(BPF_MAP_TYPE_ARRAY, "sd_array");
          qerr = query_errno(cgroup_fd);
          aerr = attach_errno(cgroup_fd, prog_fd);
          lerr = link_create_errno(cgroup_fd, prog_fd);
          derr = detach_errno(cgroup_fd, prog_fd);
          uerr = cgroup_array_update_errno(cgroup_fd, &cgroup_array_create_err);

          printf("leaked_cgroup_fstat_errno=%d\n", staterr);
          printf("array_map_create_errno=%d\n", array_create_err);
          printf("cgroup_array_create_errno=%d\n", cgroup_array_create_err);
          printf("leaked_cgroup_query_errno=%d\n", qerr);
          printf("leaked_cgroup_attach_errno=%d\n", aerr);
          printf("leaked_cgroup_link_create_errno=%d\n", lerr);
          printf("leaked_cgroup_detach_errno=%d\n", derr);
          printf("leaked_cgroup_array_update_errno=%d\n", uerr);

          close(prog_fd);
          close(cgroup_fd);

          return staterr == 0 &&
            array_create_err == 0 &&
            cgroup_array_create_err == 0 &&
            expected_denial_errno(qerr) &&
            expected_denial_errno(aerr) &&
            expected_denial_errno(lerr) &&
            expected_denial_errno(derr) &&
            expected_denial_errno(uerr) ? 0 : 1;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o systemd-ebpf-fd-leak-probe
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 systemd-ebpf-fd-leak-probe $out/bin/systemd-ebpf-fd-leak-probe
        runHook postInstall
      '';
    };

    systemdEbpfLsmIsolation = pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-lsm-isolation";
      version = "1";

      dontUnpack = true;

      nativeBuildInputs = [
        pkgs.bpftools
        pkgs.pkg-config
      ];
      buildInputs = [ pkgs.libbpf ];
      hardeningDisable = [ "zerocallusedregs" ];

      src = pkgs.writeText "systemd-ebpf-lsm-isolation.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <bpf/btf.h>
        #include <bpf/libbpf.h>
        #include <fcntl.h>
        #include <grp.h>
        #include <linux/bpf.h>
        #include <linux/btf.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/stat.h>
        #include <sys/syscall.h>
        #include <unistd.h>

        static int bpf_cmd(enum bpf_cmd cmd, union bpf_attr *attr)
        {
          return syscall(SYS_bpf, cmd, attr, sizeof(*attr));
        }

        static void die_errno(const char *what)
        {
          fprintf(stderr, "%s failed: errno=%d\n", what, errno);
          exit(1);
        }

        static void print_self_status_prefix(const char *prefix)
        {
          char line[256];
          FILE *f;

          f = fopen("/proc/self/status", "r");
          if (!f) {
            fprintf(stderr, "%s_status_open_errno=%d\n", prefix, errno);
            return;
          }

          while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "Uid:", 4) == 0 ||
                strncmp(line, "Gid:", 4) == 0 ||
                strncmp(line, "NStgid:", 7) == 0 ||
                strncmp(line, "CapInh:", 7) == 0 ||
                strncmp(line, "CapPrm:", 7) == 0 ||
                strncmp(line, "CapEff:", 7) == 0 ||
                strncmp(line, "CapBnd:", 7) == 0 ||
                strncmp(line, "CapAmb:", 7) == 0)
              fprintf(stderr, "%s_%s", prefix, line);
          }

          fclose(f);
        }

        static int find_bpf_lsm_btf_id(const char *name)
        {
          struct btf *btf;
          long err;
          int id;

          btf = btf__parse("/sys/kernel/btf/vmlinux", NULL);
          err = libbpf_get_error(btf);
          if (err) {
            fprintf(stderr, "btf__parse(/sys/kernel/btf/vmlinux) failed: %ld\n", err);
            return -1;
          }

          id = btf__find_by_name_kind(btf, name, BTF_KIND_FUNC);
          btf__free(btf);
          if (id < 0)
            fprintf(stderr, "BTF function %s not found: %d\n", name, id);

          return id;
        }

        static int find_btf_struct_member_offset(const char *struct_name,
                                                 const char *member_name)
        {
          const struct btf_member *members;
          const struct btf_type *type;
          struct btf *btf;
          long err;
          int id;
          int i;

          btf = btf__parse("/sys/kernel/btf/vmlinux", NULL);
          err = libbpf_get_error(btf);
          if (err) {
            fprintf(stderr, "btf__parse(/sys/kernel/btf/vmlinux) failed: %ld\n", err);
            return -1;
          }

          id = btf__find_by_name_kind(btf, struct_name, BTF_KIND_STRUCT);
          if (id < 0) {
            fprintf(stderr, "BTF struct %s not found: %d\n", struct_name, id);
            btf__free(btf);
            return -1;
          }

          type = btf__type_by_id(btf, id);
          if (!type || !btf_is_struct(type)) {
            fprintf(stderr, "BTF id for %s is not a struct\n", struct_name);
            btf__free(btf);
            return -1;
          }

          members = btf_members(type);
          for (i = 0; i < btf_vlen(type); i++) {
            const char *name = btf__name_by_offset(btf, members[i].name_off);
            __u32 bit_offset;

            if (!name || strcmp(name, member_name) != 0)
              continue;

            bit_offset = btf_member_bit_offset(type, i);
            if (bit_offset % 8 != 0) {
              fprintf(stderr, "BTF member %s.%s has non-byte offset %u\n",
                      struct_name, member_name, bit_offset);
              btf__free(btf);
              return -1;
            }

            btf__free(btf);
            return (int)(bit_offset / 8);
          }

          fprintf(stderr, "BTF member %s.%s not found\n", struct_name, member_name);
          btf__free(btf);
          return -1;
        }

        static int expected_denial_errno(int err)
        {
          return err == EPERM || err == EACCES || err == EINVAL || err == EOPNOTSUPP;
        }

        static int load_lsm_path_mkdir_deny_prog(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = -EPERM,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          char log_buf[65536];
          union bpf_attr attr;
          int attach_btf_id;
          int fd;

          attach_btf_id = find_bpf_lsm_btf_id("bpf_lsm_path_mkdir");
          if (attach_btf_id < 0)
            return -1;
          printf("lsm_path_mkdir_btf_id=%d\n", attach_btf_id);
          fflush(stdout);

          memset(&attr, 0, sizeof(attr));
          memset(log_buf, 0, sizeof(log_buf));
          attr.prog_type = BPF_PROG_TYPE_LSM;
          attr.expected_attach_type = BPF_LSM_MAC;
          attr.attach_btf_id = (uint32_t)attach_btf_id;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          attr.log_size = sizeof(log_buf);
          attr.log_level = 1;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "lsm_mkdir_deny");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0) {
            fprintf(stderr, "BPF_PROG_LOAD lsm/path_mkdir failed: errno=%d\n%s\n",
                    errno, log_buf);
            print_self_status_prefix("lsm_path_mkdir");
            return -1;
          }

          return fd;
        }

        static int load_lsm_file_open_deny_prog(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = -EPERM,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          char log_buf[65536];
          union bpf_attr attr;
          int attach_btf_id;
          int fd;

          attach_btf_id = find_bpf_lsm_btf_id("bpf_lsm_file_open");
          if (attach_btf_id < 0)
            return -1;
          printf("lsm_file_open_btf_id=%d\n", attach_btf_id);
          fflush(stdout);

          memset(&attr, 0, sizeof(attr));
          memset(log_buf, 0, sizeof(log_buf));
          attr.prog_type = BPF_PROG_TYPE_LSM;
          attr.expected_attach_type = BPF_LSM_MAC;
          attr.attach_btf_id = (uint32_t)attach_btf_id;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          attr.log_size = sizeof(log_buf);
          attr.log_level = 1;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "lsm_open_deny");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (fd < 0) {
            fprintf(stderr, "BPF_PROG_LOAD lsm/file_open failed: errno=%d\n%s\n",
                    errno, log_buf);
            print_self_status_prefix("lsm_file_open");
            return -1;
          }

          return fd;
        }

        static int load_lsm_task_fix_setgroups_deny_prog(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = -EPERM,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          char log_buf[65536];
          union bpf_attr attr;
          int attach_btf_id;
          int fd;
          int err;

          attach_btf_id = find_bpf_lsm_btf_id("bpf_lsm_task_fix_setgroups");
          if (attach_btf_id < 0)
            return -1;

          memset(&attr, 0, sizeof(attr));
          memset(log_buf, 0, sizeof(log_buf));
          attr.prog_type = BPF_PROG_TYPE_LSM;
          attr.expected_attach_type = BPF_LSM_MAC;
          attr.attach_btf_id = (uint32_t)attach_btf_id;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          attr.log_size = sizeof(log_buf);
          attr.log_level = 1;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "lsm_setgrp_x");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          err = fd < 0 ? errno : 0;
          printf("lsm_task_fix_setgroups_prog_load_errno=%d\n", err);
          if (fd < 0) {
            fprintf(stderr, "BPF_PROG_LOAD lsm/task_fix_setgroups failed: errno=%d\n%s\n",
                    err, log_buf);
            return -1;
          }

          return fd;
        }

        static int attach_lsm_prog_named(int prog_fd, const char *name)
        {
          union bpf_attr attr;
          int link_fd;

          memset(&attr, 0, sizeof(attr));
          attr.link_create.prog_fd = prog_fd;
          attr.link_create.attach_type = BPF_LSM_MAC;

          link_fd = bpf_cmd(BPF_LINK_CREATE, &attr);
          if (link_fd < 0)
            fprintf(stderr, "BPF_LINK_CREATE lsm/%s failed: errno=%d\n", name, errno);

          return link_fd;
        }

        static int attach_lsm_prog(int prog_fd)
        {
          return attach_lsm_prog_named(prog_fd, "path_mkdir");
        }

        static int map_in_map_smoke(void)
        {
          union bpf_attr attr;
          uint64_t key = 0;
          int inner_fd;
          int outer_fd;
          int err = 0;

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_HASH;
          attr.key_size = sizeof(uint32_t);
          attr.value_size = sizeof(uint32_t);
          attr.max_entries = 128;
          inner_fd = bpf_cmd(BPF_MAP_CREATE, &attr);
          if (inner_fd < 0) {
            err = errno;
            printf("lsm_file_open_inner_map_create_errno=%d\n", err);
            return 1;
          }
          printf("lsm_file_open_inner_map_create_errno=0\n");

          memset(&attr, 0, sizeof(attr));
          attr.map_type = BPF_MAP_TYPE_HASH_OF_MAPS;
          attr.key_size = sizeof(key);
          attr.value_size = sizeof(uint32_t);
          attr.max_entries = 1;
          attr.inner_map_fd = inner_fd;
          outer_fd = bpf_cmd(BPF_MAP_CREATE, &attr);
          if (outer_fd < 0) {
            err = errno;
            printf("lsm_file_open_outer_map_create_errno=%d\n", err);
            close(inner_fd);
            return 1;
          }
          printf("lsm_file_open_outer_map_create_errno=0\n");

          memset(&attr, 0, sizeof(attr));
          attr.map_fd = outer_fd;
          attr.key = (uint64_t)(uintptr_t)&key;
          attr.value = (uint64_t)(uintptr_t)&inner_fd;
          attr.flags = BPF_ANY;
          if (bpf_cmd(BPF_MAP_UPDATE_ELEM, &attr) < 0) {
            err = errno;
            printf("lsm_file_open_outer_map_update_errno=%d\n", err);
            close(outer_fd);
            close(inner_fd);
            return 1;
          }
          printf("lsm_file_open_outer_map_update_errno=0\n");

          close(outer_fd);
          close(inner_fd);
          return 0;
        }

        static int file_open_smoke(void)
        {
          struct bpf_insn insns[] = {
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          char log_buf[65536];
          union bpf_attr attr;
          int attach_btf_id;
          int prog_fd;
          int link_fd;
          int rc = 0;

          if (map_in_map_smoke() != 0)
            rc = 1;

          attach_btf_id = find_bpf_lsm_btf_id("bpf_lsm_file_open");
          if (attach_btf_id < 0)
            return 1;
          printf("lsm_file_open_btf_id=%d\n", attach_btf_id);

          memset(&attr, 0, sizeof(attr));
          memset(log_buf, 0, sizeof(log_buf));
          attr.prog_type = BPF_PROG_TYPE_LSM;
          attr.expected_attach_type = BPF_LSM_MAC;
          attr.attach_btf_id = (uint32_t)attach_btf_id;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          attr.log_size = sizeof(log_buf);
          attr.log_level = 1;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "lsm_file_open");

          prog_fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          if (prog_fd < 0) {
            printf("lsm_file_open_prog_load_errno=%d\n", errno);
            if (log_buf[0])
              printf("lsm_file_open_prog_load_log=%s\n", log_buf);
            return 1;
          }
          printf("lsm_file_open_prog_load_errno=0\n");

          link_fd = attach_lsm_prog_named(prog_fd, "file_open");
          if (link_fd < 0) {
            printf("lsm_file_open_link_create_errno=%d\n", errno);
            close(prog_fd);
            return 1;
          }
          printf("lsm_file_open_link_create_errno=0\n");

          close(link_fd);
          close(prog_fd);
          return rc;
        }

        static int file_open_bad_probe_read_smoke(void)
        {
          int file_inode_off;
          int inode_sb_off;
          int super_magic_off;
          struct bpf_insn insns[] = {
            {
              .code = BPF_LDX | BPF_DW | BPF_MEM,
              .dst_reg = BPF_REG_3,
              .src_reg = BPF_REG_1,
              .off = 0,
            },
            {
              .code = BPF_ALU64 | BPF_ADD | BPF_K,
              .dst_reg = BPF_REG_3,
              .imm = 0,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_X,
              .dst_reg = BPF_REG_6,
              .src_reg = BPF_REG_10,
            },
            {
              .code = BPF_ALU64 | BPF_ADD | BPF_K,
              .dst_reg = BPF_REG_6,
              .imm = -8,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_X,
              .dst_reg = BPF_REG_1,
              .src_reg = BPF_REG_6,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_2,
              .imm = 8,
            },
            {
              .code = BPF_JMP | BPF_CALL,
              .imm = BPF_FUNC_probe_read,
            },
            {
              .code = BPF_LDX | BPF_DW | BPF_MEM,
              .dst_reg = BPF_REG_3,
              .src_reg = BPF_REG_10,
              .off = -8,
            },
            {
              .code = BPF_ALU64 | BPF_ADD | BPF_K,
              .dst_reg = BPF_REG_3,
              .imm = 0,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_X,
              .dst_reg = BPF_REG_1,
              .src_reg = BPF_REG_6,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_2,
              .imm = 8,
            },
            {
              .code = BPF_JMP | BPF_CALL,
              .imm = BPF_FUNC_probe_read,
            },
            {
              .code = BPF_LDX | BPF_DW | BPF_MEM,
              .dst_reg = BPF_REG_3,
              .src_reg = BPF_REG_10,
              .off = -8,
            },
            {
              .code = BPF_ALU64 | BPF_ADD | BPF_K,
              .dst_reg = BPF_REG_3,
              .imm = 0,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_X,
              .dst_reg = BPF_REG_1,
              .src_reg = BPF_REG_6,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_2,
              .imm = 8,
            },
            {
              .code = BPF_JMP | BPF_CALL,
              .imm = BPF_FUNC_probe_read,
            },
            {
              .code = BPF_ALU64 | BPF_MOV | BPF_K,
              .dst_reg = BPF_REG_0,
              .imm = 0,
            },
            {
              .code = BPF_JMP | BPF_EXIT,
            },
          };
          char log_buf[65536];
          union bpf_attr attr;
          int attach_btf_id;
          int fd;
          int err;

          file_inode_off = find_btf_struct_member_offset("file", "f_inode");
          inode_sb_off = find_btf_struct_member_offset("inode", "i_sb");
          super_magic_off = find_btf_struct_member_offset("super_block", "s_magic");
          if (file_inode_off < 0 || inode_sb_off < 0 || super_magic_off < 0)
            return 1;

          insns[1].imm = file_inode_off;
          insns[8].imm = inode_sb_off;
          insns[13].imm = super_magic_off + 1;
          printf("lsm_file_open_bad_probe_read_file_inode_off=%d\n", file_inode_off);
          printf("lsm_file_open_bad_probe_read_inode_sb_off=%d\n", inode_sb_off);
          printf("lsm_file_open_bad_probe_read_super_magic_bad_off=%d\n",
                 super_magic_off + 1);

          attach_btf_id = find_bpf_lsm_btf_id("bpf_lsm_file_open");
          if (attach_btf_id < 0)
            return 1;

          memset(&attr, 0, sizeof(attr));
          memset(log_buf, 0, sizeof(log_buf));
          attr.prog_type = BPF_PROG_TYPE_LSM;
          attr.expected_attach_type = BPF_LSM_MAC;
          attr.attach_btf_id = (uint32_t)attach_btf_id;
          attr.insn_cnt = sizeof(insns) / sizeof(insns[0]);
          attr.insns = (uint64_t)(uintptr_t)insns;
          attr.license = (uint64_t)(uintptr_t)"GPL";
          attr.log_buf = (uint64_t)(uintptr_t)log_buf;
          attr.log_size = sizeof(log_buf);
          attr.log_level = 1;
          snprintf(attr.prog_name, sizeof(attr.prog_name), "lsm_bad_read");

          fd = bpf_cmd(BPF_PROG_LOAD, &attr);
          err = fd < 0 ? errno : 0;
          printf("lsm_file_open_bad_probe_read_errno=%d\n", err);
          if (log_buf[0])
            printf("lsm_file_open_bad_probe_read_log=%s\n", log_buf);
          if (fd >= 0) {
            close(fd);
            fprintf(stderr, "unsupported file_open bpf_probe_read unexpectedly loaded\n");
            return 1;
          }

          return expected_denial_errno(err) ? 0 : 1;
        }

        static void write_ready(const char *path)
        {
          FILE *f;

          f = fopen(path, "we");
          if (!f)
            die_errno(path);
          fprintf(f, "ready\n");
          fclose(f);
        }

        static int hold_lsm_path_mkdir_deny(const char *ready_path, const char *stop_path)
        {
          int prog_fd, link_fd;

          prog_fd = load_lsm_path_mkdir_deny_prog();
          if (prog_fd < 0)
            return 1;

          link_fd = attach_lsm_prog(prog_fd);
          close(prog_fd);
          if (link_fd < 0)
            return 1;

          printf("lsm_path_mkdir_link_fd=%d\n", link_fd);
          fflush(stdout);
          write_ready(ready_path);

          while (access(stop_path, F_OK) != 0)
            usleep(100000);

          close(link_fd);
          printf("lsm_path_mkdir_link_closed=1\n");
          return 0;
        }

        static int hold_lsm_file_open_deny(const char *path, unsigned int hold_seconds)
        {
          int warm_fd, prog_fd, link_fd, check_fd, err;

          warm_fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
          if (warm_fd < 0)
            die_errno(path);
          close(warm_fd);

          prog_fd = load_lsm_file_open_deny_prog();
          if (prog_fd < 0)
            return 1;

          link_fd = attach_lsm_prog_named(prog_fd, "file_open");
          close(prog_fd);
          if (link_fd < 0)
            return 1;

          printf("lsm_file_open_link_fd=%d\n", link_fd);
          fflush(stdout);

          check_fd = open(path, O_RDONLY | O_CLOEXEC);
          err = check_fd < 0 ? errno : 0;
          if (check_fd >= 0)
            close(check_fd);

          printf("lsm_file_open_same_ct_errno=%d\n", err);
          fflush(stdout);

          if (err != EPERM && err != EACCES) {
            close(link_fd);
            fprintf(stderr, "same-CT file_open was not denied: errno=%d\n", err);
            return 1;
          }

          sleep(hold_seconds);

          close(link_fd);
          printf("lsm_file_open_link_closed=1\n");
          return 0;
        }

        static int hold_lsm_task_fix_setgroups_deny(const char *ready_path, const char *stop_path)
        {
          int prog_fd, link_fd;

          prog_fd = load_lsm_task_fix_setgroups_deny_prog();
          if (prog_fd < 0)
            return 1;

          link_fd = attach_lsm_prog_named(prog_fd, "task_fix_setgroups");
          close(prog_fd);
          if (link_fd < 0)
            return 1;

          printf("lsm_task_fix_setgroups_link_fd=%d\n", link_fd);
          fflush(stdout);
          write_ready(ready_path);

          while (access(stop_path, F_OK) != 0)
            usleep(100000);

          close(link_fd);
          printf("lsm_task_fix_setgroups_link_closed=1\n");
          return 0;
        }

        static int setgroups_check(const char *expect)
        {
          int err = 0;

          if (setgroups(0, NULL) < 0)
            err = errno;

          printf("lsm_setgroups_check_errno=%d\n", err);

          if (strcmp(expect, "allow") == 0) {
            if (err == 0) {
              printf("lsm_setgroups_allowed=1\n");
              return 0;
            }
            fprintf(stderr, "setgroups unexpectedly denied: errno=%d\n", err);
            return 1;
          }

          if (strcmp(expect, "deny") == 0) {
            if (err == EACCES || err == EPERM) {
              printf("lsm_setgroups_denied=1\n");
              return 0;
            }
            fprintf(stderr, "setgroups was not denied as expected: errno=%d\n", err);
            return 1;
          }

          fprintf(stderr, "unknown expectation: %s\n", expect);
          return 2;
        }

        static int mkdir_check(const char *path, const char *expect)
        {
          int err = 0;

          (void)rmdir(path);
          if (mkdir(path, 0700) < 0)
            err = errno;

          printf("lsm_mkdir_check_path=%s\n", path);
          printf("lsm_mkdir_check_errno=%d\n", err);

          if (strcmp(expect, "allow") == 0) {
            if (err == 0) {
              (void)rmdir(path);
              printf("lsm_mkdir_allowed=1\n");
              return 0;
            }
            fprintf(stderr, "mkdir unexpectedly denied: errno=%d\n", err);
            return 1;
          }

          if (strcmp(expect, "deny") == 0) {
            if (err == EACCES || err == EPERM) {
              printf("lsm_mkdir_denied=1\n");
              return 0;
            }
            if (err == 0)
              (void)rmdir(path);
            fprintf(stderr, "mkdir was not denied as expected: errno=%d\n", err);
            return 1;
          }

          fprintf(stderr, "unknown expectation: %s\n", expect);
          return 2;
        }

        static int open_check(const char *path, const char *expect)
        {
          int fd;
          int err = 0;

          fd = open(path, O_CREAT | O_RDONLY | O_CLOEXEC, 0600);
          if (fd < 0)
            err = errno;
          else
            close(fd);

          printf("lsm_open_check_path=%s\n", path);
          printf("lsm_open_check_errno=%d\n", err);

          if (strcmp(expect, "allow") == 0) {
            if (err == 0) {
              printf("lsm_open_allowed=1\n");
              return 0;
            }
            fprintf(stderr, "open unexpectedly denied: errno=%d\n", err);
            return 1;
          }

          if (strcmp(expect, "deny") == 0) {
            if (err == EACCES || err == EPERM) {
              printf("lsm_open_denied=1\n");
              return 0;
            }
            fprintf(stderr, "open was not denied as expected: errno=%d\n", err);
            return 1;
          }

          fprintf(stderr, "unknown expectation: %s\n", expect);
          return 2;
        }

        int main(int argc, char **argv)
        {
          libbpf_set_print(NULL);

          if (argc == 4 && strcmp(argv[1], "attach-deny-mkdir") == 0)
            return hold_lsm_path_mkdir_deny(argv[2], argv[3]);

          if (argc == 4 && strcmp(argv[1], "attach-deny-file-open") == 0)
            return hold_lsm_file_open_deny(argv[2], (unsigned int)strtoul(argv[3], NULL, 10));

          if (argc == 4 && strcmp(argv[1], "attach-deny-task-fix-setgroups") == 0)
            return hold_lsm_task_fix_setgroups_deny(argv[2], argv[3]);

          if (argc == 2 && strcmp(argv[1], "file-open-smoke") == 0)
            return file_open_smoke();

          if (argc == 2 && strcmp(argv[1], "file-open-bad-probe-read-smoke") == 0)
            return file_open_bad_probe_read_smoke();

          if (argc == 4 && strcmp(argv[1], "mkdir-check") == 0)
            return mkdir_check(argv[2], argv[3]);

          if (argc == 4 && strcmp(argv[1], "open-check") == 0)
            return open_check(argv[2], argv[3]);

          if (argc == 3 && strcmp(argv[1], "setgroups-check") == 0)
            return setgroups_check(argv[2]);

          fprintf(stderr, "usage: %s attach-deny-mkdir READY STOP\n", argv[0]);
          fprintf(stderr, "       %s attach-deny-file-open PATH HOLD_SECONDS\n", argv[0]);
          fprintf(stderr, "       %s attach-deny-task-fix-setgroups READY STOP\n", argv[0]);
          fprintf(stderr, "       %s file-open-smoke\n", argv[0]);
          fprintf(stderr, "       %s file-open-bad-probe-read-smoke\n", argv[0]);
          fprintf(stderr, "       %s mkdir-check PATH allow|deny\n", argv[0]);
          fprintf(stderr, "       %s setgroups-check allow|deny\n", argv[0]);
          fprintf(stderr, "       %s open-check PATH allow|deny\n", argv[0]);
          return 2;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 "$src" -o systemd-ebpf-lsm-isolation $(pkg-config --cflags --libs libbpf)
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 systemd-ebpf-lsm-isolation $out/bin/systemd-ebpf-lsm-isolation
        runHook postInstall
      '';
    };

    systemdEbpfRestrictFsProbe = pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-restrict-fs-probe";
      version = "1";

      dontUnpack = true;

      nativeBuildInputs = [
        pkgs.bpftools
        pkgs.clang
        pkgs.pkg-config
      ];
      buildInputs = [ pkgs.libbpf ];

      src = pkgs.writeText "systemd-ebpf-restrict-fs-probe.c" ''
        #define _GNU_SOURCE
        #include <bpf/bpf.h>
        #include <bpf/libbpf.h>
        #include <errno.h>
        #include <fcntl.h>
        #include <stdint.h>
        #include <stdarg.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <sys/statfs.h>
        #include <sys/types.h>

        #include "bpf/restrict_fs/restrict-fs.skel.h"

        #define CGROUP_HASH_SIZE_MAX 2048
#ifndef FILEID_KERNFS
#define FILEID_KERNFS 0xfe
#endif

        static const char *restrict_fs_libbpf_level_name(enum libbpf_print_level level)
        {
          switch (level) {
          case LIBBPF_WARN:
            return "warn";
          case LIBBPF_INFO:
            return "info";
          case LIBBPF_DEBUG:
            return "debug";
          default:
            return "unknown";
          }
        }

        static void restrict_fs_print_prefixed_lines(const char *prefix,
                                                     const char *text)
        {
          const char *line = text;

          while (line && *line) {
            const char *nl = strchr(line, '\n');
            if (nl)
              printf("%s=%.*s\n", prefix, (int)(nl - line), line);
            else
              printf("%s=%s\n", prefix, line);
            line = nl ? nl + 1 : NULL;
          }
        }

        static int restrict_fs_libbpf_print(enum libbpf_print_level level,
                                            const char *format, va_list args)
        {
          char prefix[64];
          char buf[2048];
          int len;

          len = vsnprintf(buf, sizeof(buf), format, args);
          if (len < 0)
            return 0;

          snprintf(prefix, sizeof(prefix), "restrict_fs_libbpf_%s",
                   restrict_fs_libbpf_level_name(level));
          restrict_fs_print_prefixed_lines(prefix, buf);
          if ((size_t)len >= sizeof(buf))
            printf("restrict_fs_libbpf_log_truncated=1\n");

          return 0;
        }

        typedef union {
          struct file_handle file_handle;
          uint8_t space[sizeof(struct file_handle) + sizeof(uint64_t)];
        } cgroup_file_handle;

        static int update_outer_map(int outer_fd, int inner_fd, uint64_t cgroup_id)
        {
          int err;

          err = bpf_map_update_elem(outer_fd, &cgroup_id, &inner_fd, BPF_ANY);
          if (err < 0)
            return -errno;

          return 0;
        }

        static int update_inner_map(int inner_fd, uint32_t key, uint32_t value)
        {
          int err;

          err = bpf_map_update_elem(inner_fd, &key, &value, BPF_ANY);
          if (err < 0)
            return -errno;

          return 0;
        }

        static int read_current_cgroup_path(char *path, size_t path_size)
        {
          char line[512];
          FILE *f;

          if (path_size == 0)
            return -EINVAL;

          f = fopen("/proc/self/cgroup", "re");
          if (!f)
            return -errno;

          while (fgets(line, sizeof(line), f)) {
            char *entry;
            char *newline;

            if (strncmp(line, "0::", 3) != 0)
              continue;

            entry = line + 3;
            newline = strchr(entry, '\n');
            if (newline)
              *newline = '\0';

            if (snprintf(path, path_size, "/sys/fs/cgroup%s%s",
                         entry[0] == '/' ? "" : "/", entry) >= (int)path_size) {
              fclose(f);
              return -ENAMETOOLONG;
            }

            fclose(f);
            return 0;
          }

          fclose(f);
          return -ENOENT;
        }

        static int current_cgroup_id(uint64_t *ret)
        {
          cgroup_file_handle fh = {
            .file_handle.handle_bytes = sizeof(uint64_t),
            .file_handle.handle_type = FILEID_KERNFS,
          };
          char path[512];
          int mount_id = -1;
          int err;

          err = read_current_cgroup_path(path, sizeof(path));
          if (err < 0)
            return err;

          if (name_to_handle_at(AT_FDCWD, path, &fh.file_handle, &mount_id, 0) < 0)
            return -errno;
          if (fh.file_handle.handle_bytes != sizeof(uint64_t) ||
              fh.file_handle.handle_type != FILEID_KERNFS) {
            return -EINVAL;
          }

          memcpy(ret, fh.file_handle.f_handle, sizeof(*ret));
          return 0;
        }

        int main(void)
        {
          LIBBPF_OPTS(bpf_map_create_opts, inner_opts);
          struct restrict_fs_bpf *obj = NULL;
          struct bpf_link *link = NULL;
          struct statfs procfs;
          uint64_t cgroup_id;
          uint32_t zero = 0;
          uint32_t deny_list = 0;
          uint32_t dummy = 1;
          int inner_fd = -1;
          int outer_fd = -1;
          int proc_fd = -1;
          int err;

          libbpf_set_print(restrict_fs_libbpf_print);

          obj = restrict_fs_bpf__open();
          if (!obj) {
            printf("restrict_fs_skel_open_errno=%d\n", errno);
            return 1;
          }
          printf("restrict_fs_skel_open_errno=0\n");

          err = bpf_map__set_max_entries(obj->maps.cgroup_hash, CGROUP_HASH_SIZE_MAX);
          printf("restrict_fs_outer_set_max_entries_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0)
            goto fail;

          inner_fd = bpf_map_create(BPF_MAP_TYPE_HASH, NULL, sizeof(uint32_t), sizeof(uint32_t), 128, &inner_opts);
          printf("restrict_fs_inner_map_create_errno=%d\n", inner_fd < 0 ? errno : 0);
          if (inner_fd < 0)
            goto fail;

          err = bpf_map__set_inner_map_fd(obj->maps.cgroup_hash, inner_fd);
          printf("restrict_fs_set_inner_map_fd_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0)
            goto fail;

          err = restrict_fs_bpf__load(obj);
          printf("restrict_fs_object_load_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0)
            goto fail;

          link = bpf_program__attach_lsm(obj->progs.restrict_filesystems);
          err = libbpf_get_error(link);
          printf("restrict_fs_attach_lsm_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0) {
            link = NULL;
            goto fail;
          }

          outer_fd = bpf_map__fd(obj->maps.cgroup_hash);
          printf("restrict_fs_outer_map_fd_errno=%d\n", outer_fd < 0 ? errno : 0);
          if (outer_fd < 0)
            goto fail;

          err = current_cgroup_id(&cgroup_id);
          printf("restrict_fs_current_cgroup_id_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0)
            goto fail;
          printf("restrict_fs_current_cgroup_id=%llu\n", (unsigned long long)cgroup_id);
          if (cgroup_id == 0)
            goto fail;

          err = update_outer_map(outer_fd, inner_fd, cgroup_id);
          printf("restrict_fs_outer_map_update_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0)
            goto fail;

          err = update_inner_map(inner_fd, zero, deny_list);
          printf("restrict_fs_inner_mode_update_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0)
            goto fail;

          if (statfs("/proc", &procfs) < 0) {
            printf("restrict_fs_proc_statfs_errno=%d\n", errno);
            goto fail;
          }
          printf("restrict_fs_proc_statfs_errno=0\n");

          err = update_inner_map(inner_fd, (uint32_t)procfs.f_type, dummy);
          printf("restrict_fs_inner_proc_update_errno=%d\n", err < 0 ? -err : 0);
          if (err < 0)
            goto fail;

          proc_fd = open("/proc/self/mounts", O_RDONLY | O_CLOEXEC);
          printf("restrict_fs_proc_open_errno=%d\n", proc_fd < 0 ? errno : 0);
          if (proc_fd >= 0) {
            close(proc_fd);
            goto fail;
          }
          if (errno != EPERM && errno != EACCES)
            goto fail;

          bpf_link__destroy(link);
          restrict_fs_bpf__destroy(obj);
          close(inner_fd);
          return 0;

        fail:
          if (link)
            bpf_link__destroy(link);
          restrict_fs_bpf__destroy(obj);
          if (inner_fd >= 0)
            close(inner_fd);
          return 1;
        }
      '';

      buildPhase = ''
        runHook preBuild

        restrict_fs_dir=${pkgs.systemd.src}/src/core/bpf/restrict-fs
        if [ ! -d "$restrict_fs_dir" ]; then
          restrict_fs_dir=${pkgs.systemd.src}/src/core/bpf/restrict_fs
        fi
        if [ ! -e "$restrict_fs_dir/restrict-fs.bpf.c" ]; then
          echo "cannot find stock systemd restrict-fs BPF source below ${pkgs.systemd.src}" >&2
          exit 1
        fi
        cp "$restrict_fs_dir/restrict-fs.bpf.c" .

        mkdir -p bpf/restrict_fs bpf-compat
        cat >bpf-compat/errno.h <<'EOF'
        #include <asm-generic/errno.h>
        EOF

        ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
          -std=gnu11 \
          -Wno-compare-distinct-pointer-types \
          -fno-stack-protector \
          -O2 \
          -target bpf \
          -g \
          -c \
          -D__x86_64__ \
          -D__TARGET_ARCH_x86 \
          -Ibpf-compat \
          -I. \
          -idirafter ${pkgs.linuxHeaders}/include \
          -idirafter ${pkgs.libbpf}/include \
          restrict-fs.bpf.c \
          -o restrict-fs.bpf.o

        bpftool gen skeleton restrict-fs.bpf.o > bpf/restrict_fs/restrict-fs.skel.h

        $CC -O2 "$src" \
          -I. \
          -o systemd-ebpf-restrict-fs-probe \
          $(pkg-config --cflags --libs libbpf)
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 systemd-ebpf-restrict-fs-probe $out/bin/systemd-ebpf-restrict-fs-probe
        runHook postInstall
      '';
    };

    systemdEbpfSocketBindLibbpf = pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-socket-bind-libbpf";
      version = "1";

      dontUnpack = true;

      nativeBuildInputs = [
        pkgs.clang
        pkgs.pkg-config
      ];
      buildInputs = [ pkgs.libbpf ];
      hardeningDisable = [ "zerocallusedregs" ];

      src = pkgs.writeText "systemd-ebpf-socket-bind-libbpf.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <bpf/bpf.h>
        #include <bpf/libbpf.h>
        #include <fcntl.h>
        #include <linux/bpf.h>
        #include <stdarg.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        #include "socket-bind-api.bpf.h"

        static char kernel_log_buf[1024 * 1024];
        static char sd_bind4_log_buf[256 * 1024];
        static char sd_bind6_log_buf[256 * 1024];

        static int positive_errno(int err)
        {
          return err < 0 ? -err : err;
        }

        static const char *libbpf_level_name(enum libbpf_print_level level)
        {
          switch (level) {
          case LIBBPF_WARN:
            return "warn";
          case LIBBPF_INFO:
            return "info";
          case LIBBPF_DEBUG:
            return "debug";
          default:
            return "unknown";
          }
        }

        static void print_prefixed_lines(const char *prefix, const char *text)
        {
          const char *line = text;

          while (line && *line) {
            const char *nl = strchr(line, '\n');
            if (nl)
              printf("%s=%.*s\n", prefix, (int)(nl - line), line);
            else
              printf("%s=%s\n", prefix, line);
            line = nl ? nl + 1 : NULL;
          }
        }

        static int socket_bind_libbpf_print(enum libbpf_print_level level,
                                            const char *format, va_list args)
        {
          char prefix[64];
          char buf[2048];
          int len;

          len = vsnprintf(buf, sizeof(buf), format, args);
          if (len < 0)
            return 0;

          snprintf(prefix, sizeof(prefix), "socket_bind_libbpf_libbpf_%s",
                   libbpf_level_name(level));
          print_prefixed_lines(prefix, buf);
          if ((size_t)len >= sizeof(buf))
            printf("socket_bind_libbpf_log_truncated=1\n");

          return 0;
        }

        static void print_kernel_log(const char *name, const char *buf)
        {
          char prefix[128];

          if (!buf || !*buf)
            return;

          snprintf(prefix, sizeof(prefix), "socket_bind_libbpf_%s_kernel_log", name);
          print_prefixed_lines(prefix, buf);
        }

        static void setup_program_log(struct bpf_object *obj)
        {
          struct bpf_program *prog;

          bpf_object__for_each_program(prog, obj) {
            const char *name = bpf_program__name(prog);
            char *buf = NULL;
            size_t size = 0;
            int err;

            if (name && strcmp(name, "sd_bind4") == 0) {
              buf = sd_bind4_log_buf;
              size = sizeof(sd_bind4_log_buf);
            } else if (name && strcmp(name, "sd_bind6") == 0) {
              buf = sd_bind6_log_buf;
              size = sizeof(sd_bind6_log_buf);
            }

            err = bpf_program__set_log_level(prog, 1);
            printf("socket_bind_libbpf_prog_%s_set_log_level_errno=%d\n",
                   name ?: "unknown", positive_errno(err));
            if (buf) {
              memset(buf, 0, size);
              err = bpf_program__set_log_buf(prog, buf, size);
              printf("socket_bind_libbpf_prog_%s_set_log_buf_errno=%d\n",
                     name, positive_errno(err));
            }
          }
        }

        static void print_program_logs(void)
        {
          print_kernel_log("sd_bind4", sd_bind4_log_buf);
          print_kernel_log("sd_bind6", sd_bind6_log_buf);
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

        static int set_map_entries(struct bpf_map *map, const char *name)
        {
          int err;

          if (!map) {
            printf("socket_bind_libbpf_%s_map_missing=1\n", name);
            return -ENOENT;
          }

          err = bpf_map__set_max_entries(map, 1);
          printf("socket_bind_libbpf_%s_map_resize_errno=%d\n",
                 name, positive_errno(err));
          return err;
        }

        static int update_empty_rule(struct bpf_map *map, const char *name)
        {
          struct socket_bind_rule value = {
            .address_family = SOCKET_BIND_RULE_AF_MATCH_NOTHING,
          };
          uint32_t key = 0;
          int fd;

          fd = bpf_map__fd(map);
          if (fd < 0) {
            printf("socket_bind_libbpf_%s_map_fd_errno=%d\n", name, -fd);
            return fd;
          }

          if (bpf_map_update_elem(fd, &key, &value, BPF_ANY) != 0) {
            printf("socket_bind_libbpf_%s_map_update_errno=%d\n", name, errno);
            return -errno;
          }

          printf("socket_bind_libbpf_%s_map_update_errno=0\n", name);
          return 0;
        }

        static int support_smoke(void)
        {
          struct bpf_object *obj = NULL;
          struct bpf_object_open_opts opts = { 0 };
          struct bpf_program *prog;
          struct bpf_link *link;
          struct bpf_map *allow_map;
          struct bpf_map *deny_map;
          int prog_type_probe;
          int current_fd;
          int invalid_link_errno;
          int current_link_errno;
          int err;

          libbpf_set_print(socket_bind_libbpf_print);

          prog_type_probe = libbpf_probe_bpf_prog_type(BPF_PROG_TYPE_CGROUP_SOCK_ADDR, NULL);
          printf("socket_bind_libbpf_prog_type_probe=%d\n", prog_type_probe);
          if (prog_type_probe <= 0)
            return 1;

          obj = bpf_object__open_file(SOCKET_BIND_BPF_OBJECT, NULL);
          err = libbpf_get_error(obj);
          if (err) {
            printf("socket_bind_libbpf_object_open_errno=%d\n", positive_errno(err));
            return 1;
          }
          printf("socket_bind_libbpf_object_open_errno=0\n");

          allow_map = bpf_object__find_map_by_name(obj, "sd_bind_allow");
          deny_map = bpf_object__find_map_by_name(obj, "sd_bind_deny");
          if (set_map_entries(allow_map, "allow") != 0 ||
              set_map_entries(deny_map, "deny") != 0) {
            bpf_object__close(obj);
            return 1;
          }

          memset(kernel_log_buf, 0, sizeof(kernel_log_buf));
          err = bpf_object__load(obj);
          printf("socket_bind_libbpf_object_load_errno=%d\n", positive_errno(err));
          if (err) {
            bpf_object__close(obj);

            opts.sz = sizeof(opts);
            opts.kernel_log_buf = kernel_log_buf;
            opts.kernel_log_size = sizeof(kernel_log_buf);
            opts.kernel_log_level = 1;

            memset(kernel_log_buf, 0, sizeof(kernel_log_buf));
            obj = bpf_object__open_file(SOCKET_BIND_BPF_OBJECT, &opts);
            err = libbpf_get_error(obj);
            if (err) {
              printf("socket_bind_libbpf_diagnostic_object_open_errno=%d\n",
                     positive_errno(err));
              return 1;
            }
            printf("socket_bind_libbpf_diagnostic_object_open_errno=0\n");
            setup_program_log(obj);

            allow_map = bpf_object__find_map_by_name(obj, "sd_bind_allow");
            deny_map = bpf_object__find_map_by_name(obj, "sd_bind_deny");
            if (set_map_entries(allow_map, "diagnostic_allow") != 0 ||
                set_map_entries(deny_map, "diagnostic_deny") != 0) {
              bpf_object__close(obj);
              return 1;
            }

            memset(kernel_log_buf, 0, sizeof(kernel_log_buf));
            err = bpf_object__load(obj);
            printf("socket_bind_libbpf_diagnostic_object_load_errno=%d\n",
                   positive_errno(err));
            print_kernel_log("object_load", kernel_log_buf);
            print_program_logs();
            bpf_object__close(obj);
            return 1;
          }

          if (update_empty_rule(allow_map, "allow") != 0 ||
              update_empty_rule(deny_map, "deny") != 0) {
            bpf_object__close(obj);
            return 1;
          }

          prog = bpf_object__find_program_by_name(obj, "sd_bind4");
          if (!prog) {
            printf("socket_bind_libbpf_sd_bind4_missing=1\n");
            bpf_object__close(obj);
            return 1;
          }

          link = bpf_program__attach_cgroup(prog, -1);
          err = libbpf_get_error(link);
          invalid_link_errno = positive_errno(err);
          printf("socket_bind_libbpf_invalid_link_errno=%d\n", invalid_link_errno);
          if (!err)
            bpf_link__destroy(link);

          current_fd = current_cgroup_fd();
          if (current_fd < 0) {
            printf("socket_bind_libbpf_current_cgroup_open_errno=%d\n", -current_fd);
            bpf_object__close(obj);
            return 1;
          }

          link = bpf_program__attach_cgroup(prog, current_fd);
          err = libbpf_get_error(link);
          current_link_errno = positive_errno(err);
          printf("socket_bind_libbpf_current_link_errno=%d\n", current_link_errno);
          if (!err)
            bpf_link__destroy(link);
          close(current_fd);

          bpf_object__close(obj);
          return invalid_link_errno == EBADF && current_link_errno == 0 ? 0 : 1;
        }

        int main(int argc, char **argv)
        {
          if (argc == 2 && strcmp(argv[1], "support-smoke") == 0)
            return support_smoke();

          fprintf(stderr, "usage: %s support-smoke\n", argv[0]);
          return 2;
        }
      '';

      buildPhase = ''
        runHook preBuild

        socket_bind_dir=${pkgs.systemd.src}/src/core/bpf/socket-bind
        if [ ! -d "$socket_bind_dir" ]; then
          socket_bind_dir=${pkgs.systemd.src}/src/core/bpf/socket_bind
        fi
        if [ ! -e "$socket_bind_dir/socket-bind.bpf.c" ]; then
          echo "cannot find stock systemd socket-bind BPF source below ${pkgs.systemd.src}" >&2
          exit 1
        fi
        cp "$socket_bind_dir/socket-bind.bpf.c" .
        cp "$socket_bind_dir/socket-bind-api.bpf.h" .

        clang \
          -std=gnu11 \
          -Wno-compare-distinct-pointer-types \
          -fno-stack-protector \
          -O2 \
          -target bpf \
          -g \
          -c \
          -D__x86_64__ \
          -D__TARGET_ARCH_x86 \
          -I. \
          -idirafter ${pkgs.libbpf}/include \
          socket-bind.bpf.c \
          -o socket-bind.bpf.o

        $CC -O2 "$src" \
          -I. \
          -DSOCKET_BIND_BPF_OBJECT="\"$out/libexec/socket-bind.bpf.o\"" \
          -o systemd-ebpf-socket-bind-libbpf \
          $(pkg-config --cflags --libs libbpf)

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm0755 systemd-ebpf-socket-bind-libbpf \
          $out/bin/systemd-ebpf-socket-bind-libbpf
        install -Dm0644 socket-bind.bpf.o \
          $out/libexec/socket-bind.bpf.o
        runHook postInstall
      '';
    };

    mkSystemdEbpfUsernsRestrictProbe = kernel: pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-userns-restrict-probe";
      version = "1";

      dontUnpack = true;

      nativeBuildInputs = [
        pkgs.bpftools
        pkgs.clang
        pkgs.pkg-config
      ];
      buildInputs = [ pkgs.libbpf ];

      systemdVmlinuxH = pkgs.runCommand "systemd-ebpf-userns-restrict-vmlinux-h-${kernel.modDirVersion}" { } ''
        mkdir -p $out/include
        ${pkgs.bpftools}/bin/bpftool btf dump file ${kernel.dev}/vmlinux format c \
          > $out/include/vmlinux.h
      '';

      src = pkgs.writeText "systemd-ebpf-userns-restrict-probe.c" ''
        #define _GNU_SOURCE
        #include <bpf/bpf.h>
        #include <bpf/libbpf.h>
        #include <errno.h>
        #include <linux/bpf.h>
        #include <stdarg.h>
        #include <stdbool.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        #include "userns-restrict.skel.h"

        #define USERNS_MAX (16U * 1024U)
        #define MOUNTS_MAX 4096U

        static char object_log_buf[1024 * 1024];

        struct program_log {
          const char *name;
          char buf[256 * 1024];
        };

        static struct program_log program_logs[] = {
          { "userns_restrict_path_chown", { 0 } },
          { "userns_restrict_path_mkdir", { 0 } },
          { "userns_restrict_path_mknod", { 0 } },
          { "userns_restrict_path_symlink", { 0 } },
          { "userns_restrict_path_link", { 0 } },
          { "userns_restrict_task_fix_setgroups", { 0 } },
          { "userns_restrict_free_user_ns", { 0 } },
        };

        static int positive_errno(int err)
        {
          return err < 0 ? -err : err;
        }

        static const char *libbpf_level_name(enum libbpf_print_level level)
        {
          switch (level) {
          case LIBBPF_WARN:
            return "warn";
          case LIBBPF_INFO:
            return "info";
          case LIBBPF_DEBUG:
            return "debug";
          default:
            return "unknown";
          }
        }

        static void print_prefixed_lines(const char *prefix, const char *text)
        {
          const char *line = text;

          while (line && *line) {
            const char *nl = strchr(line, '\n');
            if (nl)
              printf("%s=%.*s\n", prefix, (int)(nl - line), line);
            else
              printf("%s=%s\n", prefix, line);
            line = nl ? nl + 1 : NULL;
          }
        }

        static int userns_restrict_libbpf_print(enum libbpf_print_level level,
                                                const char *format, va_list args)
        {
          char prefix[80];
          char *buf;
          va_list size_args;
          int len;

          va_copy(size_args, args);
          len = vsnprintf(NULL, 0, format, size_args);
          va_end(size_args);
          if (len < 0)
            return 0;

          buf = malloc((size_t)len + 1);
          if (!buf)
            return 0;

          vsnprintf(buf, (size_t)len + 1, format, args);
          snprintf(prefix, sizeof(prefix), "userns_restrict_libbpf_%s",
                   libbpf_level_name(level));
          print_prefixed_lines(prefix, buf);
          free(buf);

          return 0;
        }

        static struct program_log *find_program_log(const char *name)
        {
          size_t i;

          if (!name)
            return NULL;

          for (i = 0; i < sizeof(program_logs) / sizeof(program_logs[0]); i++)
            if (strcmp(program_logs[i].name, name) == 0)
              return &program_logs[i];

          return NULL;
        }

        static void setup_program_logs(struct bpf_object *obj)
        {
          struct bpf_program *prog;

          bpf_object__for_each_program(prog, obj) {
            const char *name = bpf_program__name(prog);
            struct program_log *log = find_program_log(name);
            int err;

            err = bpf_program__set_log_level(prog, 1);
            printf("userns_restrict_prog_%s_set_log_level_errno=%d\n",
                   name ?: "unknown", positive_errno(err));

            if (!log)
              continue;

            memset(log->buf, 0, sizeof(log->buf));
            err = bpf_program__set_log_buf(prog, log->buf, sizeof(log->buf));
            printf("userns_restrict_prog_%s_set_log_buf_errno=%d\n",
                   name, positive_errno(err));
          }
        }

        static bool verbose_probe_logs(void)
        {
          const char *v = getenv("SYSTEMD_EBPF_USERNS_RESTRICT_VERBOSE");

          return v && *v && strcmp(v, "0") != 0;
        }

        static void print_kernel_log(const char *prefix, const char *buf)
        {
          if (!buf || !*buf)
            return;

          print_prefixed_lines(prefix, buf);
        }

        static void print_program_logs(void)
        {
          size_t i;

          for (i = 0; i < sizeof(program_logs) / sizeof(program_logs[0]); i++) {
            char prefix[128];

            snprintf(prefix, sizeof(prefix),
                     "userns_restrict_prog_%s_kernel_log",
                     program_logs[i].name);
            print_kernel_log(prefix, program_logs[i].buf);
          }
        }

        static int make_inner_hash_map(void)
        {
          LIBBPF_OPTS(bpf_map_create_opts, inner_opts);
          int fd;

          fd = bpf_map_create(BPF_MAP_TYPE_HASH, NULL, sizeof(int),
                              sizeof(uint32_t), MOUNTS_MAX, &inner_opts);
          if (fd < 0)
            return -errno;

          return fd;
        }

        static int attach_all_programs(struct bpf_object *obj)
        {
          struct bpf_program *prog;
          int failed = 0;

          bpf_object__for_each_program(prog, obj) {
            const char *name = bpf_program__name(prog);
            struct bpf_link *link;
            int err;

            link = bpf_program__attach(prog);
            err = libbpf_get_error(link);
            printf("userns_restrict_prog_%s_attach_errno=%d\n",
                   name ?: "unknown", positive_errno(err));
            if (err) {
              failed = 1;
              continue;
            }

            bpf_link__destroy(link);
          }

          return failed ? -EACCES : 0;
        }

        static int support_smoke(void)
        {
          LIBBPF_OPTS(bpf_object_open_opts, opts);
          struct userns_restrict_bpf *obj;
          struct bpf_map *setgroups_map;
          bool verbose_logs = verbose_probe_logs();
          int inner_fd = -1;
          int err;

          libbpf_set_print(userns_restrict_libbpf_print);

          memset(object_log_buf, 0, sizeof(object_log_buf));
          if (verbose_logs) {
            opts.kernel_log_buf = object_log_buf;
            opts.kernel_log_size = sizeof(object_log_buf);
            opts.kernel_log_level = 1;
            obj = userns_restrict_bpf__open_opts(&opts);
          } else {
            obj = userns_restrict_bpf__open();
          }
          err = libbpf_get_error(obj);
          printf("userns_restrict_object_open_errno=%d\n", positive_errno(err));
          if (err)
            return 1;

          if (verbose_logs)
            setup_program_logs(obj->obj);

          err = bpf_map__set_max_entries(obj->maps.userns_mnt_id_hash, USERNS_MAX);
          printf("userns_restrict_mnt_id_hash_set_max_entries_errno=%d\n",
                 positive_errno(err));
          if (err)
            goto fail;

          err = bpf_map__set_max_entries(obj->maps.userns_ringbuf,
                                         USERNS_MAX * sizeof(unsigned));
          printf("userns_restrict_ringbuf_set_max_entries_errno=%d\n",
                 positive_errno(err));
          if (err)
            goto fail;

          setgroups_map = bpf_object__find_map_by_name(obj->obj,
                                                       "userns_setgroups_deny");
          if (setgroups_map) {
            err = bpf_map__set_max_entries(setgroups_map, USERNS_MAX);
            printf("userns_restrict_setgroups_deny_set_max_entries_errno=%d\n",
                   positive_errno(err));
            if (err)
              goto fail;
          } else {
            printf("userns_restrict_setgroups_deny_map_present=0\n");
          }

          inner_fd = make_inner_hash_map();
          printf("userns_restrict_inner_map_create_errno=%d\n",
                 inner_fd < 0 ? -inner_fd : 0);
          if (inner_fd < 0)
            goto fail;

          err = bpf_map__set_inner_map_fd(obj->maps.userns_mnt_id_hash, inner_fd);
          printf("userns_restrict_set_inner_map_fd_errno=%d\n",
                 positive_errno(err));
          if (err)
            goto fail;

          memset(object_log_buf, 0, sizeof(object_log_buf));
          err = userns_restrict_bpf__load(obj);
          printf("userns_restrict_object_load_errno=%d\n", positive_errno(err));
          if (verbose_logs) {
            print_kernel_log("userns_restrict_object_load_kernel_log", object_log_buf);
            print_program_logs();
          }
          if (err)
            goto fail;

          err = attach_all_programs(obj->obj);
          printf("userns_restrict_attach_all_errno=%d\n", positive_errno(err));
          if (err)
            goto fail;

          userns_restrict_bpf__destroy(obj);
          if (inner_fd >= 0)
            close(inner_fd);
          return 0;

        fail:
          userns_restrict_bpf__destroy(obj);
          if (inner_fd >= 0)
            close(inner_fd);
          return 1;
        }

        int main(int argc, char **argv)
        {
          if (argc == 2 && strcmp(argv[1], "support-smoke") == 0)
            return support_smoke();

          fprintf(stderr, "usage: %s support-smoke\n", argv[0]);
          return 2;
        }
      '';

      buildPhase = ''
        runHook preBuild

        userns_restrict_dir=${pkgs.systemd.src}/src/nsresourced/bpf/userns-restrict
        if [ ! -e "$userns_restrict_dir/userns-restrict.bpf.c" ]; then
          echo "cannot find stock systemd userns-restrict BPF source below ${pkgs.systemd.src}" >&2
          exit 1
        fi
        cp "$userns_restrict_dir/userns-restrict.bpf.c" .

        mkdir -p bpf-compat
        cat >bpf-compat/errno.h <<'EOF'
        #include <asm-generic/errno.h>
        EOF

        ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
          -std=gnu11 \
          -Wno-compare-distinct-pointer-types \
          -fno-stack-protector \
          -O2 \
          -target bpf \
          -g \
          -c \
          -D__x86_64__ \
          -D__TARGET_ARCH_x86 \
          -Ibpf-compat \
          -I$systemdVmlinuxH/include \
          -I. \
          -idirafter ${pkgs.linuxHeaders}/include \
          -idirafter ${pkgs.libbpf}/include \
          userns-restrict.bpf.c \
          -o userns-restrict.bpf.o

        bpftool gen skeleton userns-restrict.bpf.o > userns-restrict.skel.h

        $CC -O2 "$src" \
          -I. \
          -o systemd-ebpf-userns-restrict-probe \
          $(pkg-config --cflags --libs libbpf)

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm0755 systemd-ebpf-userns-restrict-probe \
          $out/bin/systemd-ebpf-userns-restrict-probe
        install -Dm0644 userns-restrict.bpf.o \
          $out/libexec/userns-restrict.bpf.o
        runHook postInstall
      '';
    };

    mkSystemdEbpfSysctlMonitorProbe = kernel: pkgs.stdenv.mkDerivation {
      pname = "systemd-ebpf-sysctl-monitor-probe";
      version = "1";

      dontUnpack = true;

      nativeBuildInputs = [
        pkgs.bpftools
        pkgs.clang
        pkgs.pkg-config
      ];
      buildInputs = [ pkgs.libbpf ];

      systemdVmlinuxH = pkgs.runCommand "systemd-ebpf-sysctl-monitor-vmlinux-h-${kernel.modDirVersion}" { } ''
        mkdir -p $out/include
        ${pkgs.bpftools}/bin/bpftool btf dump file ${kernel.dev}/vmlinux format c \
          > $out/include/vmlinux.h
      '';

      src = pkgs.writeText "systemd-ebpf-sysctl-monitor-probe.c" ''
        #define _GNU_SOURCE
        #include <bpf/bpf.h>
        #include <bpf/libbpf.h>
        #include <errno.h>
        #include <fcntl.h>
        #include <linux/bpf.h>
        #include <stdarg.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        #include "sysctl-monitor.skel.h"

        static char object_log_buf[1024 * 1024];
        static char sysctl_monitor_log_buf[512 * 1024];

        static int positive_errno(int err)
        {
          return err < 0 ? -err : err;
        }

        static const char *libbpf_level_name(enum libbpf_print_level level)
        {
          switch (level) {
          case LIBBPF_WARN:
            return "warn";
          case LIBBPF_INFO:
            return "info";
          case LIBBPF_DEBUG:
            return "debug";
          default:
            return "unknown";
          }
        }

        static void print_prefixed_lines(const char *prefix, const char *text)
        {
          const char *line = text;

          while (line && *line) {
            const char *nl = strchr(line, '\n');
            if (nl)
              printf("%s=%.*s\n", prefix, (int)(nl - line), line);
            else
              printf("%s=%s\n", prefix, line);
            line = nl ? nl + 1 : NULL;
          }
        }

        static int sysctl_monitor_libbpf_print(enum libbpf_print_level level,
                                               const char *format, va_list args)
        {
          char prefix[80];
          char *buf;
          va_list size_args;
          int len;

          va_copy(size_args, args);
          len = vsnprintf(NULL, 0, format, size_args);
          va_end(size_args);
          if (len < 0)
            return 0;

          buf = malloc((size_t)len + 1);
          if (!buf)
            return 0;

          vsnprintf(buf, (size_t)len + 1, format, args);
          snprintf(prefix, sizeof(prefix), "sysctl_monitor_libbpf_%s",
                   libbpf_level_name(level));
          print_prefixed_lines(prefix, buf);
          free(buf);

          return 0;
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

        static void setup_program_logs(struct bpf_object *obj)
        {
          struct bpf_program *prog;

          bpf_object__for_each_program(prog, obj) {
            const char *name = bpf_program__name(prog);
            int err;

            err = bpf_program__set_log_level(prog, 1);
            printf("sysctl_monitor_prog_%s_set_log_level_errno=%d\n",
                   name ?: "unknown", positive_errno(err));

            if (name && strcmp(name, "sysctl_monitor") == 0) {
              memset(sysctl_monitor_log_buf, 0, sizeof(sysctl_monitor_log_buf));
              err = bpf_program__set_log_buf(prog, sysctl_monitor_log_buf,
                                             sizeof(sysctl_monitor_log_buf));
              printf("sysctl_monitor_prog_%s_set_log_buf_errno=%d\n",
                     name, positive_errno(err));
            }
          }
        }

        static void print_program_logs(void)
        {
          print_prefixed_lines("sysctl_monitor_prog_sysctl_monitor_kernel_log",
                               sysctl_monitor_log_buf);
        }

        static int update_cgroup_map(int map_fd, int cgroup_fd)
        {
          int idx = 0;

          if (bpf_map_update_elem(map_fd, &idx, &cgroup_fd, BPF_ANY) < 0)
            return -errno;

          return 0;
        }

        static int support_smoke(void)
        {
          LIBBPF_OPTS(bpf_object_open_opts, opts,
            .kernel_log_buf = object_log_buf,
            .kernel_log_size = sizeof(object_log_buf),
            .kernel_log_level = 1,
          );
          struct sysctl_monitor_bpf *obj = NULL;
          struct bpf_link *link = NULL;
          int cgroup_fd = -1;
          int cgroup_map_fd;
          int root_fd = -1;
          int err;

          libbpf_set_print(sysctl_monitor_libbpf_print);

          memset(object_log_buf, 0, sizeof(object_log_buf));
          obj = sysctl_monitor_bpf__open_opts(&opts);
          err = obj ? 0 : -errno;
          printf("sysctl_monitor_object_open_errno=%d\n", positive_errno(err));
          if (err) {
            print_prefixed_lines("sysctl_monitor_object_open_kernel_log",
                                 object_log_buf);
            return 1;
          }

          setup_program_logs(obj->obj);

          memset(object_log_buf, 0, sizeof(object_log_buf));
          err = sysctl_monitor_bpf__load(obj);
          printf("sysctl_monitor_object_load_errno=%d\n", positive_errno(err));
          print_prefixed_lines("sysctl_monitor_object_load_kernel_log",
                               object_log_buf);
          print_program_logs();
          if (err)
            goto fail;

          cgroup_map_fd = bpf_map__fd(obj->maps.cgroup_map);
          printf("sysctl_monitor_cgroup_map_fd_errno=%d\n",
                 cgroup_map_fd < 0 ? -cgroup_map_fd : 0);
          if (cgroup_map_fd < 0)
            goto fail;

          cgroup_fd = current_cgroup_fd();
          printf("sysctl_monitor_current_cgroup_open_errno=%d\n",
                 cgroup_fd < 0 ? -cgroup_fd : 0);
          if (cgroup_fd < 0)
            goto fail;

          err = update_cgroup_map(cgroup_map_fd, cgroup_fd);
          printf("sysctl_monitor_cgroup_map_update_errno=%d\n",
                 positive_errno(err));
          if (err)
            goto fail;

          root_fd = open("/sys/fs/cgroup", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
          err = root_fd < 0 ? -errno : 0;
          printf("sysctl_monitor_root_cgroup_open_errno=%d\n",
                 positive_errno(err));
          if (err)
            goto fail;

          link = bpf_program__attach_cgroup(obj->progs.sysctl_monitor, root_fd);
          err = libbpf_get_error(link);
          printf("sysctl_monitor_attach_cgroup_errno=%d\n",
                 positive_errno(err));
          if (err) {
            link = NULL;
            goto fail;
          }

          bpf_link__destroy(link);
          close(root_fd);
          close(cgroup_fd);
          sysctl_monitor_bpf__destroy(obj);
          return 0;

        fail:
          if (link)
            bpf_link__destroy(link);
          if (root_fd >= 0)
            close(root_fd);
          if (cgroup_fd >= 0)
            close(cgroup_fd);
          sysctl_monitor_bpf__destroy(obj);
          return 1;
        }

        int main(int argc, char **argv)
        {
          if (argc == 2 && strcmp(argv[1], "support-smoke") == 0)
            return support_smoke();

          fprintf(stderr, "usage: %s support-smoke\n", argv[0]);
          return 2;
        }
      '';

      buildPhase = ''
        runHook preBuild

        sysctl_monitor_dir=${pkgs.systemd.src}/src/network/bpf/sysctl-monitor
        if [ ! -e "$sysctl_monitor_dir/sysctl-monitor.bpf.c" ]; then
          echo "cannot find stock systemd sysctl-monitor BPF source below ${pkgs.systemd.src}" >&2
          exit 1
        fi
        cp "$sysctl_monitor_dir/sysctl-monitor.bpf.c" .
        cp "$sysctl_monitor_dir/sysctl-write-event.h" .

        mkdir -p bpf-compat
        cat >bpf-compat/errno.h <<'EOF'
        #include <asm-generic/errno.h>
        EOF

        ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
          -std=gnu11 \
          -Wno-compare-distinct-pointer-types \
          -fno-stack-protector \
          -O2 \
          -target bpf \
          -g \
          -c \
          -D__x86_64__ \
          -D__TARGET_ARCH_x86 \
          -Ibpf-compat \
          -I$systemdVmlinuxH/include \
          -I. \
          -idirafter ${pkgs.linuxHeaders}/include \
          -idirafter ${pkgs.libbpf}/include \
          sysctl-monitor.bpf.c \
          -o sysctl-monitor.bpf.o

        bpftool gen skeleton sysctl-monitor.bpf.o > sysctl-monitor.skel.h

        $CC -O2 "$src" \
          -I. \
          -o systemd-ebpf-sysctl-monitor-probe \
          $(pkg-config --cflags --libs libbpf)

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm0755 systemd-ebpf-sysctl-monitor-probe \
          $out/bin/systemd-ebpf-sysctl-monitor-probe
        install -Dm0644 sysctl-monitor.bpf.o \
          $out/libexec/sysctl-monitor.bpf.o
        runHook postInstall
      '';
    };

    mkSystemdEbpfContainer =
      { hostKernel ? null
      , withBtfSystemd ? false
      }:
      {
        user = "testuser";

        shareStore = true;

        autostart.enable = true;

        startMenu.enable = false;

        prlimits.memlock = {
          soft = "unlimited";
          hard = "unlimited";
        };

        config =
          { config, lib, pkgs, ... }:
          let
            kernel =
              if hostKernel != null then
                hostKernel
              else
                config.boot.kernelPackages.kernel;
            systemdVmlinuxH = pkgs.runCommand "systemd-ebpf-vmlinux-h-${kernel.modDirVersion}" { } ''
              mkdir -p $out/include
              ${pkgs.bpftools}/bin/bpftool btf dump file ${kernel.dev}/vmlinux format c \
                > $out/include/vmlinux.h
            '';
            systemdWithBtf = pkgs.systemd.overrideAttrs (oldAttrs: {
              mesonFlags = oldAttrs.mesonFlags ++ [
                (lib.mesonOption "vmlinux-h" "provided")
                (lib.mesonOption "vmlinux-h-path" "${systemdVmlinuxH}/include/vmlinux.h")
              ];
            });
            hasSystemdNetworkdSysctlMonitor =
              builtins.pathExists
                (pkgs.systemd.src + "/src/network/bpf/sysctl-monitor/sysctl-monitor.bpf.c");
            systemdEbpfUsernsRestrictProbe =
              lib.optional includeBtfSystemd
                (mkSystemdEbpfUsernsRestrictProbe kernel);
            systemdEbpfSysctlMonitorProbe =
              lib.optional hasSystemdNetworkdSysctlMonitor
                (mkSystemdEbpfSysctlMonitorProbe kernel);
          in
        {
          documentation.enable = false;
          documentation.nixos.enable = false;

          systemd.package = lib.mkIf withBtfSystemd systemdWithBtf;

          environment.variables.SYSTEMD_EBPF_HAS_NETWORKD_SYSCTL_MONITOR =
            if hasSystemdNetworkdSysctlMonitor then "1" else "0";

          environment.systemPackages = [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.iproute2
            pkgs.procps
            config.systemd.package
            staticBusybox
            systemdEbpfForeign
            systemdEbpfPrivateBpfDelegate
            systemdEbpfFdLeakProbe
            systemdEbpfLsmIsolation
            systemdEbpfRestrictFsProbe
            systemdEbpfSocketBindLibbpf
            systemdEbpfTools
          ] ++ systemdEbpfSysctlMonitorProbe ++ systemdEbpfUsernsRestrictProbe;

          networking.useDHCP = false;
          networking.useNetworkd = true;
          systemd.network.enable = true;
        };
      };
  in
  {
    name = if includeBtfSystemd then "systemd-ebpf-btf" else "systemd-ebpf";

    description = ''
      Test stock systemd eBPF resource-control features inside a container${lib.optionalString includeBtfSystemd ", including BTF-gated nsresourced coverage"}
    '';

    tags = [ "ci" ];

      machine = import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          { config, lib, ... }:
          let
            hostKernel = config.boot.kernelPackage;
          in
          {
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
                uidMap = [ "0:500000:1048576" ];
                gidMap = [ "0:600000:1048576" ];
              };

            containers =
              {
                systemd-ebpf = mkSystemdEbpfContainer { inherit hostKernel; };
                systemd-ebpf-peer = mkSystemdEbpfContainer { inherit hostKernel; };
              }
              // lib.optionalAttrs includeBtfSystemd {
                systemd-ebpf-btf = mkSystemdEbpfContainer {
                  inherit hostKernel;
                  withBtfSystemd = true;
                };
              };
          };
        };
    };

    testScript = ''
      require 'shellwords'
      require 'tempfile'

      CT = 'systemd-ebpf'
      PEER_CT = 'systemd-ebpf-peer'
      BTF_CT = 'systemd-ebpf-btf'
      INCLUDE_BTF_SYSTEMD = ${if includeBtfSystemd then "true" else "false"}
      SYSTEMD_EBPF_CTS = ${builtins.toJSON ([ "systemd-ebpf" "systemd-ebpf-peer" ] ++ lib.optional includeBtfSystemd "systemd-ebpf-btf")}
      HAS_SYSTEMD_NETWORKD_SYSCTL_MONITOR = ${if builtins.pathExists (pkgs.systemd.src + "/src/network/bpf/sysctl-monitor/sysctl-monitor.bpf.c") then "true" else "false"}
      LOOPBACK_PORT = 19080
      BIND_ALLOW_PORT = 19081
      BIND_DENY_PORT = 19082

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

      def self.ct_sh(script, timeout: 120, ctid: CT)
        with_ct_script(script, ctid:) do |path|
          machine.succeeds(
            ct_script_command(path, ctid:),
            timeout:
          )
        end
      end

      def self.ct_capture(script, timeout: 120, ctid: CT)
        with_ct_script(script, ctid:) do |path|
          machine.execute(
            ct_script_command(path, ctid:),
            timeout:
          )
        end
      end

      def self.ct_systemd_has_btf?(ctid)
        status, output = ct_capture('systemctl --version', ctid:)
        fail "could not read systemd version in #{ctid}:\n#{output}" unless status == 0

        output.include?('+BTF')
      end

      def self.ct_systemd_run(unit, properties, command, timeout: 120, collect: true, ctid: CT)
        argv =
          [
            'systemd-run',
            '--quiet',
            '--wait',
            '--pipe',
            "--unit=#{unit}",
          ]
        argv << '--collect' if collect
        argv += properties.flat_map { |property| ['--property', property] } + command

        ct_sh(argv.shelljoin, timeout:, ctid:)
      end

      def self.systemd_byte_value(number, suffix)
        scale =
          {
            "" => 1,
            "B" => 1,
            "K" => 1024,
            "KB" => 1024,
            "M" => 1024 * 1024,
            "MB" => 1024 * 1024,
            "G" => 1024 * 1024 * 1024,
            "GB" => 1024 * 1024 * 1024,
          }

        number.to_f * scale.fetch(suffix, 1)
      end

      def self.ip_accounting_journal_values(journal)
        journal.lines.filter_map do |line|
          match =
            line.match(
              /Consumed .*?, ([0-9]+(?:\.[0-9]+)?)([KMGB]*) incoming IP traffic, ([0-9]+(?:\.[0-9]+)?)([KMGB]*) outgoing IP traffic/
            )
          next unless match

          [
            systemd_byte_value(match[1], match[2]),
            systemd_byte_value(match[3], match[4]),
          ]
        end
      end

      def self.marker_value(output, marker)
        output.lines.each do |line|
          stripped = line.strip
          next unless stripped.start_with?("#{marker}=")

          return stripped.split('=', 2).fetch(1)
        end

        nil
      end

      def self.marker_ids(output, marker)
        value = marker_value(output, marker)
        return [] if value.nil? || value.empty?

        value.split(',').map(&:strip).reject(&:empty?)
      end

      def self.dump_systemd_ebpf_startup_debug
        machine.execute(<<~SH, timeout: 180)
          echo '--- runit service status ---'
          for service in restrict-proc-sysfs osctld osctl-oomd set-clock network-online; do
            sv status "$service" || true
          done
          echo '--- restrict-proc-sysfs state ---'
          ls -la /run/service/restrict-proc-sysfs /service/restrict-proc-sysfs 2>/dev/null || true
          cat /proc/vpsadminos/kernfs_filter/stats 2>/dev/null || true
          cat /proc/vpsadminos/kernfs_filter/active 2>/dev/null || true
          echo '--- host bpffs mount state ---'
          findmnt -R /run/osctl/ct-bpf 2>/dev/null || true
          findmnt -R /sys/fs/bpf 2>/dev/null || true
          if [ -d /run/osctl/ct-bpf ]; then
            find /run/osctl/ct-bpf -maxdepth 3 -print 2>/dev/null | while IFS= read -r path; do
              ls -ld "$path" || true
            done
          fi
          echo '--- kernel denial diagnostics ---'
          dmesg 2>/dev/null | grep -Ei 'audit|denied|lxc|ct-bpf|sys/fs/bpf|bpffs|bpf' | tail -n 240 || true
          echo '--- osctld and pools ---'
          osctl ping || true
          osctl pool ls || true
          osctl user ls || true
          osctl ct ls || true
          echo '--- container details ---'
          for ct in #{SYSTEMD_EBPF_CTS.shelljoin}; do
            echo "--- $ct ---"
            osctl ct show "$ct" || true
            lxc_dir="$(osctl -j ct show "$ct" | ruby -rjson -e 'puts JSON.parse($stdin.read).fetch("lxc_dir")' 2>/dev/null || true)"
            if [ -n "$lxc_dir" ]; then
              echo "lxc_dir=$lxc_dir"
              if [ -f "$lxc_dir/config" ]; then
                cat "$lxc_dir/config"
              fi
              {
                find "$lxc_dir" -maxdepth 3 -type f -name '*.log' -print 2>/dev/null
                find "$lxc_dir" -maxdepth 3 -type f -name '*.out' -print 2>/dev/null
              } | sort | while read -r log; do
                echo "--- $log ---"
                tail -n 120 "$log" || true
              done
            fi
          done
          echo '--- filtered host failure logs ---'
          grep -Eih 'systemd-ebpf|ct-tank-systemd-ebpf|lxc|audit|denied|sys/fs/bpf|ct-bpf|bpffs|failed to start|operation not permitted|permission denied' \
            /var/log/messages /var/log/syslog /var/log/daemon.log 2>/dev/null | tail -n 300 || true
          find /var/log -maxdepth 3 -type f -name current 2>/dev/null | sort | while read -r log; do
            if grep -Eiq 'systemd-ebpf|ct-tank-systemd-ebpf|lxc|audit|denied|sys/fs/bpf|ct-bpf|bpffs|failed to start|operation not permitted|permission denied' "$log"; then
              echo "--- filtered $log ---"
              grep -Ei 'systemd-ebpf|ct-tank-systemd-ebpf|lxc|audit|denied|sys/fs/bpf|ct-bpf|bpffs|failed to start|operation not permitted|permission denied' "$log" | tail -n 160 || true
            fi
          done
          echo '--- recent host logs ---'
          tail -n 200 /var/log/messages /var/log/syslog /var/log/daemon.log 2>/dev/null || true
          find /var/log -maxdepth 3 -type f -name current 2>/dev/null | sort | while read -r log; do
            echo "--- $log ---"
            tail -n 120 "$log" || true
          done
        SH
      end

      def self.wait_for_systemd_ebpf_container(ctid)
        machine.wait_for_osctl_container(ctid, timeout: 300)
      rescue OsVm::TimeoutError => e
        _, debug = dump_systemd_ebpf_startup_debug
        fail "#{e.class}: #{e.message}\\n#{debug}"
      end

      def self.dump_systemd_ebpf_debug
        machine.execute(<<~SH, timeout: 180)
          for ct in #{SYSTEMD_EBPF_CTS.shelljoin}; do
            echo "--- container status: $ct ---"
            osctl ct show "$ct" || true
            echo "--- generated lxc config: $ct ---"
            lxc_dir="$(osctl -j ct show "$ct" | ruby -rjson -e 'puts JSON.parse($stdin.read).fetch("lxc_dir")' 2>/dev/null || true)"
            if [ -n "$lxc_dir" ] && [ -f "$lxc_dir/config" ]; then
              cat "$lxc_dir/config"
            fi
            echo "--- systemd failed units: $ct ---"
            osctl ct exec "$ct" systemctl --failed || true
            echo "--- recent journal: $ct ---"
            osctl ct exec "$ct" journalctl -b --no-pager -n 300 || true
            echo "--- cgroup view: $ct ---"
            osctl ct exec "$ct" sh -lc 'find /sys/fs/cgroup -maxdepth 3 -type d | sort | sed -n "1,120p"' || true
            echo "--- bpffs view: $ct ---"
            osctl ct exec "$ct" sh -lc 'findmnt -R /sys/fs/bpf 2>/dev/null; find /sys/fs/bpf -maxdepth 3 -print 2>/dev/null | sort' || true
          done
          echo '--- bpf sysctls ---'
          sysctl kernel.bpf_container_tracing_enabled kernel.unprivileged_bpf_disabled || true
        SH
      end

      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online
      wait_for_systemd_ebpf_container(CT)
      wait_for_systemd_ebpf_container(PEER_CT)
      wait_for_systemd_ebpf_container(BTF_CT) if INCLUDE_BTF_SYSTEMD
      machine.wait_until_succeeds("osctl ct exec #{CT} systemctl is-system-running", timeout: 180)
      machine.wait_until_succeeds("osctl ct exec #{PEER_CT} systemctl is-system-running", timeout: 180)
      machine.wait_until_succeeds("osctl ct exec #{BTF_CT} systemctl is-system-running", timeout: 180) if INCLUDE_BTF_SYSTEMD

      begin
        ct_sh("systemctl --version | grep -q '+BPF_FRAMEWORK'")
        stock_systemd_has_btf = ct_systemd_has_btf?(CT)
        puts "stock_systemd_has_btf=#{stock_systemd_has_btf ? 1 : 0}"
        if INCLUDE_BTF_SYSTEMD
          ct_sh("systemctl --version | grep -q '+BPF_FRAMEWORK'", ctid: BTF_CT)
          ct_sh("systemctl --version | grep -q '+BTF'", ctid: BTF_CT)
        end
        ct_sh("test \"$(cat /proc/sys/kernel/bpf_container_tracing_enabled)\" = 1")
        ct_sh("test \"$(cat /proc/sys/kernel/unprivileged_bpf_disabled)\" = 1")
        ct_sh("test ! -e /run/osctl/cgroup")
        ct_sh("test ! -e /run/osctl/bpf")
        ct_sh("test \"$(findmnt -n -T /sys/fs/bpf -o FSTYPE)\" = bpf")

        _, host_cgroup2 = machine.succeeds(<<~SH)
          for path in \\
            /sys/fs/cgroup \\
            /sys/fs/cgroup/unified \\
            /run/osctl/cgroup \\
            /run/osctl/cgroup/unified
          do
            if [ -f "$path/cgroup.controllers" ]; then
              printf '%s\\n' "$path"
              exit 0
            fi
          done
          findmnt -n -t cgroup2 -o TARGET | sed -n '1p'
        SH
        host_cgroup2 = host_cgroup2.lines.first&.strip
        fail "could not find host cgroup2 mount" if host_cgroup2.nil? || host_cgroup2.empty?

        fd_leak_host_dir = '/run/systemd-ebpf-fdleak'
        fd_leak_host_socket = "#{fd_leak_host_dir}/fd.sock"
        fd_leak_link_host_socket = "#{fd_leak_host_dir}/link.sock"
        fd_leak_raw_tp_link_host_socket = "#{fd_leak_host_dir}/raw-tp-link.sock"
        fd_leak_map_host_socket = "#{fd_leak_host_dir}/map.sock"
        fd_leak_bpffs_map_file_host_socket = "#{fd_leak_host_dir}/bpffs-map-file.sock"
        fd_leak_arena_host_socket = "#{fd_leak_host_dir}/arena.sock"
        fd_leak_prog_host_socket = "#{fd_leak_host_dir}/prog.sock"
        ct_prog_to_host_attach_host_socket = "#{fd_leak_host_dir}/ct-prog-host-attach.sock"
        ct_cgroup_array_to_host_update_host_socket = "#{fd_leak_host_dir}/ct-cgroup-array-host-update.sock"
        effective_query_ready = "#{fd_leak_host_dir}/effective.ready"
        effective_query_stop = "#{fd_leak_host_dir}/effective.stop"
        effective_query_out = "#{fd_leak_host_dir}/effective.out"
        effective_query_rc = "#{fd_leak_host_dir}/effective.rc"
        effective_query_pid = "#{fd_leak_host_dir}/effective.pid"
        effective_query_cgroup = "#{fd_leak_host_dir}/effective.cgroup"
        lsm_ready = '/tmp/systemd-ebpf-lsm.ready'
        lsm_stop = '/tmp/systemd-ebpf-lsm.stop'
        lsm_out = '/tmp/systemd-ebpf-lsm.out'
        lsm_rc = '/tmp/systemd-ebpf-lsm.rc'
        lsm_pid = '/tmp/systemd-ebpf-lsm.pid'
        lsm_taskfix_ready = '/tmp/systemd-ebpf-lsm-taskfix.ready'
        lsm_taskfix_stop = '/tmp/systemd-ebpf-lsm-taskfix.stop'
        lsm_taskfix_out = '/tmp/systemd-ebpf-lsm-taskfix.out'
        lsm_taskfix_rc = '/tmp/systemd-ebpf-lsm-taskfix.rc'
        lsm_taskfix_pid = '/tmp/systemd-ebpf-lsm-taskfix.pid'
        lsm_file_open_out = '/run/systemd-ebpf-lsm-file-open.out'
        lsm_file_open_pid = '/run/systemd-ebpf-lsm-file-open.pid'
        fd_leak_ct_socket = '/mnt/fdleak/fd.sock'
        fd_leak_link_ct_socket = '/mnt/fdleak/link.sock'
        fd_leak_raw_tp_link_ct_socket = '/mnt/fdleak/raw-tp-link.sock'
        fd_leak_map_ct_socket = '/mnt/fdleak/map.sock'
        fd_leak_bpffs_map_file_ct_socket = '/mnt/fdleak/bpffs-map-file.sock'
        fd_leak_arena_ct_socket = '/mnt/fdleak/arena.sock'
        fd_leak_prog_ct_socket = '/mnt/fdleak/prog.sock'
        ct_prog_to_host_attach_ct_socket = '/mnt/fdleak/ct-prog-host-attach.sock'
        ct_cgroup_array_to_host_update_ct_socket = '/mnt/fdleak/ct-cgroup-array-host-update.sock'
        fd_leak_probe = '${systemdEbpfFdLeakProbe}/bin/systemd-ebpf-fd-leak-probe'
        lsm_isolation = '${systemdEbpfLsmIsolation}/bin/systemd-ebpf-lsm-isolation'
        socket_bind_libbpf = '${systemdEbpfSocketBindLibbpf}/bin/systemd-ebpf-socket-bind-libbpf'

        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(lsm_ready)} #{Shellwords.escape(lsm_stop)} \
            #{Shellwords.escape(lsm_out)} #{Shellwords.escape(lsm_rc)} \
            #{Shellwords.escape(lsm_pid)}
          (
            (
              echo lsm_helper_path=#{Shellwords.escape(lsm_isolation)}
              #{Shellwords.escape(lsm_isolation)} attach-deny-mkdir \
                #{Shellwords.escape(lsm_ready)} #{Shellwords.escape(lsm_stop)}
              printf "%s\\n" "$?" >#{Shellwords.escape(lsm_rc)}
            ) >#{Shellwords.escape(lsm_out)} 2>&1 &
            echo $! >#{Shellwords.escape(lsm_pid)}
          )
        SH
        lsm_ready_status, lsm_ready_output = ct_capture(<<~SH, timeout: 120)
          set +e
          timeout 30 sh -c 'until test -s #{Shellwords.escape(lsm_ready)}; do sleep 0.1; done'
          rc="$?"
          if [ "$rc" -ne 0 ]; then
            echo '--- lsm helper files ---'
            ls -l #{Shellwords.escape(lsm_ready)} #{Shellwords.escape(lsm_stop)} \
              #{Shellwords.escape(lsm_out)} #{Shellwords.escape(lsm_rc)} \
              #{Shellwords.escape(lsm_pid)} 2>&1 || true
            echo '--- lsm helper output ---'
            cat #{Shellwords.escape(lsm_out)} 2>&1 || true
            echo '--- lsm helper rc ---'
            cat #{Shellwords.escape(lsm_rc)} 2>&1 || true
            echo '--- lsm helper process ---'
            if test -s #{Shellwords.escape(lsm_pid)}; then
              ps -fp "$(cat #{Shellwords.escape(lsm_pid)})" 2>&1 || true
            fi
          fi
          exit "$rc"
        SH
        unless lsm_ready_status == 0
          fail "container LSM isolation helper did not become ready:\n#{lsm_ready_output}"
        end
        ct_sh(
          "#{lsm_isolation} mkdir-check /tmp/systemd-ebpf-lsm-same deny"
        )
        machine.succeeds(
          "#{lsm_isolation} mkdir-check /tmp/systemd-ebpf-lsm-host allow",
          timeout: 120
        )
        ct_sh(
          "#{lsm_isolation} mkdir-check /tmp/systemd-ebpf-lsm-peer allow",
          ctid: PEER_CT
        )
        ct_sh("touch #{Shellwords.escape(lsm_stop)}")
        ct_sh("timeout 30 sh -c 'while kill -0 $(cat #{Shellwords.escape(lsm_pid)}) 2>/dev/null; do sleep 0.1; done'")
        _, lsm_isolation_output = ct_sh("cat #{Shellwords.escape(lsm_out)}")
        fail "container LSM isolation helper did not close its link:\n#{lsm_isolation_output}" unless lsm_isolation_output.include?('lsm_path_mkdir_link_closed=1')

        machine.succeeds("rm -f #{Shellwords.escape(lsm_file_open_out)} #{Shellwords.escape(lsm_file_open_pid)}")
        machine.succeeds(<<~SH)
          (
            osctl ct exec #{CT} #{Shellwords.escape(lsm_isolation)} \
              attach-deny-file-open /tmp/systemd-ebpf-lsm-file-open-same 20 \
              >#{Shellwords.escape(lsm_file_open_out)} 2>&1
          ) &
          echo $! >#{Shellwords.escape(lsm_file_open_pid)}
        SH
        machine.wait_until_succeeds(
          "grep -F lsm_file_open_link_fd= #{Shellwords.escape(lsm_file_open_out)}",
          timeout: 30
        )
        machine.wait_until_succeeds(
          "grep -F lsm_file_open_same_ct_errno= #{Shellwords.escape(lsm_file_open_out)}",
          timeout: 30
        )
        machine.succeeds(
          "#{lsm_isolation} open-check /tmp/systemd-ebpf-lsm-file-open-host allow",
          timeout: 120
        )
        ct_sh(
          "#{lsm_isolation} open-check /tmp/systemd-ebpf-lsm-file-open-peer allow",
          ctid: PEER_CT
        )
        machine.succeeds(
          "timeout 30 sh -c 'while kill -0 $(cat #{Shellwords.escape(lsm_file_open_pid)}) 2>/dev/null; do sleep 0.1; done'",
          timeout: 45
        )
        _, lsm_file_open_output = machine.succeeds("cat #{Shellwords.escape(lsm_file_open_out)}")
        fail "container file_open LSM isolation helper did not deny same-CT open:\n#{lsm_file_open_output}" unless lsm_file_open_output.match?(/^lsm_file_open_same_ct_errno=(1|13)$/)
        fail "container file_open LSM isolation helper did not close its link:\n#{lsm_file_open_output}" unless lsm_file_open_output.include?('lsm_file_open_link_closed=1')

        machine.succeeds("install -d -m 0777 #{Shellwords.escape(fd_leak_host_dir)}")
        machine.succeeds([
          'osctl', 'ct', 'mounts', 'new',
          '--fs', fd_leak_host_dir,
          '--type', 'bind',
          '--opts', 'bind,create=dir,rw',
          '--mountpoint', '/mnt/fdleak',
          '--no-map-ids',
          CT,
        ].shelljoin, timeout: 120)
        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(fd_leak_ct_socket)} \
            /tmp/systemd-ebpf-fdleak.out \
            /tmp/systemd-ebpf-fdleak.rc \
            /tmp/systemd-ebpf-fdleak.pid
          (
            systemd-ebpf-fd-leak-probe recv #{Shellwords.escape(fd_leak_ct_socket)} \
              >/tmp/systemd-ebpf-fdleak.out 2>&1
            echo $? >/tmp/systemd-ebpf-fdleak.rc
          ) &
          echo $! >/tmp/systemd-ebpf-fdleak.pid
        SH
        machine.wait_until_succeeds("test -S #{Shellwords.escape(fd_leak_host_socket)}", timeout: 30)
        machine.succeeds([fd_leak_probe, 'send', host_cgroup2, fd_leak_host_socket].shelljoin, timeout: 120)
        ct_sh("timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-fdleak.rc; do sleep 0.1; done'")
        _, fd_leak_output = ct_sh(
          'cat /tmp/systemd-ebpf-fdleak.out; test "$(cat /tmp/systemd-ebpf-fdleak.rc)" = 0'
        )
        fail "fd-leak did not receive a valid fd:\n#{fd_leak_output}" unless fd_leak_output.include?('leaked_cgroup_fstat_errno=0')
        [
          ['query', 'leaked_cgroup_query_errno'],
          ['attach', 'leaked_cgroup_attach_errno'],
          ['link-create', 'leaked_cgroup_link_create_errno'],
          ['detach', 'leaked_cgroup_detach_errno'],
          ['cgroup-array update', 'leaked_cgroup_array_update_errno'],
        ].each do |name, marker|
          denied = ["#{marker}=13", "#{marker}=9"].any? do |expected_marker|
            fd_leak_output.include?(expected_marker)
          end
          fail "fd-leak #{name} was not denied safely:\n#{fd_leak_output}" unless denied
        end

        machine.succeeds(<<~SH, timeout: 120)
          set -eu
          rm -f #{Shellwords.escape(ct_prog_to_host_attach_host_socket)} \
            #{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.out \
            #{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.rc \
            #{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.pid
          (
            #{fd_leak_probe} recv-container-prog-host-attach \
              #{Shellwords.escape(host_cgroup2)} \
              #{Shellwords.escape(ct_prog_to_host_attach_host_socket)} \
              >#{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.out 2>&1
            echo $? >#{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.rc
          ) </dev/null >/dev/null 2>&1 &
          echo $! >#{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.pid
        SH
        machine.wait_until_succeeds(
          "test -S #{Shellwords.escape(ct_prog_to_host_attach_host_socket)}",
          timeout: 30
        )
        ct_sh(
          "#{fd_leak_probe} send-container-prog #{Shellwords.escape(ct_prog_to_host_attach_ct_socket)}"
        )
        machine.succeeds(
          "timeout 30 sh -c 'until test -s #{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.rc; do sleep 0.1; done'",
          timeout: 45
        )
        _, ct_prog_host_attach_output = machine.succeeds(
          "cat #{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.out; test \"$(cat #{Shellwords.escape(fd_leak_host_dir)}/ct-prog-host-attach.rc)\" = 0",
          timeout: 30
        )
        fail "container program was not transferred to host helper:\n#{ct_prog_host_attach_output}" unless ct_prog_host_attach_output.include?('container_prog_host_fstat_errno=0')
        fail "host helper could not open host cgroup:\n#{ct_prog_host_attach_output}" unless ct_prog_host_attach_output.include?('container_prog_host_cgroup_open_errno=0')
        [
          ['attach', 'container_prog_host_attach_errno'],
          ['link-create', 'container_prog_host_link_create_errno'],
        ].each do |name, marker|
          denied = ["#{marker}=13", "#{marker}=1"].any? do |expected_marker|
            ct_prog_host_attach_output.include?(expected_marker)
          end
          fail "host #{name} of container-token program was not denied:\n#{ct_prog_host_attach_output}" unless denied
        end

        machine.succeeds(<<~SH, timeout: 120)
          set -eu
          rm -f #{Shellwords.escape(ct_cgroup_array_to_host_update_host_socket)} \
            #{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.out \
            #{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.rc \
            #{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.pid
          (
            #{fd_leak_probe} recv-container-cgroup-array-host-update \
              #{Shellwords.escape(host_cgroup2)} \
              #{Shellwords.escape(ct_cgroup_array_to_host_update_host_socket)} \
              >#{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.out 2>&1
            echo $? >#{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.rc
          ) </dev/null >/dev/null 2>&1 &
          echo $! >#{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.pid
        SH
        machine.wait_until_succeeds(
          "test -S #{Shellwords.escape(ct_cgroup_array_to_host_update_host_socket)}",
          timeout: 30
        )
        _, ct_cgroup_array_send_output = ct_sh(
          "#{fd_leak_probe} send-container-cgroup-array #{Shellwords.escape(ct_cgroup_array_to_host_update_ct_socket)}"
        )
        unless ct_cgroup_array_send_output.include?('container_cgroup_array_send_self_update_errno=0')
          fail "container cgroup-array map was not usable in its own cgroup namespace:\n#{ct_cgroup_array_send_output}"
        end
        machine.succeeds(
          "timeout 30 sh -c 'until test -s #{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.rc; do sleep 0.1; done'",
          timeout: 45
        )
        _, ct_cgroup_array_host_update_output = machine.succeeds(
          "cat #{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.out; test \"$(cat #{Shellwords.escape(fd_leak_host_dir)}/ct-cgroup-array-host-update.rc)\" = 0",
          timeout: 30
        )
        fail "container cgroup-array map was not transferred to host helper:\n#{ct_cgroup_array_host_update_output}" unless ct_cgroup_array_host_update_output.include?('container_cgroup_array_host_fstat_errno=0')
        fail "host helper could not open host cgroup for cgroup-array update:\n#{ct_cgroup_array_host_update_output}" unless ct_cgroup_array_host_update_output.include?('container_cgroup_array_host_cgroup_open_errno=0')
        denied = ['container_cgroup_array_host_update_errno=13',
                  'container_cgroup_array_host_update_errno=1'].any? do |expected_marker|
          ct_cgroup_array_host_update_output.include?(expected_marker)
        end
        fail "host update of container-token cgroup-array map was not denied:\n#{ct_cgroup_array_host_update_output}" unless denied

        _, baseline_effective_query_output = ct_sh("#{fd_leak_probe} query-current-egress-effective")
        unless baseline_effective_query_output.include?('cgroup_query_egress_errno=0 count=0 first_id=0') &&
            baseline_effective_query_output.include?('cgroup_query_egress_effective_errno=0')
          fail "baseline cgroup effective BPF query failed:\n#{baseline_effective_query_output}"
        end
        baseline_effective_ids = marker_ids(
          baseline_effective_query_output,
          'cgroup_query_egress_effective_ids'
        )

        machine.succeeds(<<~SH, timeout: 120)
          set -eu
          init_pid="$(
            osctl -j ct show #{CT} |
              ruby -rjson -e 'puts JSON.parse($stdin.read).fetch("init_pid")'
          )"
          rel="$(sed -n 's/^[0-9]*:://p' "/proc/$init_pid/cgroup" | sed -n '1p')"
          test -n "$rel"
          host_cgroup2=#{Shellwords.escape(host_cgroup2)}
          ct_cgroup="$host_cgroup2$rel"
          test -d "$ct_cgroup"
          rm -f #{Shellwords.escape(effective_query_ready)} \
            #{Shellwords.escape(effective_query_stop)} \
            #{Shellwords.escape(effective_query_out)} \
            #{Shellwords.escape(effective_query_rc)} \
            #{Shellwords.escape(effective_query_pid)} \
            #{Shellwords.escape(effective_query_cgroup)}
          printf '%s\\n' "$ct_cgroup" >#{Shellwords.escape(effective_query_cgroup)}
          (
            #{fd_leak_probe} hold-host-cgroup-egress-link \
              "$ct_cgroup" \
              #{Shellwords.escape(effective_query_ready)} \
              #{Shellwords.escape(effective_query_stop)} \
              >#{Shellwords.escape(effective_query_out)} 2>&1
            echo $? >#{Shellwords.escape(effective_query_rc)}
          ) </dev/null >/dev/null 2>&1 &
          echo $! >#{Shellwords.escape(effective_query_pid)}
        SH
        machine.wait_until_succeeds("test -s #{Shellwords.escape(effective_query_ready)}", timeout: 30)
        _, host_effective_output = machine.succeeds("cat #{Shellwords.escape(effective_query_out)}", timeout: 30)
        host_effective_prog_id = marker_value(
          host_effective_output,
          'host_effective_cgroup_prog_id'
        )
        unless host_effective_prog_id&.match?(/\A[1-9][0-9]*\z/)
          fail "host cgroup effective BPF probe did not report a program id:\n#{host_effective_output}"
        end

        _, effective_query_output = ct_sh("#{fd_leak_probe} query-current-egress-effective")
        unless effective_query_output.include?('cgroup_query_egress_errno=0 count=0 first_id=0') &&
            effective_query_output.include?('cgroup_query_egress_effective_errno=0')
          fail "host cgroup effective BPF query failed:\n#{effective_query_output}"
        end
        effective_ids = marker_ids(
          effective_query_output,
          'cgroup_query_egress_effective_ids'
        )
        if effective_ids.include?(host_effective_prog_id)
          fail "host cgroup effective BPF query leaked host program #{host_effective_prog_id}:\n#{host_effective_output}\n#{effective_query_output}"
        end
        unless effective_ids == baseline_effective_ids
          fail "host cgroup effective BPF query changed visible IDs:\n#{baseline_effective_query_output}\n#{host_effective_output}\n#{effective_query_output}"
        end
        machine.succeeds(<<~SH, timeout: 60)
          set -eu
          touch #{Shellwords.escape(effective_query_stop)}
          timeout 30 sh -c 'until test -s #{Shellwords.escape(effective_query_rc)}; do sleep 0.1; done'
          cat #{Shellwords.escape(effective_query_out)}
          test "$(cat #{Shellwords.escape(effective_query_rc)})" = 0
        SH

        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(fd_leak_link_ct_socket)} \
            /tmp/systemd-ebpf-link-fdleak.out \
            /tmp/systemd-ebpf-link-fdleak.rc \
            /tmp/systemd-ebpf-link-fdleak.pid
          (
            systemd-ebpf-fd-leak-probe recv-link #{Shellwords.escape(fd_leak_link_ct_socket)} \
              >/tmp/systemd-ebpf-link-fdleak.out 2>&1
            echo $? >/tmp/systemd-ebpf-link-fdleak.rc
          ) &
          echo $! >/tmp/systemd-ebpf-link-fdleak.pid
        SH
        machine.wait_until_succeeds("test -S #{Shellwords.escape(fd_leak_link_host_socket)}", timeout: 30)
        machine.succeeds([fd_leak_probe, 'send-link', host_cgroup2, fd_leak_link_host_socket].shelljoin, timeout: 120)
        ct_sh("timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-link-fdleak.rc; do sleep 0.1; done'")
        _, fd_leak_link_output = ct_sh(
          'cat /tmp/systemd-ebpf-link-fdleak.out; test "$(cat /tmp/systemd-ebpf-link-fdleak.rc)" = 0'
        )
        fail "link fd-leak did not receive a valid fd:\n#{fd_leak_link_output}" unless fd_leak_link_output.include?('leaked_link_fstat_errno=0')
        fail "link fd-leak exposed BPF fdinfo:\n#{fd_leak_link_output}" unless fd_leak_link_output.include?('leaked_link_fdinfo_visible=0')
        [
          ['info', 'leaked_link_info_errno', [13, 9]],
          ['update', 'leaked_link_update_errno', [13, 9]],
          ['detach', 'leaked_link_detach_errno', [13, 9]],
          ['iter-create', 'leaked_link_iter_create_errno', [13, 9]],
          ['pin', 'leaked_link_pin_errno', [13, 9]],
          ['task-fd-query', 'leaked_link_task_fd_query_errno', [13, 1]],
        ].each do |name, marker, errnos|
          denied = errnos.any? do |errno_value|
            expected_marker = "#{marker}=#{errno_value}"
            fd_leak_link_output.include?(expected_marker)
          end
          fail "link fd-leak #{name} was not denied safely:\n#{fd_leak_link_output}" unless denied
        end

        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(fd_leak_raw_tp_link_ct_socket)} \
            /tmp/systemd-ebpf-raw-tp-link-fdleak.out \
            /tmp/systemd-ebpf-raw-tp-link-fdleak.rc \
            /tmp/systemd-ebpf-raw-tp-link-fdleak.pid
          (
            systemd-ebpf-fd-leak-probe recv-raw-tp-link #{Shellwords.escape(fd_leak_raw_tp_link_ct_socket)} \
              >/tmp/systemd-ebpf-raw-tp-link-fdleak.out 2>&1
            echo $? >/tmp/systemd-ebpf-raw-tp-link-fdleak.rc
          ) &
          echo $! >/tmp/systemd-ebpf-raw-tp-link-fdleak.pid
        SH
        machine.wait_until_succeeds("test -S #{Shellwords.escape(fd_leak_raw_tp_link_host_socket)}", timeout: 30)
        machine.succeeds([fd_leak_probe, 'send-raw-tp-link', fd_leak_raw_tp_link_host_socket].shelljoin, timeout: 120)
        ct_sh("timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-raw-tp-link-fdleak.rc; do sleep 0.1; done'")
        _, fd_leak_raw_tp_link_output = ct_sh(
          'cat /tmp/systemd-ebpf-raw-tp-link-fdleak.out; test "$(cat /tmp/systemd-ebpf-raw-tp-link-fdleak.rc)" = 0'
        )
        fail "raw tracepoint link fd-leak did not receive a valid fd:\n#{fd_leak_raw_tp_link_output}" unless fd_leak_raw_tp_link_output.include?('leaked_raw_tp_link_fstat_errno=0')
        fail "raw tracepoint link fd-leak exposed BPF fdinfo:\n#{fd_leak_raw_tp_link_output}" unless fd_leak_raw_tp_link_output.include?('leaked_raw_tp_link_fdinfo_visible=0')
        [
          ['info', 'leaked_raw_tp_link_info_errno', [13, 9]],
          ['update', 'leaked_raw_tp_link_update_errno', [13, 9]],
          ['detach', 'leaked_raw_tp_link_detach_errno', [13, 9]],
          ['iter-create', 'leaked_raw_tp_link_iter_create_errno', [13, 9]],
          ['pin', 'leaked_raw_tp_link_pin_errno', [13, 9]],
          ['task-fd-query', 'leaked_raw_tp_link_task_fd_query_errno', [13, 1]],
        ].each do |name, marker, errnos|
          denied = errnos.any? do |errno_value|
            expected_marker = "#{marker}=#{errno_value}"
            fd_leak_raw_tp_link_output.include?(expected_marker)
          end
          fail "raw tracepoint link fd-leak #{name} was not denied safely:\n#{fd_leak_raw_tp_link_output}" unless denied
        end

        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(fd_leak_map_ct_socket)} \
            /tmp/systemd-ebpf-map-fdleak.out \
            /tmp/systemd-ebpf-map-fdleak.rc \
            /tmp/systemd-ebpf-map-fdleak.pid
          (
            systemd-ebpf-fd-leak-probe recv-map #{Shellwords.escape(fd_leak_map_ct_socket)} \
              >/tmp/systemd-ebpf-map-fdleak.out 2>&1
            echo $? >/tmp/systemd-ebpf-map-fdleak.rc
          ) &
          echo $! >/tmp/systemd-ebpf-map-fdleak.pid
        SH
        machine.wait_until_succeeds("test -S #{Shellwords.escape(fd_leak_map_host_socket)}", timeout: 30)
        machine.succeeds([fd_leak_probe, 'send-map', fd_leak_map_host_socket].shelljoin, timeout: 120)
        ct_sh("timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-map-fdleak.rc; do sleep 0.1; done'")
        _, fd_leak_map_output = ct_sh(
          'cat /tmp/systemd-ebpf-map-fdleak.out; test "$(cat /tmp/systemd-ebpf-map-fdleak.rc)" = 0'
        )
        fail "map fd-leak did not receive a valid fd:\n#{fd_leak_map_output}" unless fd_leak_map_output.include?('leaked_map_fstat_errno=0')
        fail "map fd-leak exposed BPF fdinfo:\n#{fd_leak_map_output}" unless fd_leak_map_output.include?('leaked_map_fdinfo_visible=0')
        [
          ['info', 'leaked_map_info_errno', [13, 9]],
          ['get-fd-by-id', 'leaked_map_get_fd_by_id_errno', [13, 1, 2]],
          ['lookup', 'leaked_map_lookup_errno', [13, 9]],
          ['update', 'leaked_map_update_errno', [13, 9]],
          ['mmap', 'leaked_map_mmap_errno', [13, 9]],
          ['lookup-batch', 'leaked_map_lookup_batch_errno', [13, 9]],
          ['update-batch', 'leaked_map_update_batch_errno', [13, 9]],
          ['delete-batch', 'leaked_map_delete_batch_errno', [13, 9]],
          ['freeze', 'leaked_map_freeze_errno', [13, 9]],
          ['pin', 'leaked_map_pin_errno', [13, 9]],
        ].each do |name, marker, errnos|
          denied = errnos.any? do |errno_value|
            expected_marker = "#{marker}=#{errno_value}"
            fd_leak_map_output.include?(expected_marker)
          end
          fail "map fd-leak #{name} was not denied safely:\n#{fd_leak_map_output}" unless denied
        end

        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(fd_leak_bpffs_map_file_ct_socket)} \
            /tmp/systemd-ebpf-bpffs-map-file-fdleak.out \
            /tmp/systemd-ebpf-bpffs-map-file-fdleak.rc \
            /tmp/systemd-ebpf-bpffs-map-file-fdleak.pid
          (
            systemd-ebpf-fd-leak-probe recv-bpffs-map-file #{Shellwords.escape(fd_leak_bpffs_map_file_ct_socket)} \
              >/tmp/systemd-ebpf-bpffs-map-file-fdleak.out 2>&1
            echo $? >/tmp/systemd-ebpf-bpffs-map-file-fdleak.rc
          ) &
          echo $! >/tmp/systemd-ebpf-bpffs-map-file-fdleak.pid
        SH
        machine.wait_until_succeeds(
          "test -S #{Shellwords.escape(fd_leak_bpffs_map_file_host_socket)}",
          timeout: 30
        )
        machine.succeeds(
          [fd_leak_probe, 'send-bpffs-map-file', fd_leak_bpffs_map_file_host_socket].shelljoin,
          timeout: 120
        )
        ct_sh("timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-bpffs-map-file-fdleak.rc; do sleep 0.1; done'")
        _, fd_leak_bpffs_map_file_output = ct_sh(
          'cat /tmp/systemd-ebpf-bpffs-map-file-fdleak.out; test "$(cat /tmp/systemd-ebpf-bpffs-map-file-fdleak.rc)" = 0'
        )
        unless fd_leak_bpffs_map_file_output.include?('leaked_bpffs_map_file_fstat_errno=0')
          fail "bpffs map-file fd-leak did not receive a valid fd:\n#{fd_leak_bpffs_map_file_output}"
        end
        unless fd_leak_bpffs_map_file_output.include?('leaked_bpffs_map_file_read_errno=13')
          fail "bpffs map-file fd-leak read was not denied safely:\n#{fd_leak_bpffs_map_file_output}"
        end

        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(fd_leak_arena_ct_socket)} \
            /tmp/systemd-ebpf-arena-fdleak.out \
            /tmp/systemd-ebpf-arena-fdleak.rc \
            /tmp/systemd-ebpf-arena-fdleak.pid
          (
            systemd-ebpf-fd-leak-probe recv-map-arena #{Shellwords.escape(fd_leak_arena_ct_socket)} \
              >/tmp/systemd-ebpf-arena-fdleak.out 2>&1
            echo $? >/tmp/systemd-ebpf-arena-fdleak.rc
          ) &
          echo $! >/tmp/systemd-ebpf-arena-fdleak.pid
        SH
        machine.wait_until_succeeds("test -S #{Shellwords.escape(fd_leak_arena_host_socket)}", timeout: 30)
        machine.succeeds([fd_leak_probe, 'send-map-arena', fd_leak_arena_host_socket].shelljoin, timeout: 120)
        ct_sh("timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-arena-fdleak.rc; do sleep 0.1; done'")
        _, fd_leak_arena_output = ct_sh(
          'cat /tmp/systemd-ebpf-arena-fdleak.out; test "$(cat /tmp/systemd-ebpf-arena-fdleak.rc)" = 0'
        )
        fail "arena map fd-leak did not receive a valid fd:\n#{fd_leak_arena_output}" unless fd_leak_arena_output.include?('leaked_arena_map_fstat_errno=0')
        fail "arena map fd-leak exposed BPF fdinfo:\n#{fd_leak_arena_output}" unless fd_leak_arena_output.include?('leaked_arena_map_fdinfo_visible=0')
        fail "arena map fd-leak get_unmapped_area was not denied before arena validation:\n#{fd_leak_arena_output}" unless fd_leak_arena_output.include?('leaked_arena_map_mmap_offset_errno=13')

        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(fd_leak_prog_ct_socket)} \
            /tmp/systemd-ebpf-prog-fdleak.out \
            /tmp/systemd-ebpf-prog-fdleak.rc \
            /tmp/systemd-ebpf-prog-fdleak.pid
          (
            systemd-ebpf-fd-leak-probe recv-prog #{Shellwords.escape(fd_leak_prog_ct_socket)} \
              >/tmp/systemd-ebpf-prog-fdleak.out 2>&1
            echo $? >/tmp/systemd-ebpf-prog-fdleak.rc
          ) &
          echo $! >/tmp/systemd-ebpf-prog-fdleak.pid
        SH
        machine.wait_until_succeeds("test -S #{Shellwords.escape(fd_leak_prog_host_socket)}", timeout: 30)
        machine.succeeds([fd_leak_probe, 'send-prog', fd_leak_prog_host_socket].shelljoin, timeout: 120)
        ct_sh("timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-prog-fdleak.rc; do sleep 0.1; done'")
        _, fd_leak_prog_output = ct_sh(
          'cat /tmp/systemd-ebpf-prog-fdleak.out; test "$(cat /tmp/systemd-ebpf-prog-fdleak.rc)" = 0'
        )
        fail "prog fd-leak did not receive a valid fd:\n#{fd_leak_prog_output}" unless fd_leak_prog_output.include?('leaked_prog_fstat_errno=0')
        fail "prog fd-leak exposed BPF fdinfo:\n#{fd_leak_prog_output}" unless fd_leak_prog_output.include?('leaked_prog_fdinfo_visible=0')
        fail "prog fd-leak bind-map setup failed:\n#{fd_leak_prog_output}" unless fd_leak_prog_output.include?('prog_bind_map_create_errno=0')
        [
          ['info', 'leaked_prog_info_errno'],
          ['test-run', 'leaked_prog_test_run_errno'],
          ['link-create', 'leaked_prog_link_create_errno'],
          ['bind-map', 'leaked_prog_bind_map_errno'],
          ['pin', 'leaked_prog_pin_errno'],
        ].each do |name, marker|
          denied = ["#{marker}=13", "#{marker}=9"].any? do |expected_marker|
            fd_leak_prog_output.include?(expected_marker)
          end
          fail "prog fd-leak #{name} was not denied safely:\n#{fd_leak_prog_output}" unless denied
        end

        ct_sh(<<~SH)
          rm -f /tmp/systemd-ebpf-server.ready /tmp/systemd-ebpf-server.log
          systemd-ebpf-server 127.0.0.1 #{LOOPBACK_PORT} /tmp/systemd-ebpf-server.ready \
            >/tmp/systemd-ebpf-server.log 2>&1 &
          echo $! >/tmp/systemd-ebpf-server.pid
          timeout 30 sh -c 'until test -s /tmp/systemd-ebpf-server.ready; do sleep 0.1; done'
        SH

        ct_systemd_run(
          'systemd-ebpf-ip-deny',
          ['IPAddressDeny=any'],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'deny']
        )
        ct_systemd_run(
          'systemd-ebpf-ip-allow',
          ['IPAddressDeny=any', 'IPAddressAllow=127.0.0.1/32'],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'allow']
        )
        ct_systemd_run(
          'systemd-ebpf-ip-accounting',
          ['IPAccounting=yes'],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'allow'],
          collect: false
        )
        _, accounting_output = ct_sh(
          'systemctl show --property=IPIngressBytes --property=IPEgressBytes --value systemd-ebpf-ip-accounting.service'
        )
        accounting_values = accounting_output.lines.map(&:strip).reject(&:empty?).map(&:to_i)
        accounting_ok = accounting_values.length == 2 && accounting_values.any? { |value| value > 0 }
        unless accounting_ok
          _, accounting_journal = ct_sh(
            'journalctl -b -u systemd-ebpf-ip-accounting.service --no-pager'
          )
          journal_values = ip_accounting_journal_values(accounting_journal).flatten
          unless journal_values.any? { |value| value > 0 }
            fail "unexpected IPAccounting counters: #{accounting_output}\n#{accounting_journal}"
          end
        end

        socket_bind_diagnostics = []
        socket_bind_diagnostic_failures = []
        [
          ['cap-status', "#{fd_leak_probe} cap-status"],
          ['stock-socket-bind-libbpf', "#{socket_bind_libbpf} support-smoke"],
          ['libbpf-probe-only', "#{fd_leak_probe} socket-bind-libbpf-probe-smoke"],
          ['direct-bind4-link', "#{fd_leak_probe} direct-bind4-link-smoke 127.0.0.1 #{BIND_DENY_PORT}"],
          ['socket-bind-like', "#{fd_leak_probe} socket-bind-like-smoke 127.0.0.1 #{BIND_DENY_PORT}"],
        ].each do |name, command|
          status, output = ct_capture(command)
          socket_bind_diagnostics << "=== #{name} status=#{status} ===\n#{output}"
          socket_bind_diagnostic_failures << "#{name}=#{status}" unless status == 0
        end
        unless socket_bind_diagnostic_failures.empty?
          fail "SocketBind diagnostics failed: #{socket_bind_diagnostic_failures.join(', ')}\n#{socket_bind_diagnostics.join("\n")}"
        end
        ct_sh("systemd-analyze log-level debug || true")

        begin
          ct_systemd_run(
            'systemd-ebpf-bind-deny',
            ['SocketBindDeny=any'],
            [fd_leak_probe, 'bind-state-test', '127.0.0.1', BIND_DENY_PORT.to_s, 'deny']
          )
        rescue => e
          fail "SocketBindDeny failed after socket-bind diagnostics:\n#{socket_bind_diagnostics.join("\n")}\n#{e.message}"
        end
        ct_systemd_run(
          'systemd-ebpf-bind-allow',
          ['SocketBindDeny=any', "SocketBindAllow=ipv4:tcp:#{BIND_ALLOW_PORT}"],
          [fd_leak_probe, 'bind-state-test', '127.0.0.1', BIND_ALLOW_PORT.to_s, 'allow']
        )
        ct_sh("#{lsm_isolation} setgroups-check allow")
        machine.succeeds("#{lsm_isolation} setgroups-check allow", timeout: 120)
        ct_sh("#{lsm_isolation} setgroups-check allow", ctid: PEER_CT)
        ct_sh(<<~SH)
          rm -f #{Shellwords.escape(lsm_taskfix_ready)} #{Shellwords.escape(lsm_taskfix_stop)} \
            #{Shellwords.escape(lsm_taskfix_out)} #{Shellwords.escape(lsm_taskfix_rc)} \
            #{Shellwords.escape(lsm_taskfix_pid)}
          (
            (
              #{Shellwords.escape(lsm_isolation)} attach-deny-task-fix-setgroups \
                #{Shellwords.escape(lsm_taskfix_ready)} #{Shellwords.escape(lsm_taskfix_stop)}
              printf "%s\\n" "$?" >#{Shellwords.escape(lsm_taskfix_rc)}
            ) >#{Shellwords.escape(lsm_taskfix_out)} 2>&1 &
            echo $! >#{Shellwords.escape(lsm_taskfix_pid)}
          )
        SH
        lsm_taskfix_ready_status, lsm_taskfix_ready_output = ct_capture(<<~SH, timeout: 120)
          set +e
          timeout 30 sh -c 'until test -s #{Shellwords.escape(lsm_taskfix_ready)}; do sleep 0.1; done'
          rc="$?"
          if [ "$rc" -ne 0 ]; then
            echo '--- task_fix_setgroups helper files ---'
            ls -l #{Shellwords.escape(lsm_taskfix_ready)} #{Shellwords.escape(lsm_taskfix_stop)} \
              #{Shellwords.escape(lsm_taskfix_out)} #{Shellwords.escape(lsm_taskfix_rc)} \
              #{Shellwords.escape(lsm_taskfix_pid)} 2>&1 || true
            echo '--- task_fix_setgroups helper output ---'
            cat #{Shellwords.escape(lsm_taskfix_out)} 2>&1 || true
            echo '--- task_fix_setgroups helper rc ---'
            cat #{Shellwords.escape(lsm_taskfix_rc)} 2>&1 || true
            echo '--- task_fix_setgroups helper process ---'
            if test -s #{Shellwords.escape(lsm_taskfix_pid)}; then
              ps -fp "$(cat #{Shellwords.escape(lsm_taskfix_pid)})" 2>&1 || true
            fi
          fi
          exit "$rc"
        SH
        unless lsm_taskfix_ready_status == 0
          fail "container task_fix_setgroups LSM isolation helper did not become ready:\n#{lsm_taskfix_ready_output}"
        end
        ct_sh("#{lsm_isolation} setgroups-check deny")
        machine.succeeds("#{lsm_isolation} setgroups-check allow", timeout: 120)
        ct_sh("#{lsm_isolation} setgroups-check allow", ctid: PEER_CT)
        ct_sh("touch #{Shellwords.escape(lsm_taskfix_stop)}")
        ct_sh(
          "timeout 30 sh -c 'while kill -0 $(cat #{Shellwords.escape(lsm_taskfix_pid)}) 2>/dev/null; do sleep 0.1; done'",
          timeout: 120
        )
        _, lsm_taskfix_output = ct_sh(
          "cat #{Shellwords.escape(lsm_taskfix_out)}; test \"$(cat #{Shellwords.escape(lsm_taskfix_rc)})\" = 0"
        )
        unless lsm_taskfix_output.include?('lsm_task_fix_setgroups_link_closed=1')
          fail "container task_fix_setgroups LSM isolation helper did not close its link:\n#{lsm_taskfix_output}"
        end

        ct_systemd_run(
          'systemd-ebpf-iface-deny',
          ['RestrictNetworkInterfaces=~lo'],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'deny']
        )
        ct_systemd_run(
          'systemd-ebpf-iface-allow',
          ['RestrictNetworkInterfaces=lo'],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'allow']
        )
        bind_network_interface_probe =
          [
            'systemd-run',
            '--quiet',
            '--wait',
            '--pipe',
            '--unit=systemd-ebpf-bind-network-interface-probe',
            '--collect',
            '--property=BindNetworkInterface=lo',
            '/run/current-system/sw/bin/true',
          ].shelljoin
        bind_network_interface_status, bind_network_interface_output =
          ct_capture(bind_network_interface_probe)
        if bind_network_interface_status == 0
          puts 'bind_network_interface_supported=1'
          ct_systemd_run(
            'systemd-ebpf-bind-network-interface',
            ['BindNetworkInterface=lo'],
            ['/run/current-system/sw/bin/systemd-ebpf-bound-iface', 'lo']
          )
        elsif bind_network_interface_output.include?('Unknown assignment: BindNetworkInterface=lo')
          puts 'bind_network_interface_supported=0'
        else
          fail "BindNetworkInterface probe failed unexpectedly:\n#{bind_network_interface_output}"
        end

        ct_sh("#{fd_leak_probe} direct-device-link-smoke")
        ct_systemd_run(
          'systemd-ebpf-device',
          ['DevicePolicy=strict', 'DeviceAllow=/dev/null rw'],
          [fd_leak_probe, 'device-policy-service-smoke']
        )

        restrict_fs_diagnostics = []
        [
          [
            'securityfs-view',
            <<~'SH'
              set -x
              findmnt -T /sys/kernel/security -o TARGET,FSTYPE,SOURCE,OPTIONS || true
              ls -la /sys/kernel/security || true
              cat /sys/kernel/security/lsm || true
              awk '$5 == "/sys/kernel/security" || $5 ~ "^/sys/kernel/security/" { print }' /proc/self/mountinfo || true
              journalctl -b --no-pager | grep -Ei 'bpf-restrict-fs|LSM BPF|RestrictFileSystems' || true
            SH
          ],
          ['lsm-file-open-smoke', "#{lsm_isolation} file-open-smoke"],
          ['lsm-file-open-bad-probe-read', "#{lsm_isolation} file-open-bad-probe-read-smoke"],
          [
            'stock-restrict-fs-skel',
            'systemd-ebpf-restrict-fs-probe'
          ],
        ].each do |name, command|
          status, output = ct_capture(command)
          restrict_fs_diagnostics << "=== #{name} status=#{status} ===\n#{output}"
          fail "RestrictFileSystems diagnostic #{name} failed:\n#{restrict_fs_diagnostics.join("\n")}" unless status == 0
        end

        begin
          ct_systemd_run(
            'systemd-ebpf-restrict-fs',
            ['RestrictFileSystems=~proc'],
            ['/run/current-system/sw/bin/systemd-ebpf-open-proc']
          )
        rescue => e
          _, restrict_fs_journal = ct_sh(
            "journalctl -b -u systemd-ebpf-restrict-fs.service --no-pager || true"
          )
          fail "RestrictFileSystems failed after diagnostics:\n#{restrict_fs_diagnostics.join("\n")}\n=== restrict-fs-service-journal ===\n#{restrict_fs_journal}\n#{e.message}"
        end

        foreign_prog = '/sys/fs/bpf/systemd-ebpf-deny-egress'
        foreign_ingress_prog = '/sys/fs/bpf/systemd-ebpf-deny-ingress'
        ct_sh("systemd-ebpf-foreign egress #{Shellwords.escape(foreign_prog)}")
        ct_sh("systemd-ebpf-foreign ingress #{Shellwords.escape(foreign_ingress_prog)}")
        private_bpf_probe =
          [
            'systemd-run',
            '--quiet',
            '--wait',
            '--collect',
            '--pipe',
            '--unit=systemd-ebpf-private-bpf',
            '--property=PrivateBPF=yes',
            '/run/current-system/sw/bin/sh',
            '-lc',
            <<~'SH'
              set -eu
              echo '--- private-bpf findmnt ---'
              findmnt -n -T /sys/fs/bpf -o TARGET,SOURCE,FSTYPE,OPTIONS || true
              echo '--- private-bpf mountinfo ---'
              awk '$5 == "/sys/fs/bpf" { print }' /proc/self/mountinfo || true
              echo '--- private-bpf tree ---'
              find /sys/fs/bpf -maxdepth 2 -print 2>/dev/null | sort || true
              findmnt -n -T /sys/fs/bpf -o FSTYPE | grep -qx bpf
              test ! -e /sys/fs/bpf/systemd-ebpf-deny-egress
            SH
          ].shelljoin
        status, private_bpf_output = ct_capture(private_bpf_probe)
        fail "PrivateBPF did not create an isolated bpffs:\n#{private_bpf_output}" unless status == 0
        private_bpf_delegate =
          [
            'systemd-run',
            '--quiet',
            '--wait',
            '--collect',
            '--pipe',
            '--unit=systemd-ebpf-private-bpf-delegate',
            '--property=PrivateBPF=yes',
            '--property=BPFDelegateCommands=BPFMapCreate',
            '--property=BPFDelegateMaps=BPFMapTypeArray',
            'systemd-ebpf-private-bpf-delegate',
          ].shelljoin
        status, private_bpf_delegate_output = ct_capture(private_bpf_delegate)
        fail "narrow PrivateBPF delegation failed:\n#{private_bpf_delegate_output}" unless status == 0
        [
          'private_bpf_delegate_bpffs_open_errno=0',
          'private_bpf_delegate_token_create_errno=0',
          'private_bpf_delegate_array_map_create_errno=0',
          'private_bpf_delegate_array_map_update_errno=0',
          'private_bpf_delegate_array_map_lookup_errno=0',
          'private_bpf_delegate_array_map_lookup_value=0x7072697662706601',
        ].each do |marker|
          fail "narrow PrivateBPF delegation missing #{marker}:\n#{private_bpf_delegate_output}" unless private_bpf_delegate_output.include?(marker)
        end
        unless ['private_bpf_delegate_ringbuf_map_create_errno=1',
                'private_bpf_delegate_ringbuf_map_create_errno=13'].any? { |marker| private_bpf_delegate_output.include?(marker) }
          fail "narrow PrivateBPF delegation unexpectedly allowed a non-delegated ringbuf map:\n#{private_bpf_delegate_output}"
        end
        broad_delegate =
          [
            'systemd-run',
            '--quiet',
            '--wait',
            '--collect',
            '--pipe',
            '--unit=systemd-ebpf-private-bpf-broad-delegate',
            '--property=PrivateBPF=yes',
            '--property=BPFDelegateCommands=any',
            '--property=BPFDelegateMaps=any',
            '--property=BPFDelegatePrograms=any',
            '--property=BPFDelegateAttachments=any',
            'systemd-ebpf-private-bpf-delegate',
            'deny-broad',
          ].shelljoin
        status, broad_delegate_output = ct_capture(broad_delegate)
        fail "broad PrivateBPF delegation unexpectedly produced usable privileges:\n#{broad_delegate_output}" unless status == 0
        if broad_delegate_output.include?('private_bpf_broad_delegate_token_create_errno=0')
          unless ['private_bpf_broad_delegate_ringbuf_map_create_errno=1',
                  'private_bpf_broad_delegate_ringbuf_map_create_errno=13'].any? { |marker| broad_delegate_output.include?(marker) }
            fail "broad PrivateBPF delegation allowed a broad map token:\n#{broad_delegate_output}"
          end
          unless ['private_bpf_broad_delegate_raw_tracepoint_prog_load_errno=1',
                  'private_bpf_broad_delegate_raw_tracepoint_prog_load_errno=13'].any? { |marker| broad_delegate_output.include?(marker) }
            fail "broad PrivateBPF delegation allowed a broad program token:\n#{broad_delegate_output}"
          end
        elsif !['private_bpf_broad_delegate_token_create_errno=1',
                'private_bpf_broad_delegate_token_create_errno=13'].any? { |marker| broad_delegate_output.include?(marker) }
          fail "broad PrivateBPF delegation failed without an expected token denial marker:\n#{broad_delegate_output}"
        end
        ct_systemd_run(
          'systemd-ebpf-ip-egress-filter-path',
          ["IPEgressFilterPath=#{foreign_prog}"],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'deny']
        )
        ct_systemd_run(
          'systemd-ebpf-foreign-program',
          ["BPFProgram=egress:#{foreign_prog}"],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'deny']
        )
        ct_systemd_run(
          'systemd-ebpf-ip-ingress-filter-path',
          ["IPIngressFilterPath=#{foreign_ingress_prog}"],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'deny']
        )
        ct_systemd_run(
          'systemd-ebpf-foreign-ingress-program',
          ["BPFProgram=ingress:#{foreign_ingress_prog}"],
          ['/run/current-system/sw/bin/systemd-ebpf-connect', '127.0.0.1', LOOPBACK_PORT.to_s, 'deny']
        )

        _, cgroup_sysctl_output = ct_sh("#{fd_leak_probe} cgroup-sysctl-like-smoke")
        [
          'cgroup_sysctl_seen_map_create_errno=0',
          'cgroup_sysctl_cgroup_map_create_errno=0',
          'cgroup_sysctl_ringbuf_map_create_errno=0',
          'cgroup_sysctl_cgroup_map_update_errno=0',
          'cgroup_sysctl_prog_load_errno=0',
          'cgroup_sysctl_link_errno=0',
          'cgroup_sysctl_read_errno=0',
          'cgroup_sysctl_write_errno=0',
          'cgroup_sysctl_seen_lookup_errno=0',
          'cgroup_sysctl_trigger_seen=1',
        ].each do |marker|
          fail "cgroup/sysctl stock-shaped smoke missing #{marker}:\n#{cgroup_sysctl_output}" unless cgroup_sysctl_output.include?(marker)
        end
        unless ['cgroup_sysctl_var_stack_nonzero_write_prog_load_errno=1',
                'cgroup_sysctl_var_stack_nonzero_write_prog_load_errno=13'].any? { |marker| cgroup_sysctl_output.include?(marker) }
          fail "cgroup/sysctl stock-shaped smoke allowed a nonzero variable stack write:\n#{cgroup_sysctl_output}"
        end

        networkd_sysctl_script = <<~SH
          set -e
          has_networkd_sysctl_monitor=#{HAS_SYSTEMD_NETWORKD_SYSCTL_MONITOR ? '1' : '0'}
          systemd_has_btf=0

          echo '--- networkd systemd version ---'
          systemctl --version | sed 's/^/networkd_systemd_version_/'
          if systemctl --version | grep -q '+BTF'; then
            systemd_has_btf=1
          fi
          echo "networkd_systemd_has_btf=$systemd_has_btf"

          print_networkd_status() {
            pid="$(systemctl show -p MainPID --value systemd-networkd.service || true)"
            echo "networkd_main_pid=''${pid:-}"
            if [ -z "$pid" ] || [ "$pid" = 0 ] || [ ! -r "/proc/$pid/status" ]; then
              echo "networkd_status_unavailable=1"
              return
            fi

            awk '/^(Name|Uid|Gid|NStgid|NSpid|CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):/ { print "networkd_status_" $0 }' \
              "/proc/$pid/status"
            for ns in user pid pid_for_children cgroup syslog tracing lsm; do
              target="$(readlink "/proc/$pid/ns/$ns" 2>/dev/null || true)"
              echo "networkd_ns_''${ns}=''${target:-missing}"
            done
            sed 's/^/networkd_cgroup_/' "/proc/$pid/cgroup" || true
          }

          run_networkd_like_cgroup_sysctl_smoke() {
            set +e
            output="$(systemd-run --quiet --wait --collect --pipe \
              --unit=systemd-ebpf-networkd-cgsysctl-smoke \
              --property=User=systemd-network \
              --property='AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_NET_RAW CAP_BPF CAP_SYS_ADMIN' \
              --property='CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_NET_RAW CAP_BPF CAP_SYS_ADMIN' \
              --property=NoNewPrivileges=yes \
              --property=ProtectControlGroups=yes \
              --property=ProtectProc=invisible \
              --property='SystemCallFilter=@system-service bpf' \
              #{fd_leak_probe} cgroup-sysctl-like-smoke 2>&1)"
            rc=$?
            set -e
            printf '%s\n' "$output"
            echo "networkd_like_cgroup_sysctl_rc=$rc"
            return "$rc"
          }

          run_networkd_like_sysctl_monitor_probe() {
            set +e
            output="$(systemd-run --quiet --wait --collect --pipe \
              --unit=systemd-ebpf-networkd-sysctl-monitor-probe \
              --property=User=systemd-network \
              --property='AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_NET_RAW CAP_BPF CAP_SYS_ADMIN' \
              --property='CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_NET_RAW CAP_BPF CAP_SYS_ADMIN' \
              --property=NoNewPrivileges=yes \
              --property=ProtectControlGroups=yes \
              --property=ProtectProc=invisible \
              --property='SystemCallFilter=@system-service bpf' \
              systemd-ebpf-sysctl-monitor-probe support-smoke 2>&1)"
            rc=$?
            set -e
            printf '%s\n' "$output"
            echo "networkd_like_sysctl_monitor_probe_rc=$rc"
            return "$rc"
          }

          run_networkd_foreign_sysctl_event_probe() {
            echo 'networkd_sysctl_monitor_packaged_btf=1'
            set +e
            sysctl -w net.ipv4.conf.dummy98.forwarding=0
            sysctl_rc="$?"
            echo "networkd_sysctl_monitor_foreign_sysctl_rc=$sysctl_rc"
            if [ "$sysctl_rc" -ne 0 ]; then
              echo '--- systemd-networkd status after failed foreign sysctl write ---'
              systemctl --no-pager --full status systemd-networkd.service || true
              echo '--- systemd-networkd journal after failed foreign sysctl write ---'
              journalctl -b -u systemd-networkd --no-pager -o short-precise || true
              set -e
              return "$sysctl_rc"
            fi

            timeout 30 sh -c 'until journalctl -b -u systemd-networkd --no-pager \
              | grep -F "Foreign process " \
              | grep -F "/proc/sys/net/ipv4/conf/dummy98/forwarding"; do sleep 0.5; done'
            event_rc="$?"
            echo "networkd_sysctl_monitor_foreign_event_rc=$event_rc"
            if [ "$event_rc" -eq 0 ]; then
              echo 'networkd_sysctl_monitor_foreign_event_seen=1'
              set -e
              return 0
            fi

            echo 'networkd_sysctl_monitor_foreign_event_seen=0'
            echo '--- dummy98 networkctl status after missing foreign sysctl event ---'
            networkctl status dummy98 --no-pager || true
            echo '--- systemd-networkd status after missing foreign sysctl event ---'
            systemctl --no-pager --full status systemd-networkd.service || true
            echo '--- systemd-networkd journal after missing foreign sysctl event ---'
            journalctl -b -u systemd-networkd --no-pager -o short-precise || true
            set -e
            return "$event_rc"
          }

          install -d -m0755 /etc/systemd/network
          printf '%s\n' \
            '[NetDev]' \
            'Name=dummy98' \
            'Kind=dummy' \
            >/etc/systemd/network/12-dummy98.netdev
          printf '%s\n' \
            '[Match]' \
            'Name=dummy98' \
            '[Network]' \
            'ConfigureWithoutCarrier=true' \
            'IPv4Forwarding=yes' \
            'IPv6AcceptRA=no' \
            >/etc/systemd/network/12-dummy98.network
          systemctl restart systemd-networkd.service
          timeout 30 sh -c 'until ip link show dummy98 >/dev/null 2>&1; do sleep 0.2; done'
          timeout 30 sh -c 'until test -e /proc/sys/net/ipv4/conf/dummy98/forwarding; do sleep 0.2; done'
          timeout 30 sh -c 'until test "$(cat /proc/sys/net/ipv4/conf/dummy98/forwarding)" = 1; do sleep 0.2; done'
          print_networkd_status
          run_networkd_like_cgroup_sysctl_smoke

          if [ "$has_networkd_sysctl_monitor" = 1 ]; then
            echo 'networkd_sysctl_monitor_source_present=1'
            run_networkd_like_sysctl_monitor_probe
            networkd_bpf_errors="$(journalctl -b -u systemd-networkd --no-pager \
              | grep -E 'Unable to load sysctl monitor|Unable to attach sysctl monitor|Failed to update cgroup map|Sysctl monitor BPF returned error' || true)"
            if [ -n "$networkd_bpf_errors" ]; then
              printf '%s\n' "$networkd_bpf_errors"
              exit 1
            fi

            if [ "$systemd_has_btf" = 1 ]; then
              run_networkd_foreign_sysctl_event_probe
              networkd_runtime_errors="$(journalctl -b -u systemd-networkd --no-pager \
                | grep -F 'Sysctl monitor BPF returned error' || true)"
              if [ -n "$networkd_runtime_errors" ]; then
                printf '%s\n' "$networkd_runtime_errors"
                exit 1
              fi
            else
              echo 'networkd_sysctl_monitor_packaged_btf=0'
              echo 'networkd_sysctl_monitor_runtime_skipped_no_btf=1'
            fi
          else
            echo 'networkd_sysctl_monitor_source_present=0'
          fi
        SH

        status, networkd_sysctl_output = ct_capture(networkd_sysctl_script, timeout: 180)
        unless status == 0
          fail "systemd-networkd sysctl monitor failed:\n#{networkd_sysctl_output}"
        end
        if INCLUDE_BTF_SYSTEMD
          status, networkd_sysctl_btf_output = ct_capture(networkd_sysctl_script, timeout: 180, ctid: BTF_CT)
          unless status == 0
            fail "systemd-networkd sysctl monitor failed in BTF systemd container:\n#{networkd_sysctl_btf_output}"
          end
        end

        nsresourced_cts = []
        nsresourced_cts << CT if stock_systemd_has_btf
        nsresourced_cts << BTF_CT if INCLUDE_BTF_SYSTEMD
        if nsresourced_cts.empty?
          puts 'stock_systemd_btf_nsresourced_supported=0'
          puts 'stock_systemd_btf_nsresourced_skipped_no_btf=1'
        end

        nsresourced_cts.each do |nsresourced_ct|
          status, nsresourced_output = ct_capture(<<~SH, timeout: 180, ctid: nsresourced_ct)
          set +e
          rc=0

          run_step() {
            name="$1"
            shift
            echo "--- step: $name ---"
            "$@"
            step_rc="$?"
            echo "step_''${name}_rc=$step_rc"
            if [ "$step_rc" -ne 0 ]; then
              rc=1
            fi
          }

          check_pin() {
            path="$1"
            if test -e "$path"; then
              echo "userns_restrict_pin_present=$path"
            else
              echo "userns_restrict_pin_missing=$path"
              rc=1
            fi
          }

          run_step install_mountfsd_socket install -Dm0644 /run/current-system/systemd/example/systemd/system/systemd-mountfsd.socket \
            /run/systemd/system/systemd-mountfsd.socket
          run_step install_mountfsd_service install -Dm0644 /run/current-system/systemd/example/systemd/system/systemd-mountfsd.service \
            /run/systemd/system/systemd-mountfsd.service
          run_step install_nsresourced_socket install -Dm0644 /run/current-system/systemd/example/systemd/system/systemd-nsresourced.socket \
            /run/systemd/system/systemd-nsresourced.socket
          run_step install_nsresourced_service install -Dm0644 /run/current-system/systemd/example/systemd/system/systemd-nsresourced.service \
            /run/systemd/system/systemd-nsresourced.service
          run_step daemon_reload systemctl daemon-reload
          run_step start_mountfsd_socket systemctl start systemd-mountfsd.socket
          run_step start_mountfsd_service systemctl start systemd-mountfsd.service
          run_step active_mountfsd_service systemctl is-active --quiet systemd-mountfsd.service
          run_step socket_mountfsd test -S /run/systemd/io.systemd.MountFileSystem

          echo '--- userns-restrict libbpf diagnostic ---'
          systemd-ebpf-userns-restrict-probe support-smoke
          userns_probe_rc="$?"
          echo "userns_restrict_probe_rc=$userns_probe_rc"
          if [ "$userns_probe_rc" -ne 0 ]; then
            rc=1
          fi

          run_step start_nsresourced_socket systemctl start systemd-nsresourced.socket
          run_step start_nsresourced_service systemctl start systemd-nsresourced.service
          run_step active_nsresourced_service systemctl is-active --quiet systemd-nsresourced.service
          run_step socket_nsresourced test -S /run/systemd/io.systemd.NamespaceResource

          for path in \
            /sys/fs/bpf/systemd/userns-restrict/maps/userns_mnt_id_hash \
            /sys/fs/bpf/systemd/userns-restrict/maps/userns_ringbuf \
            /sys/fs/bpf/systemd/userns-restrict/programs/path_chown \
            /sys/fs/bpf/systemd/userns-restrict/programs/path_mkdir \
            /sys/fs/bpf/systemd/userns-restrict/programs/path_mknod \
            /sys/fs/bpf/systemd/userns-restrict/programs/path_symlink \
            /sys/fs/bpf/systemd/userns-restrict/programs/path_link \
            /sys/fs/bpf/systemd/userns-restrict/programs/free_user_ns
          do
            check_pin "$path"
          done

          echo '--- systemd-mountfsd status ---'
          systemctl --no-pager --full status systemd-mountfsd.socket systemd-mountfsd.service || true
          echo '--- systemd-nsresourced status ---'
          systemctl --no-pager --full status systemd-nsresourced.socket systemd-nsresourced.service || true
          echo '--- systemd-nsresourced journal ---'
          journalctl -b -u systemd-nsresourced --no-pager -o short-precise || true
          echo '--- systemd-mountfsd journal ---'
          journalctl -b -u systemd-mountfsd --no-pager -o short-precise || true
          echo '--- nsresourced diagnostic scan ---'
          journalctl -b -u systemd-nsresourced --no-pager -o short-precise | \
            grep -Ei 'Proceeding with user namespace interfaces disabled|Failed to load BPF object|Failed to attach LSM BPF program|Failed to pin|bpf-lsm|libbpf|verifier|Permission denied|Operation not permitted|Invalid argument|error|failed' || true
          echo '--- bpffs mount view ---'
          findmnt -R /sys/fs/bpf 2>/dev/null || true
          echo '--- bpffs systemd tree ---'
          find /sys/fs/bpf/systemd -maxdepth 5 -print 2>/dev/null | sort || true
          echo '--- bpftool userns-restrict objects ---'
          if command -v bpftool >/dev/null 2>&1; then
            set +e
            bpftool prog show >/tmp/systemd-ebpf-bpftool-prog.out 2>/tmp/systemd-ebpf-bpftool-prog.err
            bpftool_prog_rc="$?"
            bpftool map show >/tmp/systemd-ebpf-bpftool-map.out 2>/tmp/systemd-ebpf-bpftool-map.err
            bpftool_map_rc="$?"
            bpftool link show >/tmp/systemd-ebpf-bpftool-link.out 2>/tmp/systemd-ebpf-bpftool-link.err
            bpftool_link_rc="$?"
            set -e
            echo "bpftool_prog_show_rc=$bpftool_prog_rc"
            grep -Ei 'userns|path_chown|path_mkdir|path_mknod|path_symlink|path_link|free_user_ns' /tmp/systemd-ebpf-bpftool-prog.out || true
            echo "bpftool_map_show_rc=$bpftool_map_rc"
            grep -Ei 'userns|mnt_id|ringbuf' /tmp/systemd-ebpf-bpftool-map.out || true
            echo "bpftool_link_show_rc=$bpftool_link_rc"
            grep -Ei 'userns|path_chown|path_mkdir|path_mknod|path_symlink|path_link|free_user_ns' /tmp/systemd-ebpf-bpftool-link.out || true
          fi

          exit "$rc"
        SH
        unless status == 0
          fail "systemd-mountfsd/nsresourced userns-restrict failed in #{nsresourced_ct}:\n#{nsresourced_output}"
        end

        managed_private_users_script = <<~'SH'
          read uid_inside uid_outside uid_count _ < /proc/self/uid_map
          read gid_inside gid_outside gid_count _ < /proc/self/gid_map

          printf 'managed_private_users_uid_map=%s:%s:%s\n' \
            "$uid_inside" "$uid_outside" "$uid_count"
          printf 'managed_private_users_gid_map=%s:%s:%s\n' \
            "$gid_inside" "$gid_outside" "$gid_count"

          test "$(id -u)" = 0
          test "$uid_inside" = 0
          test "$gid_inside" = 0
          test "$uid_outside" -ge 524288
          test "$gid_outside" -ge 524288
          test "$uid_count" = 65536
          test "$gid_count" = 65536

          work=/tmp/systemd-ebpf-private-users-managed
          rm -rf "$work"
          mkdir "$work"
          : > "$work/file"
          ln -s file "$work/symlink"
          ln "$work/file" "$work/hardlink"
          printf 'managed_private_users_lsm_fs_ops=1\n'
        SH

        _, managed_private_users_output = ct_systemd_run(
          'systemd-ebpf-private-users-managed',
          ['PrivateUsers=managed'],
          ['/run/current-system/sw/bin/sh', '-eu', '-c', managed_private_users_script],
          timeout: 180,
          ctid: nsresourced_ct
        )
        unless managed_private_users_output.include?('managed_private_users_uid_map=') &&
            managed_private_users_output.include?('managed_private_users_gid_map=') &&
            managed_private_users_output.include?('managed_private_users_lsm_fs_ops=1')
          fail "PrivateUsers=managed did not report managed maps in #{nsresourced_ct}:\n#{managed_private_users_output}"
        end

        ct_sh(<<~SH, ctid: nsresourced_ct)
          root=/tmp/systemd-ebpf-rootdir
          rm -rf "$root"
          mkdir -p "$root/bin" "$root/tmp"
          chmod 0755 "$root" "$root/bin"
          chmod 1777 "$root/tmp"
          cp -L /run/current-system/sw/bin/busybox "$root/bin/busybox"
          chmod 0755 "$root/bin/busybox"
          for applet in sh mkdir ln rm id; do
            ln -s busybox "$root/bin/$applet"
          done
        SH

        rootdir_private_users_script = <<~'SH'
          PATH=/bin
          test "$(id -u)" = 0
          work=/tmp/rootdir-managed
          rm -rf "$work"
          mkdir "$work"
          : > "$work/file"
          ln -s file "$work/symlink"
          ln "$work/file" "$work/hardlink"
          printf 'root_directory_private_users_mountfsd=1\n'
        SH

        _, rootdir_private_users_output = ct_systemd_run(
          'systemd-ebpf-private-users-rootdir',
          ['PrivateUsers=managed', 'RootDirectory=/tmp/systemd-ebpf-rootdir'],
          ['/bin/sh', '-eu', '-c', rootdir_private_users_script],
          timeout: 180,
          ctid: nsresourced_ct
        )
        unless rootdir_private_users_output.include?('root_directory_private_users_mountfsd=1')
          fail "RootDirectory= with PrivateUsers=managed did not complete in #{nsresourced_ct}:\n#{rootdir_private_users_output}"
        end
        end
      rescue Exception => e
        _, debug = dump_systemd_ebpf_debug
        fail "#{e.class}: #{e.message}\n#{debug}"
      ensure
        machine.execute("osctl ct exec #{CT} sh -lc 'touch /tmp/systemd-ebpf-lsm.stop 2>/dev/null || true'", timeout: 60)
        machine.execute("touch /run/systemd-ebpf-fdleak/effective.stop 2>/dev/null || true", timeout: 60)
        machine.execute("osctl ct exec #{CT} sh -lc 'kill $(cat /tmp/systemd-ebpf-server.pid) 2>/dev/null || true'", timeout: 60)
      end
    '';
  }
)
