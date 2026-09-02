import ../../make-test.nix (
  { pkgs }:
  let
    makeMachine =
      moduleAutoloadEnable:
      import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          { ... }:
          {
            boot.kernel.moduleAutoload.enable = moduleAutoloadEnable;
          };
      };
  in
  {
    name = "kernel-module-autoload";

    description = ''
      Test kernel module autoloading from containers
    '';

    tags = [ "ci" ];

    machines = {
      autoload_disabled = makeMachine false;
      autoload_enabled = makeMachine true;
    };

    testScript = ''
      require 'shellwords'

      kernel_params = ["osctl.cgroupv=2"]

      def self.ensure_machine(machine, kernel_params)
        if machine.running? && machine.start_kernel_params != kernel_params
          machine.stop
        end

        machine.start(kernel_params:) unless machine.running?
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online
        machine.wait_for_service("rsyslog")
      end

      def self.modprobe_path(machine)
        machine.succeeds("cat /proc/sys/kernel/modprobe")[1].strip
      end

      def self.loaded_modules(machine)
        machine.succeeds("awk '{ print $1 }' /proc/modules | sort")[1]
          .strip
          .split("\n")
          .reject(&:empty?)
      end

      def self.module_loaded?(machine, mod)
        machine.execute("test -d /sys/module/#{mod}")[0] == 0
      end

      def self.expect_logged_modprobe(machine, action, text)
        log_message = "kernel.modprobe: action=#{action} #{text}"

        machine.wait_until_succeeds(
          "grep -F -m 1 -- #{Shellwords.escape(log_message)} /var/log/messages",
          timeout: 30
        )
      end

      def self.cleanup_probe(machine, ctid, probe)
        ct_exec(machine, ctid, probe[:cleanup])
      end

      def self.unload_probe_module(machine, mod)
        machine.succeeds("modprobe -r #{mod} >/dev/null 2>&1 || true")
        expect(module_loaded?(machine, mod)).to be(false)
      end

      def self.ct_exec(machine, ctid, command)
        machine.execute("osctl ct exec #{ctid} sh -lc #{Shellwords.escape(command)}")
      end

      def self.run_probe(machine, ctid, probe)
        ct_exec(machine, ctid, probe[:command])
      end

      def self.expect_enabled_probe(machine, ctid, probe)
        cleanup_probe(machine, ctid, probe)
        unload_probe_module(machine, probe[:module])

        status, output = run_probe(machine, ctid, probe)
        expect(status).to eq(0), output
        expect(module_loaded?(machine, probe[:module])).to be(true)

        cleanup_probe(machine, ctid, probe)
        unload_probe_module(machine, probe[:module])
      end

      def self.expect_disabled_probe(machine, ctid, probe)
        cleanup_probe(machine, ctid, probe)
        unload_probe_module(machine, probe[:module])

        before = loaded_modules(machine)
        status, output = run_probe(machine, ctid, probe)
        cleanup_probe(machine, ctid, probe)

        expect(status).not_to eq(0), output

        after = loaded_modules(machine)
        new_modules = after - before
        expect(new_modules).to eq([]), "unexpected modules loaded: #{new_modules.join(', ')}"
        expect(module_loaded?(machine, probe[:module])).to be(false)
      end

      def self.verify_shaper(machine, ctid)
        _, output = machine.succeeds("osctl -p ct netif ls -H -o veth,max_tx,max_rx #{ctid}")
        veth, max_tx, max_rx = output.strip.split

        expect(veth).not_to be_nil
        expect(max_tx.to_i).to be > 0
        expect(max_rx.to_i).to be > 0

        _, qdisc = machine.succeeds("tc qdisc show dev #{veth}")
        expect(qdisc).to include("cake")
        expect(qdisc).to include("ingress")

        _, filters = machine.succeeds("tc filter show dev #{veth} ingress")
        expect(filters).to include("mirred")

        machine.succeeds("ip link show ifb#{veth}")

        _, ifb_qdisc = machine.succeeds("tc qdisc show dev ifb#{veth}")
        expect(ifb_qdisc).to include("cake")
      end

      def self.setup_container(machine, ctid)
        machine.succeeds("osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true")
        machine.all_succeed(
          "osctl ct new --distribution alpine --version latest #{ctid}",
          "osctl ct unset start-menu #{ctid}",
          "osctl ct netif new bridge --link lxcbr0 --max-tx 10M --max-rx 20M #{ctid} eth0",
          "osctl ct set dns-resolver #{ctid} 1.1.1.1",
          "osctl ct start #{ctid}",
        )
        machine.wait_until_succeeds("osctl ct exec #{ctid} sh -lc true", timeout: 180)
        container_apk(
          machine,
          ctid,
          'add',
          'iproute2',
          'iproute2-tc',
          'iptables',
          'iptables-legacy',
          'nftables',
          'python3',
          name: "Install network tools in #{ctid}",
          global_options: ['--no-cache']
        )
      end

      def self.cleanup_container(machine, ctid)
        machine.all_succeed(
          "osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true",
          "osctl repository images prune",
        )
      end

      def self.iptables_command(command)
        "set -e; " \
        "iptables=$(command -v iptables-legacy); " \
        "test -n \"$iptables\"; " \
        "export XTABLES_LOCKFILE=/tmp/module-autoload-xtables.lock; " \
        "#{command}"
      end

      def self.nft_command(*lines)
        "printf '%s\n' #{lines.map { |line| Shellwords.escape(line) }.join(' ')} | nft -f -"
      end

      def self.python_command(script)
        "python3 -c #{Shellwords.escape(script)}"
      end

      probes = [
        {
          name: "rtnetlink dummy",
          module: "dummy",
          command: "ip link add modauto0 type dummy",
          cleanup: "ip link del modauto0 >/dev/null 2>&1 || true",
        },
        {
          name: "tc netem",
          module: "sch_netem",
          command: "tc qdisc replace dev eth0 root netem delay 1ms",
          cleanup: "tc qdisc del dev eth0 root >/dev/null 2>&1 || true",
        },
        {
          name: "iptables xt_recent",
          module: "xt_recent",
          command: iptables_command(
            "\"$iptables\" -w -N MODAUTO_TEST; " \
            "\"$iptables\" -w -A MODAUTO_TEST -m recent --name modautoload --set -j ACCEPT"
          ),
          cleanup: iptables_command(
            "\"$iptables\" -w -F MODAUTO_TEST >/dev/null 2>&1 || true; " \
            "\"$iptables\" -w -X MODAUTO_TEST >/dev/null 2>&1 || true"
          ),
        },
        {
          name: "nftables limit",
          module: "nft_limit",
          command: nft_command(
            "add table inet MODAUTO_TEST",
            "add chain inet MODAUTO_TEST input { type filter hook input priority 0; policy accept; }",
            "add rule inet MODAUTO_TEST input limit rate 1/second accept"
          ),
          cleanup: "nft delete table inet MODAUTO_TEST >/dev/null 2>&1 || true",
        },
        {
          name: "AF_ALG AEAD socket",
          module: "algif_aead",
          command: python_command(
            "import socket; " \
            "s = socket.socket(socket.AF_ALG, socket.SOCK_SEQPACKET, 0); " \
            "s.bind(('aead', 'gcm(aes)')); " \
            "s.close()"
          ),
          cleanup: "true",
        },
      ]

      describe 'alpine-latest', order: :defined do
        before(:suite) do
          @ctid = get_container_id

          machines.each do |_, machine|
            ensure_machine(machine, kernel_params)
          end
        end

        after(:suite) do
          if @ctid
            cleanup_container(autoload_disabled, @ctid) if autoload_disabled.running?
            cleanup_container(autoload_enabled, @ctid) if autoload_enabled.running?
          end
        end

        it 'configures kernel.modprobe from boot.kernel.moduleAutoload' do
          disabled_path = modprobe_path(autoload_disabled)
          enabled_path = modprobe_path(autoload_enabled)

          expect(disabled_path).not_to be_empty
          expect(enabled_path).not_to be_empty
          expect(disabled_path).not_to eq(enabled_path)

          autoload_disabled.succeeds("test -x #{Shellwords.escape(disabled_path)}")
          autoload_enabled.succeeds("test -x #{Shellwords.escape(enabled_path)}")
        end

        it 'keeps kernel.modprobe wrappers after activation' do
          disabled_path = modprobe_path(autoload_disabled)
          enabled_path = modprobe_path(autoload_enabled)

          autoload_disabled.succeeds("/run/current-system/activate")
          autoload_enabled.succeeds("/run/current-system/activate")

          expect(modprobe_path(autoload_disabled)).to eq(disabled_path)
          expect(modprobe_path(autoload_enabled)).to eq(enabled_path)
        end

        it 'logs module requests through kernel.modprobe wrappers' do
          disabled_path = modprobe_path(autoload_disabled)
          enabled_path = modprobe_path(autoload_enabled)

          unload_probe_module(autoload_disabled, "bonding")
          status, output = autoload_disabled.execute("#{Shellwords.escape(disabled_path)} bonding")
          expect(status).not_to eq(0), output
          expect(module_loaded?(autoload_disabled, "bonding")).to be(false)
          expect_logged_modprobe(autoload_disabled, "deny", "bonding")

          unload_probe_module(autoload_enabled, "bonding")
          autoload_enabled.succeeds("#{Shellwords.escape(enabled_path)} bonding")
          expect(module_loaded?(autoload_enabled, "bonding")).to be(true)
          expect_logged_modprobe(autoload_enabled, "load", "bonding")
          autoload_enabled.succeeds("modprobe -r bonding")
        end

        it 'keeps explicit host modprobe working' do
          [autoload_disabled, autoload_enabled].each do |machine|
            unload_probe_module(machine, "bonding")
            machine.succeeds("modprobe bonding")
            expect(module_loaded?(machine, "bonding")).to be(true)
            machine.succeeds("modprobe -r bonding")
            expect(module_loaded?(machine, "bonding")).to be(false)
          end
        end

        it 'starts containers with shaped bridge interfaces' do
          setup_container(autoload_disabled, @ctid)
          setup_container(autoload_enabled, @ctid)

          verify_shaper(autoload_disabled, @ctid)
          verify_shaper(autoload_enabled, @ctid)
        end

        probes.each do |probe|
          it "blocks #{probe[:name]} autoload when disabled" do
            expect_disabled_probe(autoload_disabled, @ctid, probe)
          end

          it "allows #{probe[:name]} autoload when enabled" do
            expect_enabled_probe(autoload_enabled, @ctid, probe)
          end
        end

        it 'lets an admin toggle autoloading with kernel.modprobe at runtime' do
          probe = probes[0]
          modprobe = autoload_disabled.succeeds("command -v modprobe")[1].strip

          autoload_disabled.succeeds("sysctl -w kernel.modprobe=#{Shellwords.escape(modprobe)}")
          expect_enabled_probe(autoload_disabled, @ctid, probe)

          autoload_disabled.succeeds("sysctl -w kernel.modprobe=")
          expect_disabled_probe(autoload_disabled, @ctid, probe)
        end
      end
    '';
  }
)
