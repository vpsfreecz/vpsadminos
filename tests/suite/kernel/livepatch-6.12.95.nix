let
  correctedModuleEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_MODULE";
  releasedV1ModuleEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_RELEASED_V1_MODULE";
  predecessorModuleEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_PREDECESSOR_MODULE";
  exampleFilter = builtins.getEnv "VPSADMINOS_LIVEPATCH_EXAMPLE_FILTER";
in
assert correctedModuleEnv != "";
assert releasedV1ModuleEnv != "";
assert predecessorModuleEnv != "";
import ../../make-test.nix (
  { pkgs }:
  let
    correctedModule = builtins.storePath correctedModuleEnv;
    releasedV1Module = builtins.storePath releasedV1ModuleEnv;
    predecessorModule = builtins.storePath predecessorModuleEnv;
    correctedSha256 = builtins.hashFile "sha256" correctedModule;
    releasedV1Sha256 = builtins.hashFile "sha256" releasedV1Module;
    predecessorSha256 = builtins.hashFile "sha256" predecessorModule;
    expectedCorrectedSha256 = "d111f14a4042b04993ae27c719546382639024b90c56caff46260f9447fcb2b2";
    expectedReleasedV1Sha256 = "a3f79b223f1ad1eba764ed10e687b5800aea28b42eb1cc9fffb95f43d6260a30";
    expectedPredecessorSha256 = "70f22f6f2a1a5b0eaf57d09fdd8e988561adbea6c77fb59dcdf89b2415a9f79e";

    perfTransition = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-perf-transition";
      version = "1";
      src = ./livepatch-6.12.95;

      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o perf_transition perf_transition.c
      '';

      installPhase = ''
        install -Dm755 perf_transition "$out/bin/perf_transition"
      '';
    };

    cbpfChurn = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-cbpf-churn";
      version = "1";
      src = ./livepatch-6.12.95;

      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o cbpf_churn cbpf_churn.c
      '';

      installPhase = ''
        install -Dm755 cbpf_churn "$out/bin/cbpf_churn"
      '';
    };

    tcpLegacySocket = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-tcp-legacy-socket";
      version = "1";
      src = ./livepatch-6.12.95;

      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o tcp_legacy_socket tcp_legacy_socket.c
      '';

      installPhase = ''
        install -Dm755 tcp_legacy_socket "$out/bin/tcp_legacy_socket"
      '';
    };

    multicastHold = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-multicast-hold";
      version = "1";
      src = ./livepatch-6.12.95;

      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o multicast_hold multicast_hold.c
      '';

      installPhase = ''
        install -Dm755 multicast_hold "$out/bin/multicast_hold"
      '';
    };

    vsockFixedZerocopy = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-vsock-fixed-zerocopy";
      version = "1";
      src = ./livepatch-6.12.95;

      buildInputs = [ pkgs.liburing ];
      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -pthread -o vsock_fixed_zerocopy vsock_fixed_zerocopy.c \
          -luring
      '';

      installPhase = ''
        install -Dm755 vsock_fixed_zerocopy \
          "$out/bin/vsock_fixed_zerocopy"
      '';
    };

    nfqueueHold = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-nfqueue-hold";
      version = "1";
      src = ./livepatch-6.12.95;

      nativeBuildInputs = [ pkgs.pkg-config ];
      buildInputs = [
        pkgs.libnetfilter_queue
        pkgs.libnfnetlink
      ];
      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          $(pkg-config --cflags libnetfilter_queue) \
          -o nfqueue_hold nfqueue_hold.c \
          $(pkg-config --libs libnetfilter_queue)
      '';

      installPhase = ''
        install -Dm755 nfqueue_hold "$out/bin/nfqueue_hold"
      '';
    };

    fuseTransition = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-fuse-transition";
      version = "1";
      src = ./livepatch-6.12.95;

      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o fuse_transition fuse_transition.c
      '';

      installPhase = ''
        install -Dm755 fuse_transition "$out/bin/fuse_transition"
      '';
    };

    ipv6FragmentPartial = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-ipv6-fragment-partial";
      version = "1";
      src = ./livepatch-6.12.95;

      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o ipv6_fragment_partial ipv6_fragment_partial.c
      '';

      installPhase = ''
        install -Dm755 ipv6_fragment_partial \
          "$out/bin/ipv6_fragment_partial"
      '';
    };

    v2Runtime = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-v2-runtime";
      version = "1";
      src = ./livepatch-6.12.95;

      buildInputs = [ pkgs.lksctp-tools ];
      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o v2_runtime v2_runtime.c -lsctp -lrt
      '';

      installPhase = ''
        install -Dm755 v2_runtime "$out/bin/v2_runtime"
      '';
    };

    transitionStress = pkgs.writeShellScriptBin "livepatch-transition-stress" ''
      state_dir="''${1:?state directory is required}"
      stop_file="$state_dir/stop"

      mkdir -p "$state_dir"
      rm -f "$stop_file"

      record_success() {
        printf '.\n' >> "$state_dir/$1.ok"
      }

      cleanup_iteration() {
        ${pkgs.nftables}/bin/nft delete table inet klp_stress >/dev/null 2>&1 || true
        ${pkgs.ipset}/bin/ipset destroy >/dev/null 2>&1 || true
        ${pkgs.iproute2}/bin/ip link del klpbr0 >/dev/null 2>&1 || true
        ${pkgs.iproute2}/bin/ip netns del klpns0 >/dev/null 2>&1 || true
        ${pkgs.iproute2}/bin/ip xfrm policy delete \
          src 198.18.0.1/32 dst 198.18.0.2/32 dir out \
          >/dev/null 2>&1 || true
      }

      exercise_ipset_types() {
        while IFS='|' read -r name type element; do
          ${pkgs.ipset}/bin/ipset create "$name" "$type" timeout 1 &&
            ${pkgs.ipset}/bin/ipset add "$name" "$element" &&
            ${pkgs.ipset}/bin/ipset test "$name" "$element" ||
            return 1
        done <<'IPSET_TYPES'
      klp_ip|hash:ip|192.0.2.1
      klp_ipmac|hash:ip,mac|192.0.2.1,02:00:00:00:00:01
      klp_ipmark|hash:ip,mark|192.0.2.1,0x1
      klp_ipport|hash:ip,port|192.0.2.1,tcp:80
      klp_ipportip|hash:ip,port,ip|192.0.2.1,tcp:80,198.51.100.1
      klp_ipportnet|hash:ip,port,net|192.0.2.1,tcp:80,198.51.100.0/24
      klp_mac|hash:mac|02:00:00:00:00:01
      klp_net|hash:net|192.0.2.0/24
      klp_netiface|hash:net,iface|192.0.2.0/24,lo
      klp_netnet|hash:net,net|192.0.2.0/24,198.51.100.0/24
      klp_netport|hash:net,port|192.0.2.0/24,tcp:80
      klp_netportnet|hash:net,port,net|192.0.2.0/24,tcp:80,198.51.100.0/24
      IPSET_TYPES

        ${pkgs.ipset}/bin/ipset destroy
      }

      trap cleanup_iteration EXIT
      cleanup_iteration

      while [ ! -e "$stop_file" ]; do
        if ${pkgs.iproute2}/bin/ip link add klpbr0 type bridge &&
           ${pkgs.iproute2}/bin/ip link set klpbr0 type bridge stp_state 1 &&
           ${pkgs.iproute2}/bin/ip link set klpbr0 up &&
           ${pkgs.iproute2}/bin/ip link set klpbr0 down &&
           ${pkgs.iproute2}/bin/ip link del klpbr0; then
          record_success bridge
        else
          ${pkgs.iproute2}/bin/ip link del klpbr0 >/dev/null 2>&1 || true
        fi

        if ${pkgs.iproute2}/bin/ip netns add klpns0 &&
           ${pkgs.iproute2}/bin/ip netns exec klpns0 \
             ${pkgs.iproute2}/bin/ip link set lo up &&
           ${pkgs.iproute2}/bin/ip netns exec klpns0 \
             ${pkgs.procps}/bin/sysctl -q -w net.sctp.auth_enable=1 &&
           ${pkgs.iproute2}/bin/ip netns exec klpns0 \
             ${pkgs.procps}/bin/sysctl -n net.sctp.auth_enable >/dev/null &&
           ${pkgs.iproute2}/bin/ip netns del klpns0; then
          record_success netns
        else
          ${pkgs.iproute2}/bin/ip netns del klpns0 >/dev/null 2>&1 || true
        fi

        if exercise_ipset_types; then
          record_success ipset
        else
          ${pkgs.ipset}/bin/ipset destroy >/dev/null 2>&1 || true
        fi

        if ${pkgs.nftables}/bin/nft -f - <<'NFT_END'
      add table inet klp_stress
      add chain inet klp_stress input { type filter hook input priority 0; policy accept; }
      add set inet klp_stress endpoints { type ipv4_addr . inet_service; flags interval; }
      add element inet klp_stress endpoints { 127.0.0.1 . 1000-1001 }
      add rule inet klp_stress input udp dport 49152 queue num 0 bypass
      NFT_END
        then
          if ${pkgs.bash}/bin/bash -c \
            'printf x >/dev/udp/127.0.0.1/49152'; then
            record_success nft
          fi
        fi
        ${pkgs.nftables}/bin/nft delete table inet klp_stress >/dev/null 2>&1 || true

        if ${pkgs.iproute2}/bin/ip xfrm policy add \
             src 198.18.0.1/32 dst 198.18.0.2/32 dir out \
             priority 12345 action block &&
           ${pkgs.iproute2}/bin/ip xfrm policy delete \
             src 198.18.0.1/32 dst 198.18.0.2/32 dir out; then
          record_success xfrm
        else
          ${pkgs.iproute2}/bin/ip xfrm policy delete \
            src 198.18.0.1/32 dst 198.18.0.2/32 dir out \
            >/dev/null 2>&1 || true
        fi
      done
    '';

    machineConfig =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        kernel = config.boot.kernelPackage;
        livepatchTestModules = pkgs.stdenv.mkDerivation {
          pname = "livepatch-test-modules";
          version = kernel.modDirVersion;
          src = ./livepatch-6.12.95;

          nativeBuildInputs = kernel.nativeBuildInputs ++ [ pkgs.gnumake ];
          hardeningDisable = [
            "bindnow"
            "format"
            "fortify"
            "stackprotector"
            "pic"
          ];

          buildPhase = ''
            make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
              M="$PWD" modules
          '';

          installPhase = ''
            install -Dm644 livepatch_test_pernet_hold.ko \
              "$out/lib/modules/${kernel.modDirVersion}/extra/livepatch_test_pernet_hold.ko"
            install -Dm644 livepatch_test_probe.ko \
              "$out/lib/modules/${kernel.modDirVersion}/extra/livepatch_test_probe.ko"
          '';
        };
      in
      {
        boot.kernelVersion = lib.mkForce "6.12.95";
        services.live-patches.enable = false;
        services.nfs.server = {
          enable = true;
          exports = ''
            /tmp 127.0.0.1(rw,fsid=0,no_subtree_check,no_root_squash,insecure)
          '';
          nfsd.allowedVersions = [
            "4"
            "4.1"
            "4.2"
          ];
        };

        environment.systemPackages = [
          pkgs.iproute2
          pkgs.ipset
          pkgs.iptables
          pkgs.ipvsadm
          pkgs.nftables
          pkgs.procps
          pkgs.socat
          pkgs.util-linux
          transitionStress
        ];

        environment.etc = {
          "livepatch-test/corrected.ko".source = correctedModule;
          "livepatch-test/released-v1.ko".source = releasedV1Module;
          "livepatch-test/predecessor.ko".source = predecessorModule;
          "livepatch-test/perf-transition".source = "${perfTransition}/bin/perf_transition";
          "livepatch-test/cbpf-churn".source = "${cbpfChurn}/bin/cbpf_churn";
          "livepatch-test/tcp-legacy-socket".source = "${tcpLegacySocket}/bin/tcp_legacy_socket";
          "livepatch-test/multicast-hold".source = "${multicastHold}/bin/multicast_hold";
          "livepatch-test/vsock-fixed-zerocopy".source = "${vsockFixedZerocopy}/bin/vsock_fixed_zerocopy";
          "livepatch-test/nfqueue-hold".source = "${nfqueueHold}/bin/nfqueue_hold";
          "livepatch-test/fuse-transition".source = "${fuseTransition}/bin/fuse_transition";
          "livepatch-test/ipv6-fragment-partial".source = "${ipv6FragmentPartial}/bin/ipv6_fragment_partial";
          "livepatch-test/v2-runtime".source = "${v2Runtime}/bin/v2_runtime";
          "livepatch-test/pernet-hold.ko".source =
            "${livepatchTestModules}/lib/modules/${kernel.modDirVersion}/extra/livepatch_test_pernet_hold.ko";
          "livepatch-test/probe.ko".source =
            "${livepatchTestModules}/lib/modules/${kernel.modDirVersion}/extra/livepatch_test_probe.ko";
        };
      };
  in
  assert correctedSha256 == expectedCorrectedSha256;
  assert releasedV1Sha256 == expectedReleasedV1Sha256;
  assert predecessorSha256 == expectedPredecessorSha256;
  {
    name = "kernel-livepatch-6.12.95";

    description = ''
      Validate 6.12.95 livepatch failure, removal, replacement, and downgrade
    '';

    tags = [ "ci" ];

    machines = {
      machine = import ../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config = machineConfig;
      };
    };

    testScript = ''
      livepatch_example_filter = ${builtins.toJSON exampleFilter}
      unless livepatch_example_filter.empty?
        define_singleton_method(:it) do |message, pending: false, skip: false, &block|
          example(
            message,
            pending: pending,
            skip: skip || message != livepatch_example_filter,
            &block
          )
        end
      end

      CORRECTED_MODULE = "/etc/livepatch-test/corrected.ko"
      RELEASED_V1_MODULE = "/etc/livepatch-test/released-v1.ko"
      PREDECESSOR_MODULE = "/etc/livepatch-test/predecessor.ko"
      PERF_TRANSITION = "/etc/livepatch-test/perf-transition"
      CBPF_CHURN = "/etc/livepatch-test/cbpf-churn"
      TCP_LEGACY_SOCKET = "/etc/livepatch-test/tcp-legacy-socket"
      MULTICAST_HOLD = "/etc/livepatch-test/multicast-hold"
      VSOCK_FIXED_ZEROCOPY = "/etc/livepatch-test/vsock-fixed-zerocopy"
      NFQUEUE_HOLD = "/etc/livepatch-test/nfqueue-hold"
      FUSE_TRANSITION = "/etc/livepatch-test/fuse-transition"
      IPV6_FRAGMENT_PARTIAL = "/etc/livepatch-test/ipv6-fragment-partial"
      V2_RUNTIME = "/etc/livepatch-test/v2-runtime"
      PERNET_HOLD_MODULE = "/etc/livepatch-test/pernet-hold.ko"
      PROBE_MODULE = "/etc/livepatch-test/probe.ko"
      PROBE_PARAMETERS = "/sys/module/livepatch_test_probe/parameters"
      CORRECTED_NAME = "livepatch_2"
      RELEASED_V1_NAME = "livepatch_1"
      PREDECESSOR_NAME = "livepatch_predecessor_1"
      CORRECTED_SHA256 = ${builtins.toJSON expectedCorrectedSha256}
      RELEASED_V1_SHA256 = ${builtins.toJSON expectedReleasedV1Sha256}
      PREDECESSOR_SHA256 = ${builtins.toJSON expectedPredecessorSha256}
      # Exact GCC 15.2 disassembly places the fuse_copy_finish() call in the
      # inlined fuse_ref_page() at this offset in the boot, predecessor, and
      # corrected fuse_copy_page() implementations.  A direct internal kprobe
      # redirects this exact call site through the schedulable hold trampoline,
      # after unlock_request() cleared FR_LOCKED and before fuse_ref_page()
      # finishes the old copy state or publishes the pipe buffer.
      FUSE_REF_PAGE_ENTRY_OFFSET = 0x329
      FUSE_REF_PAGE_FINISH_CALL_OFFSET = 0x369
      # Exact boot-module and corrected-module disassembly places the first
      # instruction after the five-byte __fentry__ call at this offset in
      # nft_pipapo_insert().  Holding an entry kprobe would claim ftrace's
      # IPMODIFY slot and prevent livepatch from registering its own handler.
      NFT_PIPAPO_HOLD_OFFSET = 0x5
      # Hold the boot SUNRPC TLS worker on its push %rbp immediately after
      # the five-byte __fentry__ call.  The transition gate occupies the
      # following instruction so it can repair that pushed word before
      # redirecting the worker to the replacement.
      SUNRPC_TLS_ENTRY_HOLD_OFFSET = 0x5
      # xs_tcp_tls_setup_socket() receives the embedded work_struct. Exact
      # production DWARF places it 0x640 bytes into its sock_xprt.
      SUNRPC_TLS_WORK_OFFSET = 0x640
      SUNRPC_XS_CONNECT_GATE_OFFSET = 0x5
      SUNRPC_TLS_WORKER_GATE_OFFSET = 0x6
      # Hold a boot worker after the transition gate but before its first
      # transport->clnt read. Activation must reject this unowned old frame;
      # the entry hold above instead exercises gate redirection.
      SUNRPC_TLS_UNOWNED_HOLD_OFFSET = 0xb
      # Exact GCC 15.2 DWARF and instruction-boundary disassembly place the
      # corrected cast-before-add size calculation from inlined
      # tcp_mtu_probe() at this function-relative offset in tcp_write_xmit().
      TCP_MTU_PROBE_SIZE_OFFSET = 0x7e0
      # Exact GCC 15.2 DWARF and instruction-boundary disassembly place the
      # klp_shadow_alloc() call used to publish a TLS work shadow at section
      # offset 0x1fc.  The xs_connect symbol follows the section's 16-byte
      # __pfx_xs_connect prefix, making the required function-relative offset
      # 0x1ec.
      SUNRPC_TLS_SHADOW_ALLOC_OFFSET = 0x1ec
      # Exact corrected-module disassembly places this klp_shadow_free() call
      # at a function-relative offset where %rdi holds the transport.
      SUNRPC_CB_RELEASE_SHADOW_FREE_OFFSET = 0x27
      # After vpsadminos_sunrpc_tls_take_work() returns a callback-owned
      # record, exact corrected-module disassembly reaches this
      # cancel_delayed_work_sync() call with %rdi naming that record's
      # embedded work_struct.  Observing the held worker at this instruction
      # proves pre_unpatch() claimed the exact queued record instead of merely
      # initializing the livepatch core's unpatch transition.
      SUNRPC_TLS_DRAIN_CALLBACK_CLAIM_OFFSET = 0x56
      STRESS_STATE = "/run/livepatch-transition-stress"
      BPF_STATE = "/run/livepatch-bpf"
      IPSET_DUMP_STATE = "/run/livepatch-ipset-dump"
      TCP_STATE = "/run/livepatch-tcp"
      MULTICAST_STATE = "/run/livepatch-multicast"
      VSOCK_STATE = "/run/livepatch-vsock"
      XFRM_STATE = "/run/livepatch-xfrm"
      NFS_STATE = "/run/livepatch-nfs"
      BRIDGE_STATE = "/run/livepatch-bridge"
      FRAGMENT_STATE = "/run/livepatch-fragment"
      IPVS_STATE = "/run/livepatch-ipvs"
      NFQUEUE_STATE = "/run/livepatch-nfqueue"
      FUSE_STATE = "/run/livepatch-fuse"
      SUNRPC_STATE = "/run/livepatch-sunrpc"
      NFT_BATCH_STATE = "/run/livepatch-nft-batch"
      IPSET_HASH_OBJECTS = %w[
        ip_set_hash_ip
        ip_set_hash_ipmac
        ip_set_hash_ipmark
        ip_set_hash_ipport
        ip_set_hash_ipportip
        ip_set_hash_ipportnet
        ip_set_hash_mac
        ip_set_hash_net
        ip_set_hash_netiface
        ip_set_hash_netnet
        ip_set_hash_netport
        ip_set_hash_netportnet
      ].freeze
      ALWAYS_LOADED_TARGET_OBJECTS = %w[
        vmlinux
        fuse
        af_packet
        ppp_generic
        sctp
        libceph
        nfnetlink
        nf_tables
        ip_set
        ip_vs
      ].freeze
      LATE_TARGET_OBJECTS = (
        %w[
          bridge
          nfsv4
          vmw_vsock_virtio_transport_common
          nfnetlink_queue
        ] + IPSET_HASH_OBJECTS
      ).freeze
      LATE_TARGET_DEPENDENTS = %w[
        nf_conntrack_bridge
        br_netfilter
        vsock_loopback
      ].freeze
      V2_REPLACEMENT_FUNCTIONS = %w[
        release_task
        posix_cpu_timer_del
        posix_cpu_timer_rearm
        posix_cpu_timer_set
        xfrm6_fill_dst
        xfrm6_dst_destroy
        ppp_destroy_channel
        packet_set_ring
        sctp_process_asconf
        sctp_defaults_init
        sctp_defaults_exit
        sctp_ctrlsock_init
        sctp_ctrlsock_exit
        sctp_sysctl_net_unregister
        setup_net
        cleanup_net
        decode_new_up_state_weight
        ceph_x_update_authorizer
        ceph_con_v1_try_write
        nat_keepalive_send
      ].freeze
      KERNEL_FAULT_PATTERN =
        /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|KASAN|UBSAN|Invalid relocation target|disagrees about version|Unknown symbol/

      def self.patch_dir(name)
        "/sys/kernel/livepatch/#{name}"
      end

      def self.wait_for_patch(machine, name, enabled)
        dir = patch_dir(name)
        condition =
          if enabled == 1
            "test -d #{dir} && " \
              "test \"$(cat #{dir}/enabled)\" = 1 && " \
              "test \"$(cat #{dir}/transition)\" = 0"
          else
            "test ! -e #{dir}"
          end

        begin
          machine.wait_until_succeeds(
            condition,
            timeout: 180
          )
        rescue StandardError
          machine.execute(
            "printf 'livepatch transition diagnostic: '; " \
            "for attribute in enabled transition; do " \
            "printf '%s=' \"$attribute\"; " \
            "cat #{dir}/$attribute 2>/dev/null || printf 'missing\\n'; " \
            "done; " \
            "for state_file in /proc/[0-9]*/patch_state; do " \
            "test -r \"$state_file\" || continue; " \
            "read state < \"$state_file\" || continue; " \
            "test \"$state\" = #{enabled} && continue; " \
            "pid=''${state_file#/proc/}; pid=''${pid%/patch_state}; " \
            "read comm < /proc/$pid/comm 2>/dev/null || comm=gone; " \
            "printf 'pending pid=%s comm=%s patch_state=%s\\n' " \
            "\"$pid\" \"$comm\" \"$state\"; " \
            "cat /proc/$pid/stack 2>&1 || true; " \
            "done; " \
            "printf '%s\\n' '--- livepatch dmesg tail ---'; " \
            "dmesg | tail -n 300"
          )
          raise
        end
      end

      def self.wait_for_object(machine, patch, object, patched)
        machine.wait_until_succeeds(
          "test \"$(cat #{patch_dir(patch)}/#{object}/patched)\" = #{patched}",
          timeout: 60
        )
      end

      def self.symbol_address(machine, symbol, module_name = nil)
        module_filter =
          if module_name
            "&& $4 == \"[#{module_name}]\""
          else
            "&& NF == 3"
          end
        _, output = machine.succeeds(
          "awk '$3 == \"#{symbol}\" #{module_filter} " \
          "{ print \"0x\" $1; exit }' /proc/kallsyms"
        )
        address = output.strip
        raise "kernel symbol not found: #{symbol}" if address.empty?

        address
      end

      def self.set_probe(machine, symbol, module_name = nil)
        address = symbol_address(machine, symbol, module_name)
        machine.all_succeed(
          "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_address'",
          "sh -c 'echo #{address} > #{PROBE_PARAMETERS}/probe_address'"
        )
      end

      def self.set_offset_probe(
        machine,
        symbol,
        module_name,
        offset
      )
        address = symbol_address(machine, symbol, module_name).to_i(16) +
                  offset

        machine.all_succeed(
          "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_address'",
          "sh -c 'echo 0x#{address.to_s(16)} > " \
          "#{PROBE_PARAMETERS}/probe_address'"
        )
      end

      def self.clear_probe(machine)
        machine.succeeds(
          "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_address'"
        )
      end

      def self.set_probe2(machine, symbol, module_name = nil)
        address = symbol_address(machine, symbol, module_name)
        machine.succeeds(
          "sh -c 'echo #{address} > #{PROBE_PARAMETERS}/probe2_address'"
        )
      end

      def self.set_offset_probe2(
        machine,
        symbol,
        module_name,
        offset
      )
        address = symbol_address(machine, symbol, module_name).to_i(16) +
                  offset

        machine.all_succeed(
          "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe2_address'",
          "sh -c 'echo 0x#{address.to_s(16)} > " \
          "#{PROBE_PARAMETERS}/probe2_address'"
        )
      end

      def self.clear_probe2(machine)
        machine.succeeds(
          "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe2_address'"
        )
      end

      def self.set_probe3(machine, symbol, module_name = nil)
        address = symbol_address(machine, symbol, module_name)
        machine.succeeds(
          "sh -c 'echo #{address} > #{PROBE_PARAMETERS}/probe3_address'"
        )
      end

      def self.set_offset_probe3(
        machine,
        symbol,
        module_name,
        offset
      )
        address = symbol_address(machine, symbol, module_name).to_i(16) +
                  offset

        machine.all_succeed(
          "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe3_address'",
          "sh -c 'echo 0x#{address.to_s(16)} > " \
          "#{PROBE_PARAMETERS}/probe3_address'"
        )
      end

      def self.clear_probe3(machine)
        machine.succeeds(
          "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe3_address'"
        )
      end

      def self.probe_value(machine, name)
        machine.succeeds("cat #{PROBE_PARAMETERS}/#{name}")[1].to_i
      end

      def self.assert_kprobe_site(machine, symbol, offset, present)
        machine.succeeds(
          "test -r /sys/kernel/debug/kprobes/list"
        )

        pattern = "#{symbol}\\+0x0*#{offset.to_s(16)}[[:space:]]"
        command = "grep -E '#{pattern}' /sys/kernel/debug/kprobes/list"
        command = "! #{command}" unless present
        machine.succeeds(command)
      end

      def self.assert_sunrpc_gate_sites(machine, present)
        assert_kprobe_site(
          machine,
          "xs_connect",
          SUNRPC_XS_CONNECT_GATE_OFFSET,
          present
        )
        assert_kprobe_site(
          machine,
          "xs_tcp_tls_setup_socket",
          SUNRPC_TLS_WORKER_GATE_OFFSET,
          present
        )
      end

      def self.assert_kernel_healthy(machine, dmesg_start)
        _, before_fork = machine.succeeds(
          "dmesg | tail -n +#{dmesg_start}"
        )
        expect(before_fork).not_to match(KERNEL_FAULT_PATTERN)

        # Exercise the same task and credential allocation path on which a
        # latent slab freelist corruption first surfaced in the v12 run.
        machine.succeeds(
          "i=0; while test \"$i\" -lt 64; do " \
          "sh -c : || exit 1; i=$((i + 1)); done"
        )

        # Credential destruction is RCU-delayed.  The v13 fault arrived about
        # five seconds after its preceding example had returned, so keep the
        # health window open long enough to observe deferred put_cred_rcu()
        # callbacks instead of checking only the synchronous cleanup path.
        machine.succeeds("sleep 6")

        _, after_fork = machine.succeeds(
          "dmesg | tail -n +#{dmesg_start}"
        )
        expect(after_fork).not_to match(KERNEL_FAULT_PATTERN)
      end

      def self.arm_shadow_failures(machine, count)
        injected = probe_value(machine, "shadow_failures_injected")
        machine.succeeds(
          "sh -c 'echo #{count} > #{PROBE_PARAMETERS}/shadow_failures'"
        )
        injected
      end

      def self.arm_shadow_failure(machine)
        arm_shadow_failures(machine, 1)
      end

      def self.wait_for_shadow_failure(machine, before)
        machine.wait_until_succeeds(
          "test \"$(cat #{PROBE_PARAMETERS}/shadow_failures_injected)\" " \
          "-gt #{before}",
          timeout: 30
        )
      end

      def self.disable_patch(machine, name)
        dir = patch_dir(name)
        return unless machine.execute("test -e #{dir}/enabled")[0] == 0

        machine.succeeds("sh -c 'echo 0 > #{dir}/enabled'")
        wait_for_patch(machine, name, 0)
      end

      def self.remove_module(machine, name)
        return unless machine.execute("test -d /sys/module/#{name}")[0] == 0

        machine.succeeds("rmmod #{name}")
        machine.fails("test -d /sys/module/#{name}")
      end

      def self.unload_late_target_dependents(machine)
        LATE_TARGET_DEPENDENTS.each do |module_name|
          next unless machine.execute("test -d /sys/module/#{module_name}")[0] == 0

          machine.succeeds("modprobe -r #{module_name}")
          machine.fails("test -d /sys/module/#{module_name}")
        end
      end

      def self.reload_late_target_dependents(machine)
        LATE_TARGET_DEPENDENTS.each do |module_name|
          machine.succeeds("modprobe #{module_name}")
          machine.succeeds("test -d /sys/module/#{module_name}")
        end
      end

      def self.require_stress_progress(machine)
        %w[bridge netns ipset nft xfrm].each do |subsystem|
          machine.wait_until_succeeds(
            "test \"$(wc -l < #{STRESS_STATE}/#{subsystem}.ok)\" -ge 2",
            timeout: 120
          )
        end
      end

      def self.start_stress(machine)
        machine.succeeds(
          "mkdir -p #{STRESS_STATE}; " \
          "rm -f #{STRESS_STATE}/*.ok #{STRESS_STATE}/stop; " \
          "livepatch-transition-stress #{STRESS_STATE} " \
          ">#{STRESS_STATE}/output.log 2>&1 & " \
          "echo $! > #{STRESS_STATE}/pid"
        )
        require_stress_progress(machine)
      end

      def self.stop_stress(machine)
        return unless machine.execute("test -s #{STRESS_STATE}/pid")[0] == 0

        machine.succeeds("touch #{STRESS_STATE}/stop")
        machine.wait_until_succeeds(
          "! kill -0 \"$(cat #{STRESS_STATE}/pid)\" 2>/dev/null",
          timeout: 60
        )
        machine.succeeds("rm -f #{STRESS_STATE}/pid")
      end

      def self.stress_counts(machine)
        %w[bridge netns ipset nft xfrm].to_h do |subsystem|
          count = machine.succeeds(
            "wc -l < #{STRESS_STATE}/#{subsystem}.ok"
          )[1].to_i
          [subsystem, count]
        end
      end

      def self.wait_for_stress_advance(machine, before)
        before.each do |subsystem, count|
          machine.wait_until_succeeds(
            "test \"$(wc -l < #{STRESS_STATE}/#{subsystem}.ok)\" -gt #{count}",
            timeout: 120
          )
        end
      end

      def self.start_bpf_churn(machine)
        machine.succeeds(
          "mkdir -p #{BPF_STATE}; " \
          "rm -f #{BPF_STATE}/progress #{BPF_STATE}/stop; " \
          "#{CBPF_CHURN} #{BPF_STATE}/progress #{BPF_STATE}/stop " \
          ">#{BPF_STATE}/output.log 2>&1 & " \
          "echo $! > #{BPF_STATE}/pid"
        )
        machine.wait_until_succeeds(
          "test \"$(cat #{BPF_STATE}/progress)\" -ge 128",
          timeout: 60
        )
      end

      def self.stop_bpf_churn(machine)
        return unless machine.execute("test -s #{BPF_STATE}/pid")[0] == 0

        machine.succeeds("touch #{BPF_STATE}/stop")
        machine.wait_until_succeeds(
          "! kill -0 \"$(cat #{BPF_STATE}/pid)\" 2>/dev/null",
          timeout: 30
        )
        machine.succeeds("rm -f #{BPF_STATE}/pid")
      end

      def self.cleanup_transition_state(machine)
        machine.execute(
          "nft delete table inet klp_pre >/dev/null 2>&1 || true; " \
          "ipset destroy klp_pre_ip >/dev/null 2>&1 || true; " \
          "ip link del klp_prebr0 >/dev/null 2>&1 || true; " \
          "ip netns del klp_prens0 >/dev/null 2>&1 || true; " \
          "ip xfrm policy delete " \
          "src 198.19.0.1/32 dst 198.19.0.2/32 dir out " \
          ">/dev/null 2>&1 || true"
        )
      end

      def self.cleanup_fuse_workloads(machine)
        machine.execute(
          "for name in transition resend abort close replacement; do " \
          "state=#{FUSE_STATE}/$name; " \
          "if test -s \"$state/connection\"; then " \
          "connection=$(cat \"$state/connection\"); " \
          "abort=/sys/fs/fuse/connections/$connection/abort; " \
          "test -e \"$abort\" && echo 1 > \"$abort\" 2>/dev/null || true; " \
          "fi; " \
          "if test -s \"$state/pid\"; then " \
          "pid=$(cat \"$state/pid\"); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "fi; " \
          "umount -l \"$state/mnt\" >/dev/null 2>&1 || true; " \
          "done"
        )
      end

      def self.start_fuse_helper(machine, name, mode, finish = nil)
        state = "#{FUSE_STATE}/#{name}"
        command = "#{FUSE_TRANSITION} #{mode} #{state}/mnt #{state}"
        command += " #{finish}" if finish

        machine.succeeds(
          "rm -rf #{state}; " \
          "mkdir -p #{state}; " \
          "#{command} >#{state}/output.log 2>&1 & " \
          "echo $! > #{state}/pid"
        )
        state
      end

      def self.cleanup_example_state(machine)
        machine.execute(
          "test -e /sys/module/livepatch_test_pernet_hold/parameters/hold && " \
          "echo 0 > /sys/module/livepatch_test_pernet_hold/parameters/hold " \
          "2>/dev/null || true; " \
          "for parameter in probe_hold probe_spin_hold probe_clone_arg2 " \
          "probe_match_arg0 " \
          "probe_address probe2_address probe3_address shadow_failures; do " \
          "path=#{PROBE_PARAMETERS}/$parameter; " \
          "test -e \"$path\" && echo 0 > \"$path\" 2>/dev/null || true; " \
          "done"
        )

        [
          :stop_stress,
          :stop_bpf_churn,
          :cleanup_transition_state,
          :cleanup_ipset_dump,
          :cleanup_tcp_workload,
          :cleanup_sunrpc_workload,
          :cleanup_nft_batch_workload,
          :cleanup_multicast_workload,
          :cleanup_vsock_workload,
          :cleanup_xfrm_workload,
          :cleanup_nfs_workload,
          :cleanup_bridge_workload,
          :cleanup_fragment_workload,
          :cleanup_ipvs_workload,
          :cleanup_nfqueue_workload,
          :cleanup_fuse_workloads,
        ].each do |cleanup|
          begin
            public_send(cleanup, machine)
          rescue StandardError => e
            warn "best-effort #{cleanup} failed: #{e.class}: #{e.message}"
          end
        end

        machine.execute(
          "for name in #{CORRECTED_NAME} #{RELEASED_V1_NAME} #{PREDECESSOR_NAME}; do " \
          "dir=/sys/kernel/livepatch/$name; " \
          "if test -e \"$dir/enabled\"; then " \
          "echo 0 > \"$dir/enabled\" 2>/dev/null || true; " \
          "attempt=0; " \
          "while test $attempt -lt 300; do " \
          "test ! -e \"$dir/transition\" && break; " \
          "test \"$(cat \"$dir/transition\" 2>/dev/null)\" = 0 && break; " \
          "attempt=$((attempt + 1)); sleep 0.1; " \
          "done; " \
          "fi; " \
          "rmmod \"$name\" >/dev/null 2>&1 || true; " \
          "done"
        )

        machine.execute(
          "for module in fuse nfsv4 nf_tables nfnetlink_queue nft_queue " \
          "#{IPSET_HASH_OBJECTS.join(' ')} ip_vs bridge " \
          "nf_conntrack_bridge br_netfilter vsock_loopback " \
          "xfrm_user; do " \
          "modprobe \"$module\" >/dev/null 2>&1 || true; " \
          "done"
        )
      end

      def self.cleanup_ipset_dump(machine)
        machine.execute(
          "for pidfile in #{IPSET_DUMP_STATE}/*.pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "ipset destroy >/dev/null 2>&1 || true; " \
          "rm -f #{IPSET_DUMP_STATE}/fifo"
        )
      end

      def self.cleanup_tcp_workload(machine)
        machine.execute(
          "for pidfile in #{TCP_STATE}/*.pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "ip netns del klp_tcp_a >/dev/null 2>&1 || true; " \
          "ip netns del klp_tcp_b >/dev/null 2>&1 || true"
        )
      end

      def self.cleanup_sunrpc_workload(machine)
        machine.execute(
          "for pidfile in #{SUNRPC_STATE}/*/pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill -KILL -- \"-$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "for target in #{SUNRPC_STATE}/*/mnt; do " \
          "mountpoint -q \"$target\" || continue; " \
          "umount -l \"$target\" >/dev/null 2>&1 || true; " \
          "done; " \
          "rm -rf #{SUNRPC_STATE}"
        )
      end

      def self.cleanup_nft_batch_workload(machine)
        machine.execute(
          "for pidfile in #{NFT_BATCH_STATE}/*.pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "nft delete table inet klp_batch >/dev/null 2>&1 || true; " \
          "rm -rf #{NFT_BATCH_STATE}"
        )
      end

      def self.start_sunrpc_tls_mount(
        machine,
        label,
        extra_options = nil,
        timeo: 5
      )
        state = "#{SUNRPC_STATE}/#{label}"
        options = "vers=4.2,proto=tcp,xprtsec=tls,nosharecache," \
                  "soft,timeo=#{timeo},retrans=1,retry=0"
        options += ",#{extra_options}" unless extra_options.nil?
        machine.succeeds(
          "mkdir -p #{state}/mnt; " \
          "rm -f #{state}/pid #{state}/status #{state}/output.log; " \
          "setsid sh -c 'mount -t nfs " \
          "-o #{options} " \
          "127.0.0.1:/ #{state}/mnt; " \
          "printf \"%s\\n\" \"$?\" > #{state}/status' " \
          ">#{state}/output.log 2>&1 & " \
          "echo $! > #{state}/pid"
        )
      end

      def self.wait_for_sunrpc_tls_failure(machine, label)
        state = "#{SUNRPC_STATE}/#{label}"
        machine.wait_until_succeeds(
          "test -s #{state}/status",
          timeout: 60
        )
        machine.succeeds("test \"$(cat #{state}/status)\" -ne 0")
      end

      def self.signal_sunrpc_tls_mount(machine, label)
        state = "#{SUNRPC_STATE}/#{label}"
        machine.succeeds(
          "pid=$(cat #{state}/pid); " \
          "kill -KILL -- \"-$pid\" 2>/dev/null || true"
        )
      end

      def self.wait_for_sunrpc_tls_mount_exit(machine, label)
        state = "#{SUNRPC_STATE}/#{label}"
        machine.wait_until_succeeds(
          "pgrp=$(cat #{state}/pid); live=0; " \
          "for stat in /proc/[0-9]*/stat; do " \
          "line=$(cat \"$stat\" 2>/dev/null) || continue; " \
          "rest=''${line##*) }; set -- $rest; " \
          "test \"$3\" = \"$pgrp\" || continue; " \
          "test \"$1\" = Z && continue; " \
          "live=1; break; " \
          "done; test \"$live\" = 0",
          timeout: 30
        )
      end

      def self.kill_sunrpc_tls_mount(machine, label)
        signal_sunrpc_tls_mount(machine, label)
        wait_for_sunrpc_tls_mount_exit(machine, label)
      end

      def self.cleanup_multicast_workload(machine)
        machine.execute(
          "for pidfile in #{MULTICAST_STATE}/*.pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "ip link del klp_mc_peer >/dev/null 2>&1 || true; " \
          "ip netns del klp_mc >/dev/null 2>&1 || true"
        )
      end

      def self.cleanup_vsock_workload(machine)
        machine.execute(
          "if test -s #{VSOCK_STATE}/pid; then " \
          "pid=$(cat #{VSOCK_STATE}/pid); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "fi; " \
          "rm -rf #{VSOCK_STATE}"
        )
      end

      def self.start_vsock_workload(machine, port)
        cleanup_vsock_workload(machine)
        machine.succeeds(
          "mkdir -p #{VSOCK_STATE}; " \
          "#{VSOCK_FIXED_ZEROCOPY} #{port} " \
          "#{VSOCK_STATE}/ready #{VSOCK_STATE}/release " \
          "#{VSOCK_STATE}/result >#{VSOCK_STATE}/output.log 2>&1 & " \
          "echo $! > #{VSOCK_STATE}/pid"
        )
        machine.wait_until_succeeds(
          "test -e #{VSOCK_STATE}/ready",
          timeout: 60
        )
      end

      def self.release_vsock_workload(machine)
        machine.succeeds("touch #{VSOCK_STATE}/release")
        machine.wait_until_succeeds(
          "! kill -0 \"$(cat #{VSOCK_STATE}/pid)\" 2>/dev/null",
          timeout: 60
        )
        machine.succeeds(
          "test \"$(cat #{VSOCK_STATE}/result)\" = 262144"
        )
      end

      def self.cleanup_xfrm_workload(machine)
        machine.execute(
          "ip netns del klp_xfrm_a >/dev/null 2>&1 || true; " \
          "ip netns del klp_xfrm_b >/dev/null 2>&1 || true; " \
          "rm -rf #{XFRM_STATE}"
        )
      end

      def self.cleanup_nfs_workload(machine)
        machine.execute(
          "for pidfile in #{NFS_STATE}/*/pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill -KILL -- \"-$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "mountpoint -q #{NFS_STATE}/mnt && " \
          "umount -l #{NFS_STATE}/mnt >/dev/null 2>&1 || true; " \
          "rm -rf #{NFS_STATE}; " \
          "rm -f /tmp/klp-nfs-lock"
        )
      end

      def self.prepare_nfs_workload(machine)
        cleanup_nfs_workload(machine)
        machine.all_succeed(
          "mkdir -p #{NFS_STATE}/mnt",
          "touch /tmp/klp-nfs-lock",
          "mount -t nfs -o vers=4.2,proto=tcp,nosharecache " \
          "127.0.0.1:/ #{NFS_STATE}/mnt"
        )
      end

      def self.start_nfs_lock_holder(machine, label)
        state = "#{NFS_STATE}/#{label}"
        machine.succeeds(
          "mkdir -p #{state}; " \
          "rm -f #{state}/acquired #{state}/release; " \
          "setsid sh -ec 'exec 9>#{NFS_STATE}/mnt/klp-nfs-lock; " \
          "flock -x 9; touch #{state}/acquired; " \
          "while ! test -e #{state}/release; do sleep 0.01; done; " \
          "flock -u 9' " \
          ">#{state}/output.log 2>&1 & " \
          "echo $! > #{state}/pid"
        )
        state
      end

      def self.wait_for_nfs_lock(machine, state)
        machine.wait_until_succeeds(
          "test -e #{state}/acquired",
          timeout: 60
        )
      end

      def self.release_nfs_lock(machine, state)
        machine.succeeds("touch #{state}/release")
        machine.wait_until_succeeds(
          "! kill -0 \"$(cat #{state}/pid)\" 2>/dev/null",
          timeout: 60
        )
      end

      def self.add_xfrm_states(machine)
        auth_key =
          "0x00112233445566778899aabbccddeeff" \
          "00112233445566778899aabbccddeeff"
        enc_key = "0x00112233445566778899aabbccddeeff"

        %w[klp_xfrm_a klp_xfrm_b].each do |namespace|
          machine.all_succeed(
            "ip netns exec #{namespace} ip xfrm state add " \
            "src 10.23.0.1 dst 10.23.0.2 proto esp spi 0x100 " \
            "mode transport auth-trunc 'hmac(sha256)' #{auth_key} 128 " \
            "enc 'cbc(aes)' #{enc_key}",
            "ip netns exec #{namespace} ip xfrm state add " \
            "src 10.23.0.2 dst 10.23.0.1 proto esp spi 0x200 " \
            "mode transport auth-trunc 'hmac(sha256)' #{auth_key} 128 " \
            "enc 'cbc(aes)' #{enc_key}"
          )
        end
      end

      def self.prepare_xfrm_workload(machine)
        cleanup_xfrm_workload(machine)
        machine.all_succeed(
          "mkdir -p #{XFRM_STATE}",
          "ip netns add klp_xfrm_a",
          "ip netns add klp_xfrm_b",
          "ip link add xa0 type veth peer name xb0",
          "ip link set xa0 netns klp_xfrm_a",
          "ip link set xb0 netns klp_xfrm_b",
          "ip -net klp_xfrm_a addr add 10.23.0.1/24 dev xa0",
          "ip -net klp_xfrm_b addr add 10.23.0.2/24 dev xb0",
          "ip -net klp_xfrm_a link set lo up",
          "ip -net klp_xfrm_b link set lo up",
          "ip -net klp_xfrm_a link set xa0 up",
          "ip -net klp_xfrm_b link set xb0 up"
        )
        add_xfrm_states(machine)
        machine.all_succeed(
          "ip netns exec klp_xfrm_a ip xfrm policy add " \
          "dir out src 10.23.0.1 dst 10.23.0.2 " \
          "tmpl src 10.23.0.1 dst 10.23.0.2 proto esp " \
          "spi 0x100 mode transport level required",
          "ip netns exec klp_xfrm_a ip xfrm policy add " \
          "dir in src 10.23.0.2 dst 10.23.0.1 " \
          "tmpl src 10.23.0.2 dst 10.23.0.1 proto esp " \
          "spi 0x200 mode transport level required",
          "ip netns exec klp_xfrm_b ip xfrm policy add " \
          "dir in src 10.23.0.1 dst 10.23.0.2 " \
          "tmpl src 10.23.0.1 dst 10.23.0.2 proto esp " \
          "spi 0x100 mode transport level required",
          "ip netns exec klp_xfrm_b ip xfrm policy add " \
          "dir out src 10.23.0.2 dst 10.23.0.1 " \
          "tmpl src 10.23.0.2 dst 10.23.0.1 proto esp " \
          "spi 0x200 mode transport level required",
          "ip netns exec klp_xfrm_a ping -c 8 -W 2 10.23.0.2"
        )
      end

      def self.start_multicast_holder(machine, group)
        machine.succeeds(
          "ip netns exec klp_mc #{MULTICAST_HOLD} mc0 #{group} " \
          "#{MULTICAST_STATE}/#{group}.ready " \
          "#{MULTICAST_STATE}/stop " \
          ">#{MULTICAST_STATE}/#{group}.log 2>&1 & " \
          "echo $! > #{MULTICAST_STATE}/#{group}.pid"
        )
        machine.wait_until_succeeds(
          "test -e #{MULTICAST_STATE}/#{group}.ready",
          timeout: 30
        )
      end

      def self.prepare_multicast_workload(machine)
        cleanup_multicast_workload(machine)
        machine.all_succeed(
          "mkdir -p #{MULTICAST_STATE}",
          "rm -f #{MULTICAST_STATE}/*",
          "ip netns add klp_mc",
          "ip link add klp_mc_peer type veth peer name mc0 netns klp_mc",
          "ip link set klp_mc_peer up",
          "ip -net klp_mc addr add 192.0.2.1/24 dev mc0",
          "ip -net klp_mc addr add 2001:db8:2::1/64 dev mc0",
          "ip -net klp_mc link set lo up",
          "ip -net klp_mc link set mc0 up"
        )
        start_multicast_holder(machine, 1)
      end

      def self.stop_multicast_holders(machine)
        machine.succeeds("touch #{MULTICAST_STATE}/stop")
        [1, 2, 3].each do |group|
          next unless machine.execute(
            "test -s #{MULTICAST_STATE}/#{group}.pid"
          )[0] == 0

          machine.wait_until_succeeds(
            "! kill -0 \"$(cat #{MULTICAST_STATE}/#{group}.pid)\" " \
            "2>/dev/null",
            timeout: 30
          )
        end
      end

      def self.cleanup_bridge_workload(machine)
        machine.execute(
          "ip link del klp_stp_br0 >/dev/null 2>&1 || true; " \
          "ip link del klp_stp_br1 >/dev/null 2>&1 || true; " \
          "ip link del klp_stp_p0 >/dev/null 2>&1 || true"
        )
      end

      def self.prepare_bridge_workload(machine)
        cleanup_bridge_workload(machine)
        machine.all_succeed(
          "mkdir -p #{BRIDGE_STATE}",
          "ip link add klp_stp_br0 type bridge",
          "ip link add klp_stp_br1 type bridge",
          "ip link set klp_stp_br0 type bridge stp_state 1 priority 0 " \
          "forward_delay 200 hello_time 100 max_age 600",
          "ip link set klp_stp_br1 type bridge stp_state 1 priority 32768 " \
          "forward_delay 200 hello_time 100 max_age 600",
          "ip link add klp_stp_p0 type veth peer name klp_stp_p1",
          "ip link set klp_stp_p0 master klp_stp_br0",
          "ip link set klp_stp_p1 master klp_stp_br1",
          "ip link set klp_stp_br0 up",
          "ip link set klp_stp_br1 up",
          "ip link set klp_stp_p0 up",
          "ip link set klp_stp_p1 up",
          "sleep 7",
          "ip link set klp_stp_p1 down",
          "sleep 1",
          "ip link set klp_stp_br1 down"
        )
      end

      def self.cleanup_fragment_workload(machine)
        machine.execute(
          "nft delete table bridge klp_frag >/dev/null 2>&1 || true; " \
          "for pidfile in #{FRAGMENT_STATE}/*.pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "ip link del klp_frag_br >/dev/null 2>&1 || true; " \
          "ip netns del klp_frag_a >/dev/null 2>&1 || true; " \
          "ip netns del klp_frag_b >/dev/null 2>&1 || true; " \
          "ip netns del klp_frag_c >/dev/null 2>&1 || true"
        )
      end

      def self.prepare_fragment_workload(machine)
        cleanup_fragment_workload(machine)
        machine.all_succeed(
          "mkdir -p #{FRAGMENT_STATE}",
          "rm -f #{FRAGMENT_STATE}/*",
          "ip netns add klp_frag_a",
          "ip netns add klp_frag_b",
          "ip netns add klp_frag_c",
          "ip link add klp_frag_a0 type veth peer name eth0 " \
          "netns klp_frag_a",
          "ip link add klp_frag_b0 type veth peer name eth0 " \
          "netns klp_frag_b",
          "ip link add klp_frag_c0 type veth peer name eth0 " \
          "netns klp_frag_c",
          "ip link add klp_frag_br type bridge",
          # Bridge ports are linked at the head. Enslave a, c, then b so
          # unknown unicast traverses b first (a cloned flood skb), c second
          # (the original skb), and skips the ingress port a.
          "ip link set klp_frag_a0 master klp_frag_br",
          "ip link set klp_frag_c0 master klp_frag_br",
          "ip link set klp_frag_b0 master klp_frag_br",
          # nf_conntrack_bridge records frag_max_size only when it reassembles
          # real input fragments.  br_ip6_fragment() deliberately rejects a
          # zero value, so the sender-side link must fragment the datagram
          # before it enters the bridge.
          "ip link set klp_frag_a0 mtu 1280",
          "ip link set klp_frag_b0 mtu 1280",
          "ip link set klp_frag_c0 mtu 1280",
          "ip link set klp_frag_a0 up",
          "ip link set klp_frag_b0 up",
          "ip link set klp_frag_c0 up",
          "ip link set klp_frag_br up",
          "ip -net klp_frag_a link set lo up",
          "ip -net klp_frag_b link set lo up",
          "ip -net klp_frag_c link set lo up",
          "ip -net klp_frag_a link set eth0 mtu 1280",
          "ip -net klp_frag_b link set eth0 mtu 1280",
          "ip -net klp_frag_c link set eth0 mtu 1280",
          "ip -net klp_frag_a addr add 2001:db8:3::1/64 dev eth0 nodad",
          "ip -net klp_frag_b addr add 2001:db8:3::2/64 dev eth0 nodad",
          "ip -net klp_frag_a link set eth0 up",
          "ip -net klp_frag_b link set eth0 up",
          "ip -net klp_frag_c link set eth0 up",
          "modprobe nf_conntrack_bridge",
          "modprobe nft_ct",
          # br_netfilter and bridge conntrack both register postrouting at
          # INT_MAX.  br_netfilter is registered first when the bridge is
          # created; enabling its IPv6 handoff therefore steals the skb and
          # uses br_nf_dev_queue_xmit() fragmentation before bridge conntrack
          # can reach nf_ct_bridge_post() and nf_br_ip6_fragment().
          "sysctl -qw net.bridge.bridge-nf-call-ip6tables=0",
          # Loading nf_conntrack_bridge only publishes its hook table.  A
          # bridge-family conntrack expression acquires the per-netns bridge
          # conntrack user and registers the defrag/refrag hooks.
          "nft add table bridge klp_frag",
          "nft 'add chain bridge klp_frag prerouting " \
          "{ type filter hook prerouting priority 0; policy accept; }'",
          "nft 'add rule bridge klp_frag prerouting ct state new counter'"
        )
        machine.succeeds(
          "ip netns exec klp_frag_b socat -u " \
          "UDP6-RECVFROM:9004,reuseaddr CREATE:#{FRAGMENT_STATE}/payload " \
          ">#{FRAGMENT_STATE}/server.log 2>&1 & " \
          "echo $! > #{FRAGMENT_STATE}/server.pid"
        )
        machine.wait_until_succeeds(
          "ip netns exec klp_frag_b ss -lun | " \
          "grep -Eq ':9004[[:space:]]'",
          timeout: 30
        )
        machine.wait_until_succeeds(
          "ip netns exec klp_frag_a ping -6 -c 1 -W 2 2001:db8:3::2",
          timeout: 30
        )
        machine.succeeds(
          "dest_mac=$(ip netns exec klp_frag_b " \
          "cat /sys/class/net/eth0/address); " \
          "bridge fdb del \"$dest_mac\" dev klp_frag_b0 master"
        )
      end

      def self.cleanup_ipvs_workload(machine)
        machine.execute(
          "iptables -w -D nixos-fw -i klp_ipvs_host -m mark --mark 1 " \
          "-j nixos-fw-accept >/dev/null 2>&1 || true; " \
          "iptables -w -t mangle -D nixos-fw-rpfilter " \
          "-i klp_ipvs_host -j RETURN >/dev/null 2>&1 || true; " \
          "ipvsadm -C >/dev/null 2>&1 || true; " \
          "nft delete table ip klp_ipvs >/dev/null 2>&1 || true; " \
          "ip rule del priority 100 fwmark 1 lookup 100 " \
          ">/dev/null 2>&1 || true; " \
          "ip route del local 0.0.0.0/0 dev lo table 100 " \
          ">/dev/null 2>&1 || true; " \
          "ip link del klp_ipvs_out >/dev/null 2>&1 || true; " \
          "ip link del klp_ipvs_host >/dev/null 2>&1 || true; " \
          "ip netns del klp_ipvs_client >/dev/null 2>&1 || true"
        )
      end

      def self.prepare_ipvs_workload(machine)
        cleanup_ipvs_workload(machine)
        machine.all_succeed(
          "mkdir -p #{IPVS_STATE}",
          "ip netns add klp_ipvs_client",
          "ip link add klp_ipvs_host type veth peer name eth0 " \
          "netns klp_ipvs_client",
          "ip link add klp_ipvs_out type dummy",
          "ip addr add 192.0.2.1/24 dev klp_ipvs_host",
          "ip addr add 198.51.100.1/24 dev klp_ipvs_out",
          "ip link set klp_ipvs_host up",
          "ip link set klp_ipvs_out up",
          "ip -net klp_ipvs_client addr add 192.0.2.2/24 dev eth0",
          "ip -net klp_ipvs_client link set lo up",
          "ip -net klp_ipvs_client link set eth0 up",
          "ip -net klp_ipvs_client route add default via 192.0.2.1",
          "ip rule add priority 100 fwmark 1 lookup 100",
          "ip route add local 0.0.0.0/0 dev lo table 100",
          "sysctl -qw net.ipv4.ip_forward=1",
          "sysctl -qw net.ipv4.vs.cache_bypass=1",
          "ipvsadm -A -f 1 -s rr",
          "nft add table ip klp_ipvs",
          "nft 'add chain ip klp_ipvs prerouting " \
          "{ type filter hook prerouting priority mangle; policy accept; }'",
          "nft 'add rule ip klp_ipvs prerouting " \
          "iifname \"klp_ipvs_host\" udp dport 9003 " \
          "meta mark set 1 counter'",
          "iptables -w -t mangle -I nixos-fw-rpfilter 1 " \
          "-i klp_ipvs_host -j RETURN",
          "iptables -w -I nixos-fw 1 -i klp_ipvs_host " \
          "-m mark --mark 1 -j nixos-fw-accept"
        )
      end

      def self.prepare_legacy_tcp_socket(machine)
        cleanup_tcp_workload(machine)
        machine.all_succeed(
          "mkdir -p #{TCP_STATE}",
          "rm -f #{TCP_STATE}/*",
          "ip netns add klp_tcp_a",
          "ip netns add klp_tcp_b",
          "ip link add klp_tcp_a0 type veth peer name klp_tcp_b0",
          "ip link set klp_tcp_a0 netns klp_tcp_a",
          "ip link set klp_tcp_b0 netns klp_tcp_b",
          "ip -net klp_tcp_a addr add 198.51.100.1/24 dev klp_tcp_a0",
          "ip -net klp_tcp_b addr add 198.51.100.2/24 dev klp_tcp_b0",
          "ip -net klp_tcp_a link set lo up",
          "ip -net klp_tcp_b link set lo up",
          "ip -net klp_tcp_a link set klp_tcp_a0 up",
          "ip -net klp_tcp_b link set klp_tcp_b0 up",
          "ip netns exec klp_tcp_a sysctl -qw net.ipv4.tcp_reordering=-1",
          "ip netns exec klp_tcp_a sysctl -qw net.ipv4.tcp_mtu_probing=2",
          "ip netns exec klp_tcp_a sysctl -qw net.ipv4.tcp_base_mss=512"
        )
        machine.succeeds(
          "ip netns exec klp_tcp_b socat -u " \
          "TCP-LISTEN:9002,reuseaddr OPEN:/dev/null,wronly " \
          ">#{TCP_STATE}/server.log 2>&1 & " \
          "echo $! > #{TCP_STATE}/server.pid"
        )
        machine.wait_until_succeeds(
          "ip netns exec klp_tcp_b ss -ltn | grep -q ':9002'",
          timeout: 30
        )
        machine.succeeds(
          "ip netns exec klp_tcp_a #{TCP_LEGACY_SOCKET} " \
          "198.51.100.2 9002 #{TCP_STATE}/ready #{TCP_STATE}/release " \
          "#{TCP_STATE}/result >#{TCP_STATE}/client.log 2>&1 & " \
          "echo $! > #{TCP_STATE}/client.pid"
        )
        machine.wait_until_succeeds(
          "test -e #{TCP_STATE}/ready",
          timeout: 30
        )
      end

      def self.release_legacy_tcp_socket(machine)
        machine.succeeds("touch #{TCP_STATE}/release")
        machine.wait_until_succeeds(
          "! kill -0 \"$(cat #{TCP_STATE}/client.pid)\" 2>/dev/null",
          timeout: 60
        )
        machine.succeeds("test \"$(cat #{TCP_STATE}/result)\" = 8388608")
      end

      def self.prepare_held_ipset_dump(machine)
        cleanup_ipset_dump(machine)
        machine.all_succeed(
          "mkdir -p #{IPSET_DUMP_STATE}",
          "rm -f #{IPSET_DUMP_STATE}/*",
          "awk 'BEGIN { " \
          "print \"create klp_dump hash:ip\"; " \
          "for (i = 1; i <= 8192; i++) " \
          "printf \"add klp_dump 198.51.%d.%d\\n\", " \
          "int((i - 1) / 254), ((i - 1) % 254) + 1; " \
          "}' | ipset restore",
          "mkfifo #{IPSET_DUMP_STATE}/fifo"
        )
        # A background process which retains the test command channel makes
        # machine.succeeds() wait for it.  Detach both jobs while deliberately
        # leaving the ipset writer blocked on the unread FIFO.
        machine.succeeds(
          "sleep 300 < #{IPSET_DUMP_STATE}/fifo >/dev/null 2>&1 & " \
          "echo $! > #{IPSET_DUMP_STATE}/reader.pid; " \
          "ipset list klp_dump > #{IPSET_DUMP_STATE}/fifo " \
          "2>#{IPSET_DUMP_STATE}/dump.log </dev/null & " \
          "echo $! > #{IPSET_DUMP_STATE}/dump.pid"
        )
        machine.wait_until_succeeds(
          "test -d /proc/$(cat #{IPSET_DUMP_STATE}/dump.pid) && " \
          "grep -Eq 'pipe_(write|wait)' " \
          "/proc/$(cat #{IPSET_DUMP_STATE}/dump.pid)/wchan",
          timeout: 60
        )
      end

      def self.grow_ipset_list_across_dump_release(machine)
        machine.succeeds(
          "rm -f #{IPSET_DUMP_STATE}/growth.done; " \
          "(for i in $(seq 0 350); do " \
          "ipset create \"klp_g_$i\" hash:ip || exit; " \
          "done; touch #{IPSET_DUMP_STATE}/growth.done) " \
          ">#{IPSET_DUMP_STATE}/growth.log 2>&1 & " \
          "echo $! > #{IPSET_DUMP_STATE}/growth.pid"
        )
        machine.wait_until_succeeds(
          "test \"$(ipset list -n | wc -l)\" -ge 250",
          timeout: 60
        )
        machine.succeeds(
          "kill \"$(cat #{IPSET_DUMP_STATE}/dump.pid)\"; " \
          "rm -f #{IPSET_DUMP_STATE}/dump.pid"
        )
        machine.wait_until_succeeds(
          "test -e #{IPSET_DUMP_STATE}/growth.done",
          timeout: 60
        )
        machine.succeeds("ipset test klp_dump 198.51.0.1")
      end

      def self.prepare_transition_state(machine)
        cleanup_transition_state(machine)
        machine.all_succeed(
          "ip link add klp_prebr0 type bridge",
          "ip link set klp_prebr0 type bridge stp_state 1",
          "ip link set klp_prebr0 up",
          "ip netns add klp_prens0",
          "ip netns exec klp_prens0 ip link set lo up",
          "ipset create klp_pre_ip hash:ip timeout 300",
          "ipset add klp_pre_ip 192.0.2.129",
          "nft add table inet klp_pre",
          "nft 'add set inet klp_pre endpoints " \
          "{ type ipv4_addr . inet_service; flags interval; }'",
          "nft 'add element inet klp_pre endpoints " \
          "{ 127.0.0.1 . 1000-1001 }'",
          "ip xfrm policy add " \
          "src 198.19.0.1/32 dst 198.19.0.2/32 dir out " \
          "priority 12346 action block"
        )
      end

      def self.consume_transition_state(machine)
        machine.all_succeed(
          "ipset test klp_pre_ip 192.0.2.129",
          "nft list set inet klp_pre endpoints",
          "ip link set klp_prebr0 down",
          "ip link del klp_prebr0",
          "ip netns del klp_prens0",
          "ipset destroy klp_pre_ip",
          "nft delete table inet klp_pre",
          "ip xfrm policy delete " \
          "src 198.19.0.1/32 dst 198.19.0.2/32 dir out"
        )
      end

      def self.cleanup_nfqueue_workload(machine)
        machine.execute(
          "iptables -w -t mangle -D nixos-fw-rpfilter " \
          "-i klp_nfq_br -j RETURN >/dev/null 2>&1 || true; " \
          "ip6tables -w -t mangle -D nixos-fw-rpfilter " \
          "-i klp_nfq_br -j RETURN >/dev/null 2>&1 || true; " \
          "for pidfile in #{NFQUEUE_STATE}/*.pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); " \
          "kill \"$pid\" >/dev/null 2>&1 || true; " \
          "done; " \
          "for pidfile in #{NFQUEUE_STATE}/*.pid; do " \
          "test -s \"$pidfile\" || continue; " \
          "pid=$(cat \"$pidfile\"); attempt=0; " \
          "while kill -0 \"$pid\" >/dev/null 2>&1 && " \
          "test \"$attempt\" -lt 100; do " \
          "attempt=$((attempt + 1)); sleep 0.1; " \
          "done; " \
          "done; " \
          "nft delete table bridge klp_nfq >/dev/null 2>&1 || true; " \
          "ip link del klp_nfq_br >/dev/null 2>&1 || true; " \
          "ip link del klp_nfq_a0 >/dev/null 2>&1 || true; " \
          "ip link del klp_nfq_b0 >/dev/null 2>&1 || true; " \
          "ip netns del klp_nfq_a >/dev/null 2>&1 || true; " \
          "ip netns del klp_nfq_b >/dev/null 2>&1 || true"
        )
      end

      def self.prepare_nfqueue_workload(machine)
        cleanup_nfqueue_workload(machine)
        machine.all_succeed(
          "mkdir -p #{NFQUEUE_STATE}",
          "rm -f #{NFQUEUE_STATE}/*",
          "ip netns add klp_nfq_a",
          "ip netns add klp_nfq_b",
          "ip link add klp_nfq_a0 type veth peer name eth0 netns klp_nfq_a",
          "ip link add klp_nfq_b0 type veth peer name eth0 netns klp_nfq_b",
          "ip link add klp_nfq_br type bridge",
          "ip link set klp_nfq_a0 master klp_nfq_br",
          "ip link set klp_nfq_b0 master klp_nfq_br",
          "ip link set klp_nfq_a0 up",
          "ip link set klp_nfq_b0 up",
          "ip link set klp_nfq_br up",
          "ip -net klp_nfq_a addr add 192.0.2.1/24 dev eth0",
          "ip -net klp_nfq_b addr add 192.0.2.2/24 dev eth0",
          "ip -net klp_nfq_a addr add 2001:db8:1::1/64 dev eth0",
          "ip -net klp_nfq_b addr add 2001:db8:1::2/64 dev eth0",
          "ip -net klp_nfq_a link set lo up",
          "ip -net klp_nfq_b link set lo up",
          "ip -net klp_nfq_a link set eth0 up",
          "ip -net klp_nfq_b link set eth0 up",
          "modprobe nf_conntrack_bridge",
          "sysctl -qw net.bridge.bridge-nf-call-iptables=1",
          "sysctl -qw net.bridge.bridge-nf-call-ip6tables=1",
          "iptables -w -t mangle -I nixos-fw-rpfilter 1 " \
          "-i klp_nfq_br -j RETURN",
          "ip6tables -w -t mangle -I nixos-fw-rpfilter 1 " \
          "-i klp_nfq_br -j RETURN",
        )
        machine.wait_until_succeeds(
          "ip netns exec klp_nfq_a ping -c 1 -W 2 192.0.2.2",
          timeout: 30
        )
        machine.wait_until_succeeds(
          "ip netns exec klp_nfq_a ping -6 -c 1 -W 2 2001:db8:1::2",
          timeout: 30
        )
        machine.all_succeed(
          "nft add table bridge klp_nfq",
          "nft 'add chain bridge klp_nfq forward " \
          "{ type filter hook forward priority 0; policy accept; }'",
          "nft 'add rule bridge klp_nfq forward " \
          "ether type ip ip protocol icmp queue num 40'",
          "nft 'add rule bridge klp_nfq forward " \
          "ether type ip6 ip6 nexthdr 58 queue num 41'",
          "nft 'add rule bridge klp_nfq forward " \
          "ether type ip ip protocol tcp tcp dport 9000 " \
          "ip length > 1500 queue num 42'",
        )

        [ [ 4, 40 ], [ 6, 41 ], [ 4, 42 ] ].each do |family, queue|
          machine.succeeds(
            "#{NFQUEUE_HOLD} #{family} #{queue} " \
            "#{NFQUEUE_STATE}/#{queue}.ready " \
            "#{NFQUEUE_STATE}/#{queue}.release " \
            ">#{NFQUEUE_STATE}/#{queue}.log 2>&1 & " \
            "echo $! > #{NFQUEUE_STATE}/#{queue}.pid"
          )
          machine.wait_until_succeeds(
            "grep -Eq '^[[:space:]]*#{queue}[[:space:]]' " \
            "/proc/net/netfilter/nfnetlink_queue",
            timeout: 30
          )
        end

        machine.succeeds(
          "ip netns exec klp_nfq_b socat -u " \
          "TCP-LISTEN:9000,reuseaddr OPEN:/dev/null,wronly " \
          ">#{NFQUEUE_STATE}/server.log 2>&1 & " \
          "echo $! > #{NFQUEUE_STATE}/server.pid"
        )
        machine.succeeds(
          "ip netns exec klp_nfq_a ping -c 1 -W 30 192.0.2.2 " \
          ">#{NFQUEUE_STATE}/ping4.log 2>&1 & " \
          "echo $! > #{NFQUEUE_STATE}/ping4.pid"
        )
        machine.succeeds(
          "ip netns exec klp_nfq_a ping -6 -c 1 -W 30 2001:db8:1::2 " \
          ">#{NFQUEUE_STATE}/ping6.log 2>&1 & " \
          "echo $! > #{NFQUEUE_STATE}/ping6.pid"
        )
        machine.succeeds(
          "(dd if=/dev/zero bs=1048576 count=8 status=none | " \
          "ip netns exec klp_nfq_a socat -u STDIN TCP:192.0.2.2:9000) " \
          ">#{NFQUEUE_STATE}/client.log 2>&1 </dev/null & " \
          "echo $! > #{NFQUEUE_STATE}/client.pid"
        )

        [ 40, 41, 42 ].each do |queue|
          machine.wait_until_succeeds(
            "test -s #{NFQUEUE_STATE}/#{queue}.ready",
            timeout: 60
          )
        end
        machine.succeeds("grep -Fx gso=1 #{NFQUEUE_STATE}/42.ready")
      end

      def self.release_nfqueue_workload(machine)
        machine.succeeds(
          "touch #{NFQUEUE_STATE}/40.release " \
          "#{NFQUEUE_STATE}/41.release #{NFQUEUE_STATE}/42.release"
        )
        [ 40, 41, 42 ].each do |queue|
          machine.wait_until_succeeds(
            "! kill -0 \"$(cat #{NFQUEUE_STATE}/#{queue}.pid)\" 2>/dev/null",
            timeout: 30
          )
        end
      end

      def self.exercise_nfqueue_shadow_failure(machine)
        cleanup_nfqueue_workload(machine)
        machine.all_succeed(
          "mkdir -p #{NFQUEUE_STATE}",
          "rm -f #{NFQUEUE_STATE}/*",
          "ip netns add klp_nfq_a",
          "ip netns add klp_nfq_b",
          "ip link add klp_nfq_a0 type veth peer name eth0 netns klp_nfq_a",
          "ip link add klp_nfq_b0 type veth peer name eth0 netns klp_nfq_b",
          "ip link add klp_nfq_br type bridge",
          "ip link set klp_nfq_a0 master klp_nfq_br",
          "ip link set klp_nfq_b0 master klp_nfq_br",
          "ip link set klp_nfq_a0 up",
          "ip link set klp_nfq_b0 up",
          "ip link set klp_nfq_br up",
          "ip -net klp_nfq_a addr add 192.0.2.1/24 dev eth0",
          "ip -net klp_nfq_b addr add 192.0.2.2/24 dev eth0",
          "ip -net klp_nfq_a link set lo up",
          "ip -net klp_nfq_b link set lo up",
          "ip -net klp_nfq_a link set eth0 up",
          "ip -net klp_nfq_b link set eth0 up",
          "modprobe nf_conntrack_bridge",
          "sysctl -qw net.bridge.bridge-nf-call-iptables=1",
          "iptables -w -t mangle -I nixos-fw-rpfilter 1 " \
          "-i klp_nfq_br -j RETURN",
        )
        machine.wait_until_succeeds(
          "ip netns exec klp_nfq_a ping -c 1 -W 2 192.0.2.2",
          timeout: 30
        )
        machine.all_succeed(
          "nft add table bridge klp_nfq",
          "nft 'add chain bridge klp_nfq prerouting " \
          "{ type filter hook prerouting priority 1; policy accept; }'",
          "nft 'add rule bridge klp_nfq prerouting " \
          "ether type ip ip protocol icmp queue num 43'"
        )
        machine.succeeds(
          "#{NFQUEUE_HOLD} 4 43 #{NFQUEUE_STATE}/43.ready " \
          "#{NFQUEUE_STATE}/43.release >#{NFQUEUE_STATE}/43.log 2>&1 & " \
          "echo $! > #{NFQUEUE_STATE}/43.pid"
        )
        machine.wait_until_succeeds(
          "grep -Eq '^[[:space:]]*43[[:space:]]' " \
          "/proc/net/netfilter/nfnetlink_queue",
          timeout: 30
        )

        injected = arm_shadow_failure(machine)
        status, output = machine.execute(
          "ip netns exec klp_nfq_a ping -c 1 -W 2 192.0.2.2"
        )
        expect(status).not_to eq(0), output
        # nf_queue_entry_get_refs() performs the shadow allocation itself.
        # The injected failure proves that this function ran; publication is
        # rejected by the absence of the queue helper's ready file below.
        wait_for_shadow_failure(machine, injected)
        machine.fails("test -e #{NFQUEUE_STATE}/43.ready")

        machine.succeeds("ip link set klp_nfq_br down")
        machine.succeeds("ip link del klp_nfq_br")
        cleanup_nfqueue_workload(machine)
      end

      describe "6.12.95 cumulative livepatch", order: :defined do
        before(:suite) do
          machine.start
          machine.wait_until_online

          machine.succeeds("test \"$(uname -r)\" = 6.12.95")
          machine.succeeds(
            "test \"$(sha256sum #{CORRECTED_MODULE} | cut -d' ' -f1)\" = #{CORRECTED_SHA256}"
          )
          machine.succeeds(
            "test \"$(sha256sum #{RELEASED_V1_MODULE} | cut -d' ' -f1)\" = #{RELEASED_V1_SHA256}"
          )
          machine.succeeds(
            "test \"$(sha256sum #{PREDECESSOR_MODULE} | cut -d' ' -f1)\" = #{PREDECESSOR_SHA256}"
          )
          machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
          machine.fails("test -d /sys/module/#{RELEASED_V1_NAME}")
          machine.fails("test -d /sys/module/#{PREDECESSOR_NAME}")

          machine.all_succeed(
            "modprobe fuse",
            "mountpoint -q /sys/fs/fuse/connections || " \
            "mount -t fusectl fusectl /sys/fs/fuse/connections",
            "modprobe nfsv4",
            "modprobe l2tp_ppp",
            "modprobe af_packet",
            "modprobe sctp",
            "modprobe libceph",
            "modprobe nf_tables",
            "modprobe nfnetlink_queue",
            "modprobe nft_queue",
            "modprobe ip_set_hash_ip",
            "modprobe ip_vs",
            "modprobe bridge",
            "modprobe br_netfilter",
            "modprobe vsock_loopback",
            "modprobe xfrm_user",
            "insmod #{PERNET_HOLD_MODULE}",
            "insmod #{PROBE_MODULE}",
          )
          machine.wait_until_succeeds(
            "rpcinfo -t 127.0.0.1 nfs 4",
            timeout: 60
          )
          machine.fails("pgrep -x tlshd")
          @dmesg_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1
        end

        before(:example) do
          @example_dmesg_start =
            machine.succeeds("dmesg | wc -l")[1].to_i + 1
        end

        after(:example) do
          if machine.running?
            cleanup_example_state(machine)
            assert_kernel_healthy(machine, @example_dmesg_start)
          end
        end

        after(:suite) do
          if machine.running?
            cleanup_example_state(machine)
            machine.execute("rmmod livepatch_test_pernet_hold >/dev/null 2>&1 || true")
            machine.execute("rmmod livepatch_test_probe >/dev/null 2>&1 || true")
          end
        end

        it "keeps unpatched credential lifetimes healthy through fork and RCU callbacks" do
          machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
          machine.fails("test -d /sys/module/#{RELEASED_V1_NAME}")
          machine.fails("test -d /sys/module/#{PREDECESSOR_NAME}")
          machine.fails("test -d #{patch_dir(CORRECTED_NAME)}")
          machine.fails("test -d #{patch_dir(RELEASED_V1_NAME)}")
          machine.fails("test -d #{patch_dir(PREDECESSOR_NAME)}")

          _, before_fork = machine.succeeds(
            "dmesg | tail -n +#{@example_dmesg_start}"
          )
          expect(before_fork).not_to match(KERNEL_FAULT_PATTERN)

          machine.succeeds(
            "i=0; while test \"$i\" -lt 4096; do " \
            "sh -c : || exit 1; i=$((i + 1)); done"
          )
          machine.succeeds("sleep 6")

          _, after_rcu = machine.succeeds(
            "dmesg | tail -n +#{@example_dmesg_start}"
          )
          expect(after_rcu).not_to match(KERNEL_FAULT_PATTERN)
          machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
          machine.fails("test -d /sys/module/#{RELEASED_V1_NAME}")
          machine.fails("test -d /sys/module/#{PREDECESSOR_NAME}")
        end

        it "unwinds a deliberately failed enablement" do
          hold = "/sys/module/livepatch_test_pernet_hold/parameters/hold"
          held = "/sys/module/livepatch_test_pernet_hold/parameters/held"

          machine.succeeds("sh -c 'echo 1 > #{hold}'")
          machine.wait_until_succeeds("test \"$(cat #{held})\" = Y")

          failure_log_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1
          status, output = machine.execute("insmod #{CORRECTED_MODULE}")
          expect(status).not_to eq(0), output
          machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
          machine.fails("test -d #{patch_dir(CORRECTED_NAME)}")
          machine.succeeds(
            "dmesg | tail -n +#{failure_log_start} | " \
            "grep -F 'pre-patch callback failed for object'"
          )
          machine.fails(
            "dmesg | tail -n +#{failure_log_start} | " \
            "grep -E 'Invalid relocation target|disagrees about version|Unknown symbol'"
          )

          machine.succeeds("sh -c 'echo 0 > #{hold}'")
          machine.wait_until_succeeds("test \"$(cat #{held})\" = N")

          machine.succeeds("nft list tables")
          machine.succeeds("ipset list -n")
        end

        it "rejects occupied SUNRPC transition gate sites and unwinds them" do
          [
            [ "xs_connect", SUNRPC_XS_CONNECT_GATE_OFFSET ],
            [ "xs_tcp_tls_setup_socket", SUNRPC_TLS_WORKER_GATE_OFFSET ],
          ].each do |symbol, offset|
            set_offset_probe(machine, symbol, nil, offset)
            assert_kprobe_site(machine, symbol, offset, true)

            failure_log_start =
              machine.succeeds("dmesg | wc -l")[1].to_i + 1
            status, output = machine.execute("insmod #{CORRECTED_MODULE}")
            expect(status).not_to eq(0), output
            machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
            machine.fails("test -d #{patch_dir(CORRECTED_NAME)}")
            machine.succeeds(
              "dmesg | tail -n +#{failure_log_start} | " \
              "grep -F 'pre-patch callback failed for object'"
            )

            # The test probe remains, but both module-owned gates must have
            # been unregistered before the failed module text is discarded.
            assert_kprobe_site(machine, symbol, offset, true)
            clear_probe(machine)
            assert_sunrpc_gate_sites(machine, false)
          end

          # Prove that neither failure retained gate or registry state.
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          assert_sunrpc_gate_sites(machine, false)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
        end

        it "rejects an unshadowed legacy SUNRPC worker and allows retry" do
          cleanup_sunrpc_workload(machine)
          set_offset_probe(
            machine,
            "xs_tcp_tls_setup_socket",
            nil,
            SUNRPC_TLS_UNOWNED_HOLD_OFFSET
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          # The boot worker is already beyond the future transition gate but
          # has not yet read its unpinned raw client. The pre-patch stack scan
          # must reject activation instead of claiming that this frame can be
          # redirected or recovered.
          # Keep the mount task's client reference alive while its unpatched
          # worker is deliberately stopped.  The short default timeout would
          # otherwise destroy the raw client and reenact the original UAF
          # after the livepatch correctly refuses this escaped frame.
          start_sunrpc_tls_mount(
            machine,
            "legacy-unowned-rejection",
            timeo: 600
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )

          failure_log_start =
            machine.succeeds("dmesg | wc -l")[1].to_i + 1
          status, output = machine.execute("insmod #{CORRECTED_MODULE}")
          expect(status).not_to eq(0), output
          expect(output).to include("Device or resource busy")
          machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
          machine.fails("test -d #{patch_dir(CORRECTED_NAME)}")
          assert_sunrpc_gate_sites(machine, false)
          machine.succeeds(
            "dmesg | tail -n +#{failure_log_start} | " \
            "grep -F 'pre-patch callback failed for object'"
          )

          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N",
            timeout: 30
          )
          wait_for_sunrpc_tls_failure(machine, "legacy-unowned-rejection")
          clear_probe(machine)

          # A clean retry after the old frame exits must be able to allocate
          # and retire a fresh first-generation registry.
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          assert_sunrpc_gate_sites(machine, false)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_sunrpc_workload(machine)
        end

        it "transitions exact FUSE splice and resend states safely" do
          cleanup_fuse_workloads(machine)

          resend_state = start_fuse_helper(machine, "resend", "resend")
          machine.wait_until_succeeds(
            "test -e #{resend_state}/held",
            timeout: 30
          )

          set_probe(machine, "fuse_dev_queue_interrupt", "fuse")
          machine.succeeds("touch #{resend_state}/signal")
          machine.wait_until_succeeds(
            "test -e #{resend_state}/signaled && " \
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -ge 3",
            timeout: 30
          )
          clear_probe(machine)
          machine.succeeds("touch #{resend_state}/resend")
          machine.wait_until_succeeds(
            "test -e #{resend_state}/resent",
            timeout: 30
          )

          hold = "/sys/module/livepatch_test_pernet_hold/parameters/hold"
          held = "/sys/module/livepatch_test_pernet_hold/parameters/held"
          machine.succeeds("sh -c 'echo 1 > #{hold}'")
          machine.wait_until_succeeds("test \"$(cat #{held})\" = Y")
          status, output = machine.execute("insmod #{CORRECTED_MODULE}")
          expect(status).not_to eq(0), output
          machine.fails("test -d /sys/module/#{CORRECTED_NAME}")
          machine.succeeds(
            "kill -0 \"$(cat #{resend_state}/pid)\" && " \
            "test ! -e #{resend_state}/fatal-done"
          )
          machine.succeeds("sh -c 'echo 0 > #{hold}'")
          machine.wait_until_succeeds("test \"$(cat #{held})\" = N")

          transition_state = start_fuse_helper(
            machine,
            "transition",
            "writeback",
            "reply"
          )
          machine.wait_until_succeeds(
            "test -e #{transition_state}/ready",
            timeout: 30
          )
          set_offset_probe2(
            machine,
            "fuse_copy_page",
            "fuse",
            FUSE_REF_PAGE_ENTRY_OFFSET
          )
          set_offset_probe(
            machine,
            "fuse_copy_page",
            "fuse",
            FUSE_REF_PAGE_FINISH_CALL_OFFSET
          )
          machine.succeeds(
            "if test -r /sys/kernel/debug/kprobes/list; then " \
            "grep -E 'fuse_copy_page\\+0x0*329[[:space:]]' " \
            "/sys/kernel/debug/kprobes/list; " \
            "grep -E 'fuse_copy_page\\+0x0*369[[:space:]]' " \
            "/sys/kernel/debug/kprobes/list; " \
            "fi"
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'; " \
            "touch #{transition_state}/start"
          )
          machine.wait_until_succeeds(
            "test -e #{transition_state}/writeback-started",
            timeout: 30
          )
          machine.succeeds(
            "pid=$(cat #{transition_state}/pid); " \
            "attempt=0; while test $attempt -lt 100; do " \
            "read held < #{PROBE_PARAMETERS}/probe_held; " \
            "read hits < #{PROBE_PARAMETERS}/probe_hits; " \
            "test \"$held\" = Y && test \"$hits\" = 1 && exit 0; " \
            "if ! read process_pid process_name process_state process_rest " \
            "< /proc/$pid/stat 2>/dev/null; then " \
            "process_state=gone; break; " \
            "fi; " \
            "test \"$process_state\" = Z && break; " \
            "if ! kill -0 \"$pid\" 2>/dev/null; then " \
            "process_state=gone; break; " \
            "fi; " \
            "attempt=$((attempt + 1)); sleep 0.1; " \
            "done; " \
            "read ref_entries < #{PROBE_PARAMETERS}/probe2_hits; " \
            "read missed < #{PROBE_PARAMETERS}/probe_missed; " \
            "read ref_missed < #{PROBE_PARAMETERS}/probe2_missed; " \
            "printf 'FUSE helper state: %s; held=%s; hits=%s; " \
            "ref_entries=%s; missed=%s; ref_missed=%s\\n' " \
            "\"''${process_state:-unknown}\" \"$held\" \"$hits\" " \
            "\"$ref_entries\" \"$missed\" \"$ref_missed\" >&2; " \
            "if test -r /sys/kernel/debug/kprobes/list; then " \
            "grep -F 'fuse_copy_page+' " \
            "/sys/kernel/debug/kprobes/list >&2 || true; " \
            "fi; " \
            "if test -r /proc/$pid/wchan; then " \
            "printf 'FUSE helper wchan: ' >&2; cat /proc/$pid/wchan >&2; " \
            "fi; " \
            "for child in $(cat /proc/$pid/task/$pid/children 2>/dev/null); do " \
            "printf 'FUSE child %s wchan: ' \"$child\" >&2; " \
            "cat /proc/$child/wchan >&2; " \
            "done; " \
            "cat #{transition_state}/output.log >&2; exit 1",
            timeout: 20
          )
          machine.succeeds(
            "grep -F fuse_copy_page " \
            "/proc/$(cat #{transition_state}/pid)/stack"
          )
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_hits)\" = 1"
          )
          clear_probe2(machine)

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          machine.wait_until_succeeds(
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/enabled)\" = 1 && " \
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/transition)\" = 1",
            timeout: 30
          )
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N && " \
            "test -e #{transition_state}/completed",
            timeout: 30
          )
          wait_for_patch(machine, CORRECTED_NAME, 1)
          clear_probe(machine)

          machine.succeeds("touch #{resend_state}/fatal")
          machine.wait_until_succeeds(
            "test -e #{resend_state}/fatal-done",
            timeout: 30
          )
          machine.succeeds("touch #{resend_state}/consume")
          machine.wait_until_succeeds(
            "test -e #{resend_state}/consume-done",
            timeout: 30
          )
          machine.succeeds("touch #{resend_state}/abort")
          machine.wait_until_succeeds(
            "test -e #{resend_state}/abort-done && " \
            "! kill -0 \"$(cat #{resend_state}/pid)\" 2>/dev/null",
            timeout: 30
          )

          abort_state = start_fuse_helper(
            machine,
            "abort",
            "writeback",
            "abort"
          )
          machine.wait_until_succeeds(
            "test -e #{abort_state}/ready",
            timeout: 30
          )
          set_offset_probe(
            machine,
            "fuse_copy_page",
            CORRECTED_NAME,
            FUSE_REF_PAGE_FINISH_CALL_OFFSET
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'; " \
            "touch #{abort_state}/start"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y && " \
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" = 1",
            timeout: 30
          )
          machine.succeeds(
            "sh -c 'echo 1 > /sys/fs/fuse/connections/" \
            "$(cat #{abort_state}/connection)/abort'"
          )
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N && " \
            "test -e #{abort_state}/aborted",
            timeout: 30
          )
          clear_probe(machine)

          close_state = start_fuse_helper(
            machine,
            "close",
            "writeback",
            "close"
          )
          machine.wait_until_succeeds(
            "test -e #{close_state}/ready",
            timeout: 30
          )
          machine.succeeds("touch #{close_state}/start")
          machine.wait_until_succeeds(
            "test -e #{close_state}/closed && " \
            "! kill -0 \"$(cat #{close_state}/pid)\" 2>/dev/null",
            timeout: 30
          )

          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_fuse_workloads(machine)
        end

        it "normalizes both valid legacy perf group states" do
          [1, 2].each do |phase|
            machine.succeeds(
              "#{PERF_TRANSITION} #{phase} #{CORRECTED_MODULE} #{CORRECTED_NAME}",
              timeout: 180
            )
            wait_for_patch(machine, CORRECTED_NAME, 1)
            disable_patch(machine, CORRECTED_NAME)
            remove_module(machine, CORRECTED_NAME)
          end
        end

        it "flushes every online CPU after the function transition" do
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)

          set_probe(machine, "do_flush_tlb_all")
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          online_cpus = machine.succeeds("getconf _NPROCESSORS_ONLN")[1].to_i
          expect(probe_value(machine, "probe_hits")).to be >= online_cpus
          expect(probe_value(machine, "probe_cpu_count")).to eq(online_cpus)

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
        end

        it "flushes predictor state for reused classic-BPF JIT addresses" do
          machine.succeeds("sysctl -qw net.core.bpf_jit_enable=1")
          start_bpf_churn(machine)

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          set_probe(machine, "vpsadminos_bpf_jit_ibpb", CORRECTED_NAME)
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0",
            timeout: 60
          )

          stop_bpf_churn(machine)
          machine.succeeds("test \"$(cat #{BPF_STATE}/progress)\" -ge 256")
          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
        end

        it "fails a pipapo clone cleanly when its shadow cannot be allocated" do
          machine.execute("nft delete table inet klp_pipapo >/dev/null 2>&1 || true")
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          machine.all_succeed(
            "nft add table inet klp_pipapo",
            "nft 'add set inet klp_pipapo endpoints " \
            "{ type ipv4_addr . inet_service; flags interval; }'"
          )

          injected = arm_shadow_failure(machine)
          status, output = machine.execute(
            "nft 'add element inet klp_pipapo endpoints " \
            "{ 192.0.2.10 . 443 }'"
          )
          expect(status).not_to eq(0), output
          wait_for_shadow_failure(machine, injected)

          machine.all_succeed(
            "nft list set inet klp_pipapo endpoints",
            "nft 'add element inet klp_pipapo endpoints " \
            "{ 192.0.2.10 . 443 }'",
            "nft 'get element inet klp_pipapo endpoints " \
            "{ 192.0.2.10 . 443 }'",
            "nft 'delete element inet klp_pipapo endpoints " \
            "{ 192.0.2.10 . 443 }'",
            "nft delete table inet klp_pipapo"
          )

          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
        end

        it "holds complete NFtables batches across activation and removal" do
          cleanup_nft_batch_workload(machine)
          machine.all_succeed(
            "mkdir -p #{NFT_BATCH_STATE}",
            "nft add table inet klp_batch",
            "nft 'add set inet klp_batch endpoints " \
            "{ type ipv4_addr . inet_service; flags interval; }'"
          )

          set_offset_probe(
            machine,
            "nft_pipapo_insert",
            "nf_tables",
            NFT_PIPAPO_HOLD_OFFSET
          )
          machine.succeeds(
            "if test -r /sys/kernel/debug/kprobes/list; then " \
            "grep -E 'nft_pipapo_insert\\+0x0*5[[:space:]]' " \
            "/sys/kernel/debug/kprobes/list; " \
            "fi"
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.succeeds(
            "(nft 'add element inet klp_batch endpoints " \
            "{ 192.0.2.20 . 80 }'; " \
            "printf '%s\\n' \"$?\" > #{NFT_BATCH_STATE}/activate.status) " \
            ">#{NFT_BATCH_STATE}/activate.log 2>&1 & " \
            "echo $! > #{NFT_BATCH_STATE}/activate.pid"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          machine.wait_until_succeeds(
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/enabled)\" = 1 && " \
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/transition)\" = 1",
            timeout: 30
          )
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N && " \
            "test \"$(cat #{NFT_BATCH_STATE}/activate.status)\" = 0",
            timeout: 30
          )
          wait_for_patch(machine, CORRECTED_NAME, 1)
          clear_probe(machine)
          machine.succeeds(
            "nft 'get element inet klp_batch endpoints " \
            "{ 192.0.2.20 . 80 }'"
          )

          set_offset_probe(
            machine,
            "nft_pipapo_insert",
            CORRECTED_NAME,
            NFT_PIPAPO_HOLD_OFFSET
          )
          machine.succeeds(
            "if test -r /sys/kernel/debug/kprobes/list; then " \
            "grep -E 'nft_pipapo_insert\\+0x0*5[[:space:]]' " \
            "/sys/kernel/debug/kprobes/list; " \
            "fi"
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.succeeds(
            "(nft 'add element inet klp_batch endpoints " \
            "{ 192.0.2.21 . 443 }'; " \
            "printf '%s\\n' \"$?\" > #{NFT_BATCH_STATE}/remove.status) " \
            ">#{NFT_BATCH_STATE}/remove.log 2>&1 & " \
            "echo $! > #{NFT_BATCH_STATE}/remove.pid"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )
          machine.succeeds(
            "(echo 0 > #{patch_dir(CORRECTED_NAME)}/enabled; " \
            "printf '%s\\n' \"$?\" > #{NFT_BATCH_STATE}/disable.status) " \
            ">#{NFT_BATCH_STATE}/disable.log 2>&1 & " \
            "echo $! > #{NFT_BATCH_STATE}/disable.pid"
          )
          machine.succeeds(
            "sleep 1; kill -0 \"$(cat #{NFT_BATCH_STATE}/disable.pid)\"; " \
            "test ! -e #{NFT_BATCH_STATE}/disable.status"
          )

          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N && " \
            "test \"$(cat #{NFT_BATCH_STATE}/remove.status)\" = 0 && " \
            "test \"$(cat #{NFT_BATCH_STATE}/disable.status)\" = 0",
            timeout: 60
          )
          wait_for_patch(machine, CORRECTED_NAME, 0)
          clear_probe(machine)
          remove_module(machine, CORRECTED_NAME)
          machine.all_succeed(
            "nft 'get element inet klp_batch endpoints " \
            "{ 192.0.2.20 . 80 }'",
            "nft 'get element inet klp_batch endpoints " \
            "{ 192.0.2.21 . 443 }'"
          )
          cleanup_nft_batch_workload(machine)
        end

        it "holds an ipset dump across activation and list-array growth" do
          prepare_held_ipset_dump(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          grow_ipset_list_across_dump_release(machine)

          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_ipset_dump(machine)
        end

        it "prevents a running legacy ipset GC from requeueing on destroy" do
          machine.execute("ipset destroy klp_gc >/dev/null 2>&1 || true")
          set_probe(machine, "hash_ip4_gc", "ip_set_hash_ip")
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.all_succeed(
            "ipset create klp_gc hash:ip timeout 1",
            "ipset add klp_gc 192.0.2.99 timeout 1"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          machine.succeeds(
            "ipset destroy klp_gc > /run/klp-gc-destroy.log 2>&1 & " \
            "echo $! > /run/klp-gc-destroy.pid"
          )
          machine.succeeds(
            "sleep 1; kill -0 \"$(cat /run/klp-gc-destroy.pid)\""
          )

          hits = probe_value(machine, "probe_hits")
          expect(hits).to eq(1)
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N && " \
            "! kill -0 \"$(cat /run/klp-gc-destroy.pid)\" 2>/dev/null",
            timeout: 30
          )
          machine.succeeds("sleep 5")
          expect(probe_value(machine, "probe_hits")).to eq(hits)

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
        end

        it "hardens a legacy TCP sysctl table and wrapped socket" do
          prepare_legacy_tcp_socket(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          set_offset_probe(
            machine,
            "tcp_write_xmit",
            CORRECTED_NAME,
            TCP_MTU_PROBE_SIZE_OFFSET
          )
          machine.succeeds(
            "if test -r /sys/kernel/debug/kprobes/list; then " \
            "grep -E 'tcp_write_xmit\\+0x0*7e0[[:space:]]' " \
            "/sys/kernel/debug/kprobes/list; " \
            "fi"
          )

          machine.succeeds(
            "ip netns exec klp_tcp_a " \
            "sysctl -qw net.ipv4.tcp_reordering=-1"
          )
          release_legacy_tcp_socket(machine)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_tcp_workload(machine)
        end

        it "completes fixed-buffer vsock sends across activation" do
          start_vsock_workload(machine, 9005)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          set_probe(machine, "__skb_zcopy_downgrade_managed")
          release_vsock_workload(machine)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )
          clear_probe(machine)

          set_probe(machine, "__skb_zcopy_downgrade_managed")
          set_probe2(
            machine,
            "virtio_transport_send_pkt_info",
            CORRECTED_NAME
          )
          start_vsock_workload(machine, 9006)
          release_vsock_workload(machine)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" = 0"
          )
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_hits)\" -gt 0"
          )

          clear_probe(machine)
          clear_probe2(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_vsock_workload(machine)
        end

        it "retires populated XFRM input caches before lookup and deletion" do
          prepare_xfrm_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          set_probe(
            machine,
            "xfrm_input_state_lookup",
            CORRECTED_NAME
          )
          machine.succeeds(
            "ip netns exec klp_xfrm_a ping -c 16 -W 2 10.23.0.2"
          )
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )
          clear_probe(machine)

          set_probe(machine, "__xfrm_state_delete", CORRECTED_NAME)
          machine.all_succeed(
            "ip netns exec klp_xfrm_a ip xfrm state flush",
            "ip netns exec klp_xfrm_b ip xfrm state flush"
          )
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -ge 4"
          )

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_xfrm_workload(machine)
        end

        it "handles preactivation NFSv4 lock and unlock RPC callbacks" do
          prepare_nfs_workload(machine)

          set_probe(machine, "nfsd4_lock", "nfsd")
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          lock_state = start_nfs_lock_holder(machine, "lock-transition")
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          machine.wait_until_succeeds(
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/enabled)\" = 1 && " \
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/transition)\" = 1",
            timeout: 30
          )
          set_probe2(
            machine,
            "nfs4_lock_done",
            CORRECTED_NAME
          )
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          wait_for_nfs_lock(machine, lock_state)
          wait_for_patch(machine, CORRECTED_NAME, 1)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_hits)\" -gt 0"
          )
          clear_probe2(machine)
          clear_probe(machine)
          release_nfs_lock(machine, lock_state)

          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)

          unlock_state = start_nfs_lock_holder(machine, "unlock-transition")
          wait_for_nfs_lock(machine, unlock_state)
          set_probe(machine, "nfsd4_locku", "nfsd")
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'; " \
            "touch #{unlock_state}/release"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          set_probe2(
            machine,
            "nfs4_locku_done",
            CORRECTED_NAME
          )
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "! kill -0 \"$(cat #{unlock_state}/pid)\" 2>/dev/null",
            timeout: 60
          )
          wait_for_patch(machine, CORRECTED_NAME, 1)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_hits)\" -gt 0"
          )
          clear_probe2(machine)
          clear_probe(machine)

          set_probe(
            machine,
            "nfs4_lock_done",
            CORRECTED_NAME
          )
          active_state = start_nfs_lock_holder(machine, "active")
          wait_for_nfs_lock(machine, active_state)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )
          release_nfs_lock(machine, active_state)

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_nfs_workload(machine)
        end

        it "redirects an old SUNRPC TLS worker through the transition gate" do
          cleanup_sunrpc_workload(machine)
          set_offset_probe(
            machine,
            "xs_tcp_tls_setup_socket",
            nil,
            SUNRPC_TLS_ENTRY_HOLD_OFFSET
          )
          machine.succeeds(
            "if test -r /sys/kernel/debug/kprobes/list; then " \
            "grep -E 'xs_tcp_tls_setup_socket\\+0x0*5[[:space:]]' " \
            "/sys/kernel/debug/kprobes/list; " \
            "fi"
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          # The initial rpc_ping() cannot finish while this worker is held,
          # and rpc_create() adds nconnect peers only after that return.  The
          # already-published first transport is therefore the real legacy
          # worker which must cross the transition gate.
          start_sunrpc_tls_mount(machine, "legacy")
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          machine.wait_until_succeeds(
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/enabled)\" = 1 && " \
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/transition)\" = 1",
            timeout: 30
          )
          expect(probe_value(machine, "probe_hits")).to be > 0
          assert_sunrpc_gate_sites(machine, true)
          set_probe2(
            machine,
            "vpsadminos_sunrpc_worker_gate_target",
            CORRECTED_NAME
          )

          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N",
            timeout: 30
          )
          wait_for_patch(machine, CORRECTED_NAME, 1)
          expect(probe_value(machine, "probe2_hits")).to be > 0
          assert_sunrpc_gate_sites(machine, false)
          wait_for_sunrpc_tls_failure(machine, "legacy")

          clear_probe2(machine)
          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_sunrpc_workload(machine)
        end

        it "pins and drains a SUNRPC TLS client across clean removal" do
          cleanup_sunrpc_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          set_probe(
            machine,
            "vpsadminos_sunrpc_tls_release_work",
            CORRECTED_NAME
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          start_sunrpc_tls_mount(machine, "owned")
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y",
            timeout: 30
          )
          signal_sunrpc_tls_mount(machine, "owned")

          machine.succeeds(
            "(echo 0 > #{patch_dir(CORRECTED_NAME)}/enabled; " \
            "printf '%s\\n' \"$?\" > #{SUNRPC_STATE}/disable.status) " \
            ">#{SUNRPC_STATE}/disable.log 2>&1 & " \
            "echo $! > #{SUNRPC_STATE}/disable.pid"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/enabled)\" = 0 && " \
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/transition)\" = 1",
            timeout: 30
          )

          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N",
            timeout: 30
          )
          wait_for_sunrpc_tls_mount_exit(machine, "owned")
          wait_for_patch(machine, CORRECTED_NAME, 0)
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0",
            timeout: 30
          )
          machine.wait_until_succeeds(
            "test -s #{SUNRPC_STATE}/disable.status",
            timeout: 30
          )
          machine.succeeds(
            "test \"$(cat #{SUNRPC_STATE}/disable.status)\" = 0"
          )

          clear_probe(machine)
          remove_module(machine, CORRECTED_NAME)
          cleanup_sunrpc_workload(machine)
        end

        it "gives a SUNRPC removal callback sole ownership before worker claim" do
          cleanup_sunrpc_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          race_state = "#{SUNRPC_STATE}/spin-coordinator"

          race_log_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1
          set_offset_probe(
            machine,
            "xs_tcp_tls_setup_socket",
            CORRECTED_NAME,
            SUNRPC_TLS_ENTRY_HOLD_OFFSET
          )
          set_offset_probe2(
            machine,
            "vpsadminos_sunrpc_tls_drain",
            CORRECTED_NAME,
            SUNRPC_TLS_DRAIN_CALLBACK_CLAIM_OFFSET
          )
          set_offset_probe3(
            machine,
            "vpsadminos_sunrpc_cb_release",
            CORRECTED_NAME,
            SUNRPC_CB_RELEASE_SHADOW_FREE_OFFSET
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.succeeds(
            "mkdir -p #{SUNRPC_STATE}/spin-deadline; " \
            "rm -f #{SUNRPC_STATE}/spin-deadline/fired; " \
            "setsid sh -c 'sleep 10; " \
            "touch #{SUNRPC_STATE}/spin-deadline/fired; " \
            "test ! -e #{PROBE_PARAMETERS}/probe_hold || " \
            "echo 0 > #{PROBE_PARAMETERS}/probe_hold' " \
            ">#{SUNRPC_STATE}/spin-deadline/output.log 2>&1 & " \
            "echo $! > #{SUNRPC_STATE}/spin-deadline/pid"
          )
          machine.succeeds(
            "mkdir -p #{race_state}; " \
            "rm -f #{race_state}/snapshot #{race_state}/held " \
            "#{race_state}/claim-matched #{race_state}/owner " \
            "#{race_state}/disable-alive #{race_state}/status-unwritten " \
            "#{race_state}/enabled #{race_state}/transition " \
            "#{race_state}/disable.status; " \
            "setsid sh -c 'set -eu; coordinator() { " \
            "while test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" != Y; do " \
            "sleep 0.01; done; " \
            "(set -C; : > #{race_state}/owner) 2>/dev/null || return 0; " \
            "printf \"Y\\n\" > #{race_state}/held; " \
            "read worker < #{PROBE_PARAMETERS}/probe_arg0; " \
            "test \"$worker\" != 0; " \
            "transport=$((worker - #{SUNRPC_TLS_WORK_OFFSET})); " \
            "printf \"%s\\n\" \"$worker\" > " \
            "#{PROBE_PARAMETERS}/probe_match_arg0; " \
            "printf \"0x%x\\n\" \"$transport\" > " \
            "#{race_state}/held-transport; " \
            "(echo 0 > #{patch_dir(CORRECTED_NAME)}/enabled; " \
            "printf \"%s\\n\" \"$?\" > #{race_state}/disable.status) " \
            ">#{race_state}/disable.log 2>&1 & " \
            "disable_pid=$!; " \
            "printf \"%s\\n\" \"$disable_pid\" > #{race_state}/disable.pid; " \
            "while test \"$(cat " \
            "#{PROBE_PARAMETERS}/probe2_match_hits)\" -eq 0; do " \
            "sleep 0.01; done; " \
            "printf \"Y\\n\" > #{race_state}/claim-matched; " \
            "printf \"0x%x\\n\" \"$transport\" > " \
            "#{PROBE_PARAMETERS}/probe_match_arg0; " \
            "if kill -0 \"$disable_pid\" 2>/dev/null; then " \
            "printf \"Y\\n\" > #{race_state}/disable-alive; else " \
            "printf \"N\\n\" > #{race_state}/disable-alive; fi; " \
            "if test ! -e #{race_state}/disable.status; then " \
            "printf \"Y\\n\" > #{race_state}/status-unwritten; else " \
            "printf \"N\\n\" > #{race_state}/status-unwritten; fi; " \
            "cat #{patch_dir(CORRECTED_NAME)}/enabled > " \
            "#{race_state}/enabled; " \
            "cat #{patch_dir(CORRECTED_NAME)}/transition > " \
            "#{race_state}/transition; " \
            "touch #{race_state}/snapshot; " \
            "echo 0 > #{PROBE_PARAMETERS}/probe_hold; }; " \
            "coordinator & coordinator & coordinator & coordinator & wait' " \
            ">#{race_state}/output.log 2>&1 & " \
            "echo $! > #{race_state}/pid"
          )
          start_sunrpc_tls_mount(machine, "callback-owned")
          machine.wait_until_succeeds(
            "test -e #{race_state}/snapshot",
            timeout: 30
          )
          callback_checks = {
            "worker was held" => machine.execute(
              "test \"$(cat #{race_state}/held)\" = Y"
            ),
            "callback claimed held worker" => machine.execute(
              "test \"$(cat #{race_state}/claim-matched)\" = Y"
            ),
            "disable writer remained alive" => machine.execute(
              "test \"$(cat #{race_state}/disable-alive)\" = Y"
            ),
            "disable status remained unwritten" => machine.execute(
              "test \"$(cat #{race_state}/status-unwritten)\" = Y"
            ),
            "patch remained enabled" => machine.execute(
              "test \"$(cat #{race_state}/enabled)\" = 1"
            ),
            "unpatch transition remained active" => machine.execute(
              "test \"$(cat #{race_state}/transition)\" = 1"
            ),
          }
          callback_checks.each do |label, (status, output)|
            expect(status).to eq(0), "#{label}: #{output}"
          end

          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_hits)\" -gt 0",
            timeout: 30
          )
          expect(probe_value(machine, "probe2_missed")).to eq(0)
          machine.all_succeed(
            "kill -0 \"$(cat #{SUNRPC_STATE}/spin-deadline/pid)\"",
            "test ! -e #{SUNRPC_STATE}/spin-deadline/fired"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N",
            timeout: 30
          )
          machine.succeeds(
            "kill -- \"-$(cat #{SUNRPC_STATE}/spin-deadline/pid)\""
          )
          machine.wait_until_succeeds(
            "! kill -0 \"$(cat #{SUNRPC_STATE}/spin-deadline/pid)\" " \
            "2>/dev/null",
            timeout: 30
          )
          machine.all_succeed(
            "rm -f #{SUNRPC_STATE}/spin-deadline/pid",
            "test ! -e #{SUNRPC_STATE}/spin-deadline/fired"
          )
          machine.wait_until_succeeds(
            "test -s #{race_state}/disable.status",
            timeout: 30
          )
          machine.succeeds(
            "test \"$(cat #{race_state}/disable.status)\" = 0"
          )
          wait_for_patch(machine, CORRECTED_NAME, 0)
          wait_for_sunrpc_tls_failure(machine, "callback-owned")
          ownership_counts = %w[
            probe2_hits
            probe3_hits
            probe3_match_hits
            probe2_missed
            probe3_missed
          ].to_h do |parameter|
            [parameter, probe_value(machine, parameter)]
          end
          ownership_summary = ownership_counts.map do |parameter, value|
            "#{parameter}=#{value}"
          end.join(", ")
          expect(ownership_counts["probe2_hits"]).to be >= 1,
            ownership_summary
          expect(ownership_counts["probe3_match_hits"]).to eq(1),
            ownership_summary
          expect(ownership_counts["probe2_missed"]).to eq(0),
            ownership_summary
          expect(ownership_counts["probe3_missed"]).to eq(0),
            ownership_summary
          _, race_dmesg = machine.succeeds(
            "dmesg | tail -n +#{race_log_start}"
          )
          expect(race_dmesg).not_to match(
            /BUG:|WARNING:|Oops:|general protection fault|kernel panic/
          )

          clear_probe3(machine)
          clear_probe2(machine)
          clear_probe(machine)
          remove_module(machine, CORRECTED_NAME)
          cleanup_sunrpc_workload(machine)
        end

        it "fails SUNRPC TLS shadow allocation closed and reaches no-agent TLS" do
          cleanup_sunrpc_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          set_probe(
            machine,
            "xs_tcp_tls_setup_socket",
            CORRECTED_NAME
          )
          set_offset_probe2(
            machine,
            "xs_connect",
            CORRECTED_NAME,
            SUNRPC_TLS_SHADOW_ALLOC_OFFSET
          )
          machine.succeeds(
            "if test -r /sys/kernel/debug/kprobes/list; then " \
            "grep -E 'xs_connect\\+0x0*1ec[[:space:]]' " \
            "/sys/kernel/debug/kprobes/list; " \
            "fi"
          )
          injected = arm_shadow_failures(machine, 1024)
          start_sunrpc_tls_mount(machine, "shadow-failure")
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_hits)\" -gt 0",
            timeout: 30
          )
          wait_for_shadow_failure(machine, injected)
          machine.succeeds("sleep 2")
          expect(probe_value(machine, "probe_hits")).to eq(0)
          kill_sunrpc_tls_mount(machine, "shadow-failure")
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/shadow_failures'"
          )
          clear_probe2(machine)
          clear_probe(machine)

          set_probe(machine, "xs_tls_handshake_sync")
          start_sunrpc_tls_mount(machine, "no-agent")
          wait_for_sunrpc_tls_failure(machine, "no-agent")
          expect(probe_value(machine, "probe_hits")).to be > 0
          machine.fails("pgrep -x tlshd")

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_sunrpc_workload(machine)
        end

        it "tears down populated IPv4 and IPv6 multicast state safely" do
          prepare_multicast_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          set_probe(machine, "igmp_ifc_start_timer", CORRECTED_NAME)
          start_multicast_holder(machine, 2)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )
          clear_probe(machine)

          set_probe(machine, "mld_ifc_start_work", CORRECTED_NAME)
          start_multicast_holder(machine, 3)
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )
          clear_probe(machine)

          set_probe(machine, "ip_mc_destroy_dev", CORRECTED_NAME)
          machine.succeeds("ip -net klp_mc link del mc0")
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )
          stop_multicast_holders(machine)

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_multicast_workload(machine)
        end

        it "drains down-bridge STP timers on root and nonroot paths" do
          prepare_bridge_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          set_probe(
            machine,
            "br_topology_change_detection",
            CORRECTED_NAME
          )
          machine.all_succeed(
            "ip link set klp_stp_p0 down",
            "ip link set klp_stp_p0 up",
            "ip link set klp_stp_br1 up",
            "ip link set klp_stp_p1 up",
            "sleep 3",
            "ip link set klp_stp_p1 down"
          )
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )
          clear_probe(machine)

          machine.succeeds("ip link set klp_stp_br1 down")
          set_probe(machine, "br_dev_delete", CORRECTED_NAME)
          machine.succeeds("ip link del klp_stp_br1")
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0"
          )

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_bridge_workload(machine)
        end

        it "transmits the IPVS fwmark cache-bypass path without a destination" do
          prepare_ipvs_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          set_probe(machine, "ip_vs_bypass_xmit", CORRECTED_NAME)
          set_probe2(machine, "ip_vs_leave", "ip_vs")

          machine.all_succeed(
            "ip rule show | " \
            "grep -Eq '^100:.*fwmark 0x1.*lookup 100'",
            "ip route show table 100 type local | " \
            "grep -Eq '^local (default|0\\.0\\.0\\.0/0) dev lo'",
            "ip route get 198.51.100.100 mark 1 | " \
            "grep -Eq '^local .* dev lo([[:space:]]|$)'",
            "ip route get 198.51.100.100 | " \
            "grep -Eq '^198\\.51\\.100\\.100 .*dev " \
            "klp_ipvs_out([[:space:]]|$)'",
            "ipvsadm -Ln | grep -Eq '^FWM[[:space:]]+1[[:space:]]'"
          )

          machine.succeeds(
            "for i in $(seq 1 32); do " \
            "printf x | ip netns exec klp_ipvs_client " \
            "socat -u STDIN UDP:198.51.100.100:9003; " \
            "done"
          )
          machine.succeeds(
            "nft list chain ip klp_ipvs prerouting | " \
            "grep -Eq 'counter packets [1-9][0-9]* bytes [1-9][0-9]*'"
          )
          machine.succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_hits)\" -gt 0"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0",
            timeout: 30
          )

          clear_probe2(machine)
          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_ipvs_workload(machine)
        end

        it "fragments oversized IPv6 bridge traffic after checksum handling" do
          prepare_fragment_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          set_probe2(machine, "skb_checksum_help")
          set_probe3(machine, "pskb_expand_head")
          set_probe(machine, "br_ip6_fragment", CORRECTED_NAME)
          machine.succeeds(
            "rm -f #{FRAGMENT_STATE}/probe-coordinator.owner " \
            "#{FRAGMENT_STATE}/probe-coordinator.snapshot " \
            "#{FRAGMENT_STATE}/probe-coordinator.held " \
            "#{FRAGMENT_STATE}/probe-coordinator.pid; " \
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_spin_hold'; " \
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_clone_arg2'; " \
            "setsid sh -c 'coordinator() { " \
            "attempt=0; " \
            "while test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" != Y && " \
            "test \"$attempt\" -lt 600; do " \
            "test ! -e #{FRAGMENT_STATE}/probe-coordinator.snapshot || " \
            "return 0; " \
            "attempt=$((attempt + 1)); sleep 0.01; done; " \
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y || " \
            "return 0; " \
            "test \"$(cat " \
            "#{PROBE_PARAMETERS}/probe_arg2_clone_held)\" = Y || " \
            "return 0; " \
            "(set -C; : > #{FRAGMENT_STATE}/probe-coordinator.owner) " \
            "2>/dev/null || return 0; " \
            "read skb < #{PROBE_PARAMETERS}/probe_arg2; " \
            "test \"$skb\" != 0; " \
            "printf \"%s\\n\" \"$skb\" > " \
            "#{PROBE_PARAMETERS}/probe_match_arg0; " \
            "printf \"Y\\n\" > " \
            "#{FRAGMENT_STATE}/probe-coordinator.held; " \
            "echo 0 > #{PROBE_PARAMETERS}/probe_hold; " \
            "touch #{FRAGMENT_STATE}/probe-coordinator.snapshot; }; " \
            "coordinator & coordinator & coordinator & coordinator & wait' " \
            ">#{FRAGMENT_STATE}/probe-coordinator.log 2>&1 & " \
            "echo $! > #{FRAGMENT_STATE}/probe-coordinator.pid"
          )

          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'; " \
            "source_mac=$(ip netns exec klp_frag_a " \
            "cat /sys/class/net/eth0/address); " \
            "dest_mac=$(ip netns exec klp_frag_b " \
            "cat /sys/class/net/eth0/address); " \
            "(ip netns exec klp_frag_a #{IPV6_FRAGMENT_PARTIAL} " \
            "eth0 \"$source_mac\" \"$dest_mac\" " \
            "2001:db8:3::1 2001:db8:3::2 9004; " \
            "status=$?; printf '%s\\n' \"$status\" > " \
            "#{FRAGMENT_STATE}/client.status; exit \"$status\") " \
            ">#{FRAGMENT_STATE}/client.log 2>&1 </dev/null & " \
            "echo $! > #{FRAGMENT_STATE}/client.pid"
          )
          machine.wait_until_succeeds(
            "test -e #{FRAGMENT_STATE}/probe-coordinator.snapshot || " \
            "test -s #{FRAGMENT_STATE}/client.status",
            timeout: 30
          )
          machine.succeeds(
            "if test -e #{FRAGMENT_STATE}/probe-coordinator.snapshot; then " \
            "test \"$(cat " \
            "#{FRAGMENT_STATE}/probe-coordinator.held)\" = Y; " \
            "exit 0; fi; " \
            "printf 'client.status='; cat #{FRAGMENT_STATE}/client.status; " \
            "cat #{FRAGMENT_STATE}/client.log; " \
            "cat #{FRAGMENT_STATE}/probe-coordinator.log; " \
            "printf 'fragment_hits='; " \
            "cat #{PROBE_PARAMETERS}/probe_hits; " \
            "printf 'fragment_arg2='; " \
            "cat #{PROBE_PARAMETERS}/probe_arg2; " \
            "printf 'checksum_hits='; " \
            "cat #{PROBE_PARAMETERS}/probe2_hits; " \
            "printf 'expand_hits='; " \
            "cat #{PROBE_PARAMETERS}/probe3_hits; exit 1"
          )
          machine.wait_until_succeeds(
            "! kill -0 \"$(cat " \
            "#{FRAGMENT_STATE}/probe-coordinator.pid)\" 2>/dev/null",
            timeout: 10
          )
          machine.succeeds("rm #{FRAGMENT_STATE}/probe-coordinator.pid")
          machine.wait_until_succeeds(
            "test -e #{FRAGMENT_STATE}/payload && " \
            "test \"$(wc -c < #{FRAGMENT_STATE}/payload)\" = 4096",
            timeout: 30
          )
          machine.wait_until_succeeds(
            "test -s #{FRAGMENT_STATE}/client.status",
            timeout: 30
          )
          machine.all_succeed(
            "test \"$(cat #{FRAGMENT_STATE}/client.status)\" = 0",
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0",
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_match_hits)\" -gt 0",
            "test \"$(cat #{PROBE_PARAMETERS}/probe3_match_hits)\" -gt 0",
            "test \"$(cat " \
            "#{PROBE_PARAMETERS}/probe_arg2_clone_held)\" = Y",
            "test \"$(cat #{PROBE_PARAMETERS}/probe_missed)\" = 0",
            "test \"$(cat #{PROBE_PARAMETERS}/probe2_missed)\" = 0",
            "test \"$(cat #{PROBE_PARAMETERS}/probe3_missed)\" = 0"
          )
          machine.all_succeed(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_clone_arg2'",
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_spin_hold'"
          )

          clear_probe3(machine)
          clear_probe2(machine)
          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_fragment_workload(machine)
        end

        it "drains held IPv4, IPv6, and GSO bridge NFQUEUE entries" do
          prepare_nfqueue_workload(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          machine.succeeds("ip link set klp_nfq_br down")
          machine.succeeds("ip link del klp_nfq_br")
          release_nfqueue_workload(machine)

          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          cleanup_nfqueue_workload(machine)
        end

        it "drops a queued bridge packet when its shadow allocation fails" do
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          exercise_nfqueue_shadow_failure(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
        end

        it "contains and exercises the v2 replacement functions" do
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)

          V2_REPLACEMENT_FUNCTIONS.each do |function|
            symbol_address(machine, function, CORRECTED_NAME)
          end

          set_probe(machine, "posix_cpu_timer_set", CORRECTED_NAME)
          machine.succeeds("#{V2_RUNTIME} cpu-timer")
          machine.succeeds("test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0")

          set_probe(machine, "packet_set_ring", CORRECTED_NAME)
          machine.succeeds("#{V2_RUNTIME} packet-ring")
          machine.succeeds("test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0")

          set_probe(machine, "ppp_destroy_channel", CORRECTED_NAME)
          machine.succeeds("#{V2_RUNTIME} pppol2tp")
          machine.succeeds("test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0")

          machine.all_succeed(
            "sysctl -q -w net.sctp.auth_enable=1",
            "sysctl -q -w net.sctp.addip_enable=1"
          )
          set_probe(machine, "sctp_process_asconf", CORRECTED_NAME)
          machine.succeeds("#{V2_RUNTIME} sctp-asconf")
          machine.succeeds("test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0")

          clear_probe(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
        end

        it "activates, exercises, disables, and removes the corrected patch" do
          machine.succeeds("modprobe -r nft_queue")
          unload_late_target_dependents(machine)
          LATE_TARGET_OBJECTS.reverse_each do |object|
            if machine.execute("test -d /sys/module/#{object}")[0] == 0
              machine.succeeds("modprobe -r #{object}")
            end
            machine.fails("test -d /sys/module/#{object}")
          end

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          ALWAYS_LOADED_TARGET_OBJECTS.each do |object|
            wait_for_object(machine, CORRECTED_NAME, object, 1)
          end
          LATE_TARGET_OBJECTS.each do |object|
            wait_for_object(machine, CORRECTED_NAME, object, 0)
          end

          LATE_TARGET_OBJECTS.each do |object|
            machine.succeeds("modprobe #{object}")
          end
          machine.succeeds("modprobe nft_queue")
          LATE_TARGET_OBJECTS.each do |object|
            wait_for_object(machine, CORRECTED_NAME, object, 1)
          end

          machine.succeeds("modprobe -r nft_queue")
          unload_late_target_dependents(machine)
          LATE_TARGET_OBJECTS.reverse_each do |object|
            machine.succeeds("modprobe -r #{object}")
            wait_for_object(machine, CORRECTED_NAME, object, 0)
          end

          LATE_TARGET_OBJECTS.each do |object|
            machine.succeeds("modprobe #{object}")
          end
          machine.succeeds("modprobe nft_queue")
          reload_late_target_dependents(machine)
          LATE_TARGET_OBJECTS.each do |object|
            wait_for_object(machine, CORRECTED_NAME, object, 1)
          end

          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)

          machine.succeeds("sysctl -w net.ipv4.tcp_reordering=999999")
          machine.succeeds("sysctl -w net.ipv4.tcp_reordering=3")

          prepare_transition_state(machine)
          machine.succeeds("insmod #{CORRECTED_MODULE}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          consume_transition_state(machine)

          start_stress(machine)
          before = stress_counts(machine)
          wait_for_stress_advance(machine, before)
          IPSET_HASH_OBJECTS.each do |object|
            wait_for_object(machine, CORRECTED_NAME, object, 1)
          end

          stop_stress(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          machine.succeeds("nft list tables")
          machine.succeeds("ipset list -n")
        end

        it "atomically replaces released v1 with v2 and rejects an incompatible downgrade" do
          machine.succeeds("insmod #{RELEASED_V1_MODULE}")
          wait_for_patch(machine, RELEASED_V1_NAME, 1)
          start_stress(machine)
          released_v1_before = stress_counts(machine)
          wait_for_stress_advance(machine, released_v1_before)
          stop_stress(machine)

          replacement_state = start_fuse_helper(
            machine,
            "replacement",
            "writeback",
            "reply"
          )
          machine.wait_until_succeeds(
            "test -e #{replacement_state}/ready",
            timeout: 30
          )
          set_offset_probe(
            machine,
            "fuse_copy_page",
            RELEASED_V1_NAME,
            FUSE_REF_PAGE_FINISH_CALL_OFFSET
          )
          machine.succeeds(
            "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_hold'; " \
            "touch #{replacement_state}/start"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = Y && " \
            "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" = 1",
            timeout: 30
          )

          machine.succeeds("insmod #{CORRECTED_MODULE}")
          machine.wait_until_succeeds(
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/enabled)\" = 1 && " \
            "test \"$(cat #{patch_dir(CORRECTED_NAME)}/transition)\" = 1",
            timeout: 30
          )
          machine.succeeds(
            "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_hold'"
          )
          machine.wait_until_succeeds(
            "test \"$(cat #{PROBE_PARAMETERS}/probe_held)\" = N && " \
            "test -e #{replacement_state}/completed",
            timeout: 30
          )
          clear_probe(machine)
          wait_for_patch(machine, CORRECTED_NAME, 1)
          wait_for_patch(machine, RELEASED_V1_NAME, 0)
          start_stress(machine)
          corrected_before = stress_counts(machine)
          wait_for_stress_advance(machine, corrected_before)

          machine.succeeds("rmmod #{RELEASED_V1_NAME}")
          machine.fails("test -d /sys/module/#{RELEASED_V1_NAME}")
          downgrade_log_start =
            machine.succeeds("dmesg | wc -l")[1].to_i + 1
          status, output = machine.execute(
            "insmod #{PREDECESSOR_MODULE}"
          )
          expect(status).not_to eq(0), output
          machine.fails("test -d /sys/module/#{PREDECESSOR_NAME}")
          wait_for_patch(machine, CORRECTED_NAME, 1)
          wait_for_patch(machine, PREDECESSOR_NAME, 0)
          machine.succeeds(
            "dmesg | tail -n +#{downgrade_log_start} | grep -F " \
            "'Livepatch patch (#{PREDECESSOR_NAME}) is not compatible with the already installed livepatches.'"
          )

          stop_stress(machine)
          disable_patch(machine, CORRECTED_NAME)
          remove_module(machine, CORRECTED_NAME)
          remove_module(machine, RELEASED_V1_NAME)
          remove_module(machine, PREDECESSOR_NAME)
          cleanup_fuse_workloads(machine)
        end

        it "keeps transition workloads and the kernel healthy" do
          _, dmesg = machine.succeeds("dmesg | tail -n +#{@dmesg_start}")
          expect(dmesg).not_to match(KERNEL_FAULT_PATTERN)
          machine.succeeds("nft list tables")
          machine.succeeds("ipset list -n")
        end
      end
    '';
  }
)
