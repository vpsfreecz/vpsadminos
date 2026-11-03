import ../../make-test.nix (
  { pkgs }:
  let
    fixtures = import ../../fixtures/livepatch { inherit pkgs; };
    module = builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_MODULE";
    expectedSha256 = builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_SHA256";
    sitesEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_SITES";
    sitesFile = "${builtins.storePath sitesEnv}/sites.json";
    siteRecord = builtins.fromJSON (builtins.readFile sitesFile);
  in
  assert module != "";
  assert expectedSha256 != "";
  assert sitesEnv != "";
  assert builtins.hashFile "sha256" (builtins.storePath module) == expectedSha256;
  assert siteRecord.schema_version == 1;
  assert siteRecord.module_sha256 == expectedSha256;
  {
    name = "kernel-livepatch-inet-frag";
    description = "Observe native and v7 fragment-queue timer/hash/lock ordering";
    tags = [
      "livepatch-amd"
      "livepatch-intel"
    ];
    machine = (
      import ../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config = { lib, ... }: {
          imports = [ ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix ];
          services.live-patches.enable = lib.mkForce false;
          boot.qemu = {
            cpus = lib.mkForce 2;
            memory = lib.mkForce 2048;
            cpu.cores = lib.mkForce 2;
            cpu.threads = lib.mkForce 1;
            cpu.sockets = lib.mkForce 1;
          };
          environment.systemPackages = [
            pkgs.iproute2
            pkgs.kmod
          ];
          environment.etc = {
            "livepatch-inet-frag/module.ko".source = builtins.storePath module;
            "livepatch-inet-frag/sites.json".source = sitesFile;
            "livepatch-inet-frag/fragment".source = "${fixtures.ipv6FragmentPartial}/bin/ipv6_fragment_partial";
          };
        };
      }
    );
    testScript = ''
      require 'json'

      MODULE_FILE = '/etc/livepatch-inet-frag/module.ko'
      MODULE_SHA256 = ${builtins.toJSON expectedSha256}
      SITE_RECORD = JSON.parse(${builtins.toJSON (builtins.readFile sitesFile)}).freeze
      SITES_SHA256 = ${builtins.toJSON (builtins.hashFile "sha256" sitesFile)}
      TRACE = '/sys/kernel/tracing/instances/lp_inet_frag'
      PATCH = '/sys/kernel/livepatch/livepatch_7'
      FAULTS = /BUG:|WARNING:|Oops:|general protection fault|[Kk]ernel panic|KASAN|UBSAN|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall/

      def validate_site_record
        required = %w[svm_entry nft_insert_entry sunrpc_worker_entry fuse_finish sunrpc_shadow_alloc sunrpc_callback_claim sunrpc_callback_release inet_frag_timer tcp_mtu_size]
        site = SITE_RECORD.fetch('sites').fetch('inet_frag_timer')
        abi = SITE_RECORD.fetch('abi')
        unless SITE_RECORD.fetch('schema_version') == 1 &&
               SITE_RECORD.fetch('module_sha256') == MODULE_SHA256 &&
               MODULE_SHA256.match?(/\A[0-9a-f]{64}\z/) &&
               SITE_RECORD.fetch('sites').keys.sort == required.sort &&
               SITE_RECORD.fetch('elf').fetch('elf_class') == 64 &&
               SITE_RECORD.fetch('elf').fetch('machine') == 'EM_X86_64' &&
               site.fetch('object') == 'livepatch_7' && %w[inet_frag_find inet_frag_create].include?(site.fetch('symbol')) &&
               site.fetch('symbol_pos') == 0 && site.fetch('section').match?(/\A\.text(?:[.a-zA-Z0-9_]*)\z/) &&
               site.fetch('kind') == 'call_observe' && site.fetch('frame') == 'observe_only' &&
               site.fetch('inline') == 'inet_frag_create' &&
               site.fetch('registers').fetch('arg0') == { 'register' => 'rdi', 'width' => 64 } &&
               site.fetch('callee') == { 'object' => 'vmlinux', 'symbol' => 'mod_timer', 'symbol_pos' => 0 } &&
               site.fetch('symbol_size').is_a?(Integer) && site.fetch('symbol_size').between?(1, 16777216) &&
               site.fetch('offset').is_a?(Integer) && site.fetch('offset') >= 0 &&
               site.fetch('instruction_length').is_a?(Integer) && site.fetch('instruction_length').between?(1, 15) &&
               site.fetch('offset') + site.fetch('instruction_length') <= site.fetch('symbol_size') &&
               abi.keys.sort == %w[inet_frag_lock inet_frag_node inet_frag_timer sock_xprt_connect_worker] &&
               abi.values.all? { |offset| offset.is_a?(Integer) && offset.between?(0, 65535) } &&
               abi.fetch('inet_frag_node') < abi.fetch('inet_frag_timer') && abi.fetch('inet_frag_timer') < abi.fetch('inet_frag_lock')
          raise 'invalid current fragment timer site or structure ABI'
        end
      end

      def symbol_address(name, module_name = nil)
        scope = module_name ? "NF == 4 && $4 == \"[#{module_name}]\"" : 'NF == 3'
        # /proc/kallsyms prints resolved SHN_UNDEF module imports as U or u.
        addresses = machine.succeeds("awk '$2 !~ /^[Uu]$/ && $3 == \"#{name}\" && #{scope} { print $1 }' /proc/kallsyms")[1].lines.map(&:strip)
        unless addresses.length == 1 && addresses.first.match?(/\A[0-9a-fA-F]+\z/) && Integer(addresses.first, 16) > 0
          raise "missing or ambiguous symbol #{name} #{module_name}: #{addresses.inspect}"
        end
        Integer(addresses.first, 16)
      end

      def assert_unpatched
        machine.all_succeed(
          'test "$(uname -r)" = 6.12.95',
          'test -d /sys/kernel/livepatch',
          'test -z "$(find /sys/kernel/livepatch -mindepth 1 -maxdepth 1 -print -quit)"',
          'test -z "$(find /sys/module -maxdepth 1 -name "livepatch_[0-9]*" -print -quit)"',
          'uname -a; ls -la /sys/kernel/livepatch; cat /proc/modules',
        )
      end

      def observe_timer(phase, address, hashed:)
        # The resolver checks these member layouts against the SDK and module.
        abi = SITE_RECORD.fetch('abi')
        node_delta = abi.fetch('inet_frag_node') - abi.fetch('inet_frag_timer')
        lock_delta = abi.fetch('inet_frag_lock') - abi.fetch('inet_frag_timer')
        event = "#{phase}_timer"
        # The existing helper derives the fragment ID from this port. Distinct
        # IDs ensure the target creates a queue rather than finding the old one.
        port = hashed ? 49153 : 49152
        machine.all_succeed(
          "echo 'p:lp_inet_frag/#{event} 0x#{address.to_s(16)} timer=%di:x64 next=#{format('%+d', node_delta)}(%di):x64 lock=#{format('%+d', lock_delta)}(%di):u32' >> /sys/kernel/tracing/kprobe_events",
          "echo > #{TRACE}/trace",
          "echo 1 > #{TRACE}/events/lp_inet_frag/#{event}/enable",
          "echo 1 > #{TRACE}/tracing_on",
          "/etc/livepatch-inet-frag/fragment klpf_tx 02:00:00:00:08:01 02:00:00:00:08:02 2001:db8:8::1 2001:db8:8::2 #{port}",
        )
        machine.wait_until_succeeds("grep -q '#{event}:' #{TRACE}/trace", timeout: 30)
        machine.all_succeed("echo 0 > #{TRACE}/tracing_on", "echo 0 > #{TRACE}/events/lp_inet_frag/#{event}/enable")
        output = machine.succeeds("cat #{TRACE}/trace")[1]
        puts "#{phase.upcase} inet-frag timer call observations:\n#{output}"
        rows = output.lines.select { |line| line.include?("#{event}:") }
        expect(rows.length).to be > 0
        rows.each do |line|
          match = /timer=(0x[0-9a-f]+) next=(0x[0-9a-f]+) lock=(\d+)/i.match(line)
          raise "unparsed #{phase} observation: #{line}" unless match
          expect(Integer(match[1], 16)).to be > 0
          next_node = Integer(match[2], 16)
          lock = Integer(match[3], 10)
          if hashed
            expect(next_node).to be > 0
            expect(lock & 1).to eq(1)
          else
            expect(next_node).to eq(0)
            expect(lock).to eq(0)
          end
        end
        # Losing probe hits is not acceptable evidence for either phase.
        profile = machine.succeeds("awk '$1 ~ /#{event}$/ { print $2, $3 }' /sys/kernel/tracing/kprobe_profile")[1].split
        expect(profile.length).to eq(2)
        expect(Integer(profile[0])).to eq(rows.length)
        expect(Integer(profile[1])).to eq(0)
        machine.succeeds("echo '-:lp_inet_frag/#{event}' >> /sys/kernel/tracing/kprobe_events")
      end

      before(:suite) do
        validate_site_record
        machine.start
        machine.wait_until_online
        machine.succeeds("test \"$(sha256sum #{MODULE_FILE} | cut -d' ' -f1)\" = #{MODULE_SHA256}")
        machine.succeeds("test \"$(sha256sum /etc/livepatch-inet-frag/sites.json | cut -d' ' -f1)\" = #{SITES_SHA256}")
      end

      after(:suite) do
        if machine.running? && !@completed
          ['dmesg | tail -n 100', "cat #{TRACE}/trace", 'cat /sys/kernel/tracing/kprobe_profile',
           'find /sys/kernel/livepatch -maxdepth 3 -type f -print'].each do |command|
            begin
              machine.execute(command, timeout: 15)
            rescue StandardError => e
              warn("inet-frag diagnostic failed: #{e.class}: #{e.message}")
            end
          end
        end
      end

      describe 'Generic inet fragment-queue creation', order: :defined do
        it 'arms the timer only after locked hash insertion under v7, unlike the native baseline' do
          assert_unpatched
          dmesg_start = Integer(machine.succeeds('dmesg | wc -l')[1].strip) + 1
          machine.all_succeed(
            'modprobe veth',
            'mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing',
            "mkdir #{TRACE}",
            'ip netns add klpf_ns',
            'ip link add klpf_tx type veth peer name klpf_rx',
            'ip link set klpf_rx netns klpf_ns',
            'ip link set klpf_tx address 02:00:00:00:08:01 up',
            'ip -n klpf_ns link set lo up',
            'ip -n klpf_ns link set klpf_rx address 02:00:00:00:08:02 up',
            'ip -6 addr add 2001:db8:8::1/64 dev klpf_tx nodad',
            'ip -n klpf_ns -6 addr add 2001:db8:8::2/64 dev klpf_rx nodad',
          )
          # a2384967 frozen vmlinux: call at 81d7ff4f, function at 81d7fd20.
          puts 'VULNERABLE BASELINE: timer registration before hashing, without the queue lock'
          observe_timer('native', symbol_address('inet_frag_find') + 0x22f, hashed: false)
          assert_unpatched
          machine.succeeds("insmod #{MODULE_FILE}", timeout: 300)
          machine.wait_until_succeeds("test \"$(cat #{PATCH}/enabled)\" = 1 && test \"$(cat #{PATCH}/transition)\" = 0", timeout: 300)
          puts 'TARGET: inserted hash node and held queue lock at timer registration'
          site = SITE_RECORD.fetch('sites').fetch('inet_frag_timer')
          observe_timer('target', symbol_address(site.fetch('symbol'), site.fetch('object')) + site.fetch('offset'), hashed: true)
          machine.succeeds("echo 0 > #{PATCH}/enabled", timeout: 300)
          machine.wait_until_succeeds("test ! -e #{PATCH}", timeout: 300)
          machine.all_succeed('rmmod livepatch_7', 'ip netns del klpf_ns', "rmdir #{TRACE}")
          assert_unpatched
          expect(machine.succeeds("dmesg | tail -n +#{dmesg_start}")[1]).not_to match(FAULTS)
          @completed = true
        end
      end
    '';
  }
)
