import ../../make-test.nix (
  { pkgs }:
  let
    lib = pkgs.lib;

    preinitNetFaultPatch = pkgs.writeText "preinit-net-fault-injection.patch" ''
      diff --git a/net/core/net_namespace.c b/net/core/net_namespace.c
      index 61db5f73ca862..39d36d7d5f7d1 100644
      --- a/net/core/net_namespace.c
      +++ b/net/core/net_namespace.c
      @@ -14,6 +14,7 @@
       #include <linux/proc_ns.h>
       #include <linux/file.h>
       #include <linux/export.h>
      +#include <linux/error-injection.h>
       #include <linux/user_namespace.h>
       #include <linux/net_namespace.h>
       #include <linux/sched/task.h>
      @@ -404,3 +405,3 @@
       /* init code that must occur even if setup_net() is not called. */
      -static __net_init int preinit_net(struct net *net, struct user_namespace *user_ns)
      +static noinline __net_init int preinit_net(struct net *net, struct user_namespace *user_ns)
       {
      @@ -432,4 +433,5 @@
       }
      +ALLOW_ERROR_INJECTION(preinit_net, ERRNO);

       /*
        * setup_net runs the initializers for the network namespace object.
    '';

    netnsPreinitProbe = pkgs.stdenv.mkDerivation {
      pname = "netns-preinit-fault-probe";
      version = "1";

      dontUnpack = true;

      src = pkgs.writeText "netns-preinit-fault-probe.c" ''
        #define _GNU_SOURCE
        #include <errno.h>
        #include <fcntl.h>
        #include <sched.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        static int enable_task_faults(void)
        {
          static const char enabled[] = "1\n";
          int fd;

          fd = open("/proc/self/make-it-fail", O_WRONLY | O_CLOEXEC);
          if (fd < 0) {
            perror("open /proc/self/make-it-fail");
            return -1;
          }
          if (write(fd, enabled, sizeof(enabled) - 1) !=
              (ssize_t)(sizeof(enabled) - 1)) {
            perror("write /proc/self/make-it-fail");
            close(fd);
            return -1;
          }
          if (close(fd) < 0) {
            perror("close /proc/self/make-it-fail");
            return -1;
          }
          return 0;
        }

        int main(int argc, char **argv)
        {
          char *end;
          long iterations;
          long i;

          if (argc != 2) {
            fprintf(stderr, "usage: %s ITERATIONS\n", argv[0]);
            return 2;
          }

          errno = 0;
          iterations = strtol(argv[1], &end, 10);
          if (errno || *end != '\0' || iterations <= 0) {
            fprintf(stderr, "invalid iteration count: %s\n", argv[1]);
            return 2;
          }

          if (enable_task_faults() < 0)
            return 1;

          for (i = 0; i < iterations; i++) {
            errno = 0;
            if (unshare(CLONE_NEWNET) == 0) {
              fprintf(stderr, "iteration %ld unexpectedly created a netns\n", i);
              return 1;
            }
            if (errno != ENOMEM) {
              fprintf(stderr,
                      "iteration %ld failed with errno=%d (%s), expected %d\n",
                      i, errno, strerror(errno), ENOMEM);
              return 1;
            }
          }

          printf("preinit_net_injected_failures=%ld\n", iterations);
          return 0;
        }
      '';

      buildPhase = ''
        runHook preBuild
        $CC -O2 -Wall -Wextra -Werror "$src" -o netns-preinit-fault-probe
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 netns-preinit-fault-probe \
          $out/bin/netns-preinit-fault-probe
        runHook postInstall
      '';
    };
  in
  {
    name = "kernel-netns-preinit-fault";

    description = ''
      Verify failed network-namespace preinitialization releases its allocation
    '';

    tags = [ "kernel" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          kernelPackages = import ../../../os/packages/linux/packages.nix {
            inherit
              config
              lib
              pkgs
              ;
          };
          kernelVersion = kernelPackages.defaultVersion;
          kernelDef = kernelPackages.kernels.${kernelVersion};
          kernelFeatures = kernelDef.features or { };
          kernelSource = pkgs.fetchurl {
            url = "https://github.com/vpsfreecz/linux/archive/${kernelDef.rev}.tar.gz";
            sha256 = kernelDef.sha256;
          };
          faultConfig = with lib.kernel; {
            FUNCTION_ERROR_INJECTION = yes;
            FAULT_INJECTION = yes;
            FAULT_INJECTION_DEBUG_FS = yes;
            FAIL_FUNCTION = yes;
          };
          faultKernel = pkgs.callPackage ../../../os/packages/linux/generic.nix (rec {
            version = kernelVersion;
            modDirVersion = version;
            extraMeta.branch = lib.concatStringsSep "." (lib.take 2 (lib.splitString "." version));
            src = kernelSource;
            kernelPatches = [
              pkgs.kernelPatches.bridge_stp_helper
              {
                name = "preinit-net-fault-injection";
                patch = preinitNetFaultPatch;
              }
            ];
            features = kernelFeatures;
            structuredExtraConfig = (kernelDef.structuredExtraConfig or { }) // faultConfig;
            zfsBuiltinPkg = null;
          });
        in
        {
          environment.systemPackages = [
            netnsPreinitProbe
            pkgs.coreutils
            pkgs.gawk
            pkgs.gnugrep
            pkgs.util-linux
          ];

          boot.kernelVersion = lib.mkForce kernelVersion;
          boot.kernelPackage = lib.mkForce faultKernel;
          boot.zfsBuiltin = lib.mkForce false;
        };
    };

    testScript = ''
      require 'shellwords'

      machine.start
      machine.wait_until_online
      machine.succeeds(
        "mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug"
      )

      %w[
        CONFIG_FUNCTION_ERROR_INJECTION
        CONFIG_FAULT_INJECTION
        CONFIG_FAULT_INJECTION_DEBUG_FS
        CONFIG_FAIL_FUNCTION
      ].each do |symbol|
        machine.succeeds(
          "gzip -dc /proc/config.gz | grep -Fx #{Shellwords.escape("#{symbol}=y")}"
        )
      end

      machine.succeeds(
        "grep -Eq '^preinit_net[[:space:]]+ERRNO$' " \
          "/sys/kernel/debug/fail_function/injectable"
      )

      machine.succeeds(<<~'SH', timeout: 180)
        set -eu
        fault=/sys/kernel/debug/fail_function
        iterations=256

        cleanup() {
          printf '0\n' > "$fault/probability" || true
          printf '0\n' > "$fault/times" || true
          printf '\n' > "$fault/inject" || true
          printf 'N\n' > "$fault/task-filter" || true
        }
        trap cleanup EXIT HUP INT TERM

        settled_active_netns() {
          # SLUB accounts objects in a per-CPU slab until the cache is flushed.
          test -w /sys/kernel/slab/net_namespace/shrink
          printf '1\n' > /sys/kernel/slab/net_namespace/shrink
          awk '$1 == "net_namespace" { print $2; found = 1 } END { exit !found }' \
            /proc/slabinfo
        }

        before=$(settled_active_netns)
        printf 'preinit_net\n' > "$fault/inject"
        printf '0xfffffffffffffff4\n' > "$fault/preinit_net/retval"
        printf '1\n' > "$fault/interval"
        printf '100\n' > "$fault/probability"
        printf '%s\n' -1 > "$fault/times"
        printf '0\n' > "$fault/space"
        printf 'Y\n' > "$fault/task-filter"

        grep -Eq '^preinit_net[[:space:]]+ERRNO$' "$fault/injectable"
        test "$(cat "$fault/preinit_net/retval")" = fffffffffffffff4
        netns-preinit-fault-probe "$iterations"

        printf '0\n' > "$fault/probability"
        printf '\n' > "$fault/inject"
        after=$(settled_active_netns)
        if [ "$after" -gt "$before" ]; then
          echo "net_namespace leak: before=$before after=$after failures=$iterations" >&2
          exit 1
        fi

        unshare --net true
        printf 'net_namespace_before=%s after=%s failures=%s\n' \
          "$before" "$after" "$iterations"
      SH
    '';
  }
)
