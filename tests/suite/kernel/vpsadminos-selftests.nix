import ../../make-test.nix (
  { pkgs }:
  let
    syslogNsProbe = pkgs.stdenv.mkDerivation {
      pname = "vpsadminos-syslog-ns-probe";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "syslog-ns-probe.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <limits.h>
        #include <stdio.h>
        #include <string.h>
        #include <sys/syscall.h>
        #include <unistd.h>

        #define SYSLOG_ACTION_NEW_NS 11

        static int expect_error(const char *label, const char *name, int len,
                                int expected_errno)
        {
          long ret;

          errno = 0;
          ret = syscall(SYS_syslog, SYSLOG_ACTION_NEW_NS, name, len);
          if (ret == -1 && errno == expected_errno)
            return 0;

          fprintf(stderr,
                  "%s: got ret=%ld errno=%d, expected ret=-1 errno=%d\n",
                  label, ret, errno, expected_errno);
          return 1;
        }

        static int expect_success(const char *label, const char *name, int len)
        {
          long ret;

          errno = 0;
          ret = syscall(SYS_syslog, SYSLOG_ACTION_NEW_NS, name, len);
          if (ret == 0)
            return 0;

          fprintf(stderr, "%s: got ret=%ld errno=%d, expected success\n",
                  label, ret, errno);
          return 1;
        }

        int main(void)
        {
          static const char max_name[] = "Ab0-c_d.eF12";
          static const char too_long[] = "Ab0-c_d.eF123";
          static const char embedded_nul[] = { 'a', 'b', '\0', 'c' };
          static const char embedded_newline[] = { 'a', 'b', '\n', 'c' };
          int failed = 0;

          failed |= expect_error("negative length", NULL, -1, EINVAL);
          failed |= expect_error("minimum int length", NULL, INT_MIN, EINVAL);
          failed |= expect_error("zero length", NULL, 0, EINVAL);
          failed |= expect_error("overlong name", too_long,
                                 sizeof(too_long) - 1, ENAMETOOLONG);
          failed |= expect_error("maximum int length", NULL, INT_MAX,
                                 ENAMETOOLONG);
          failed |= expect_error("leading delimiter", "-abc", 4, EINVAL);
          failed |= expect_error("trailing delimiter", "abc.", 4, EINVAL);
          failed |= expect_error("embedded space", "a b", 3, EINVAL);
          failed |= expect_error("tag delimiter", "a]b", 3, EINVAL);
          failed |= expect_error("embedded NUL", embedded_nul,
                                 sizeof(embedded_nul), EINVAL);
          failed |= expect_error("embedded newline", embedded_newline,
                                 sizeof(embedded_newline), EINVAL);
          failed |= expect_success("minimum valid name", "a", 1);
          failed |= expect_success("maximum valid name", max_name,
                                   sizeof(max_name) - 1);

          if (failed)
            return 1;

          puts("syslog namespace request boundaries passed");
          return 0;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 -Wall -Wextra -Werror "$src" -o syslog-ns-probe
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 syslog-ns-probe $out/bin/syslog-ns-probe
        runHook postInstall
      '';
    };
  in
  {
    name = "kernel-vpsadminos-selftests";

    description = ''
      Run vpsAdminOS kernel selftests from tools/testing/selftests/vpsadminos
    '';

    tags = [ "ci" ];

    machine = (
      import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            selftests = pkgs.stdenv.mkDerivation {
              pname = "vpsadminos-kernel-selftests";
              version = config.boot.kernelVersion;
              src = config.boot.kernelPackage.src;

              nativeBuildInputs = [ pkgs.rsync ];

              dontConfigure = true;

              buildPhase = ''
                runHook preBuild
                make -C tools/testing/selftests/vpsadminos
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                make -C tools/testing/selftests/vpsadminos \
                  INSTALL_PATH=$out/bin install
                find $out/bin -maxdepth 1 \
                  -type f -name '*.sh' -exec chmod +x {} +
                patchShebangs $out/bin
                runHook postInstall
              '';
            };
          in
          {
            boot.qemu = {
              memory = lib.mkForce 4096;
              cpus = lib.mkForce 1;
              cpu = {
                cores = lib.mkForce 1;
                threads = lib.mkForce 1;
                sockets = lib.mkForce 1;
              };
            };

            boot.kernel.sysctl = {
              "kernel.bpf_container_tracing_enabled" = lib.mkForce 1;
              "kernel.unprivileged_bpf_disabled" = lib.mkForce 1;
              "kernel.kptr_restrict" = lib.mkForce 0;
            };

            environment.systemPackages = [
              pkgs.coreutils
              pkgs.gawk
              pkgs.util-linux
              selftests
              syslogNsProbe
            ];
          };
      }
    );

    testScript = ''
      selftests = "/run/current-system/sw/bin"
      tests = %w[
        tracing_ns_control_path.sh
        tracing_bpf_userns_control.sh
        kernfs_filter_reload_visibility.sh
        bpf_map_in_map_domain.sh
      ]
      helpers = %w[
        tracing_ns_smoke
        tracing_bpf_userns_smoke
        bpf_map_in_map_domain_smoke
        syslog-ns-probe
      ]

      machine.start
      machine.wait_until_online
      machine.wait_for_osctl_pool('tank', timeout: 8 * 60)

      (tests + helpers).each do |test|
        machine.succeeds("test -x #{selftests}/#{test}")
      end

      tests.each do |test|
        machine.succeeds("cd #{selftests} && ./#{test}", timeout: 180)
      end

      machine.succeeds("#{selftests}/syslog-ns-probe")

      machine.succeeds(<<~'SH', timeout: 180)
        set -eu
        helper=/run/current-system/sw/bin/tracing_ns_smoke
        name=lifeCycle01
        iterations=32
        before_create=$(dmesg | grep -c 'tracing_ns: create ' || true)
        before_destroy=$(dmesg | grep -c 'tracing_ns: destroy ' || true)
        completed=0

        while [ "$completed" -lt "$iterations" ]; do
          retries=0
          while :; do
            if output=$($helper --syslog-name "$name" --tracing 2>&1); then
              helper_status=0
            else
              helper_status=$?
            fi
            if [ "$helper_status" -ne 0 ]; then
              printf '%s\n' "$output" >&2
              echo "lifecycle helper exited with status $helper_status" >&2
              exit 1
            fi
            if printf '%s\n' "$output" | grep -q '^child_tracing=tracing:\[' &&
               printf '%s\n' "$output" | grep -q '^child_syslog=syslog:\['; then
              break
            fi

            if ! printf '%s\n' "$output" | grep -q '^clone_errno=17$'; then
              printf '%s\n' "$output" >&2
              echo 'unexpected syslog/tracing lifecycle result' >&2
              exit 1
            fi

            retries=$((retries + 1))
            if [ "$retries" -ge 100 ]; then
              echo 'timed out waiting for the prior syslog namespace to teardown' >&2
              exit 1
            fi
            sleep 0.05
          done

          completed=$((completed + 1))
        done

        retries=0
        while :; do
          after_create=$(dmesg | grep -c 'tracing_ns: create ' || true)
          after_destroy=$(dmesg | grep -c 'tracing_ns: destroy ' || true)
          create_delta=$((after_create - before_create))
          destroy_delta=$((after_destroy - before_destroy))
          if [ "$create_delta" -eq "$iterations" ] &&
             [ "$destroy_delta" -eq "$iterations" ]; then
            break
          fi

          retries=$((retries + 1))
          if [ "$retries" -ge 100 ]; then
            printf 'lifecycle mismatch: create=%s destroy=%s expected=%s\n' \
              "$create_delta" "$destroy_delta" "$iterations" >&2
            exit 1
          fi
          sleep 0.05
        done

        printf 'syslog_tracing_lifecycle_create=%s destroy=%s\n' \
          "$create_delta" "$destroy_delta"
      SH
    '';
  }
)
