import ../../make-test.nix (
  { pkgs }:
  let
    policy =
      limit: extra:
      { lib, ... }:
      {
        boot.zfs.pools = { };
        boot.kernel.sysctl."kernel.printk_ratelimit" = lib.mkForce limit;
      }
      // extra;

    extraFile = target: value: {
      environment.etc.sysctl-test-alias = {
        inherit target;
        text = "vm.vfs_cache_pressure=${toString value}\n";
      };
    };

    withFiles =
      limit: value: target:
      policy limit (
        pkgs.lib.recursiveUpdate (extraFile target value) {
          environment.etc."sysctl.conf".text = "kernel.printk_ratelimit=${toString (limit + 1)}\n";
        }
      );

    switched =
      module:
      (import ../../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          modules = [
            ../../configs/vpsadminos/base.nix
            module
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;

    added = switched (withFiles 8 111 "sysctl.d/80-os-test.conf");
    changed = switched (withFiles 10 112 "sysctl.d/80-os-test.conf");
    renamed = switched (withFiles 10 112 "sysctl.d/81-os-test.conf");
    removed = switched (policy null { });
    failing = switched (
      policy 12 {
        environment.etc."sysctl.d/99-os-test.conf".text = ''
          vm.vfs_cache_pressure=113
          kernel.printk_ratelimit=invalid
        '';
      }
    );
  in
  {
    name = "system-sysctl";
    description = "Apply managed sysctls on boot and configuration changes";
    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config = {
        imports = [ (policy 7 { }) ];
        system.extraDependencies = [
          added
          changed
          renamed
          removed
          failing
        ];
      };
    };

    testScript = ''
      require 'shellwords'

      def value(key)
        machine.succeeds("sysctl -n #{Shellwords.escape(key)}")[1].strip.to_i
      end

      def attempts
        machine.succeeds(
          "grep -F -c 'Applying /etc/sysctl.d/60-nixos.conf' /var/log/sysctl/current || true"
        )[1].strip.to_i
      end

      def wait_for_attempt(previous)
        machine.wait_until_succeeds(
          "test $(grep -F -c 'Applying /etc/sysctl.d/60-nixos.conf' /var/log/sysctl/current) -gt #{previous}",
          timeout: 30
        )
        machine.wait_until_succeeds("sv status sysctl | grep -q '^down:'", timeout: 30)
        expect(attempts).to eq(previous + 1)
      end

      def switch_to(system, action = 'test')
        previous = attempts
        _, output = machine.succeeds("#{system}/bin/switch-to-configuration #{action}")
        wait_for_attempt(previous)
        output
      end

      def retry_sysctl
        previous = attempts
        machine.succeeds(<<~CMD)
          set -e
          sv stop sysctl
          sv status sysctl | grep -q '^down:'
          rm -f /run/service/sysctl/applied /run/service/sysctl/done
          sv once sysctl
        CMD
        wait_for_attempt(previous)
      end

      before(:suite) do
        machine.start(wait_for_boot: true)
        machine.wait_until_succeeds('/service/sysctl/check', timeout: 60)
        machine.wait_until_succeeds("sv status sysctl | grep -q '^down:'", timeout: 30)
      end

      describe 'generic sysctl service', order: :defined do
        it 'retains early boot application and deliberately applies again as a service' do
          expect(machine.console_output).to include('Applying /etc/sysctl.d/60-nixos.conf')
          expect(attempts).to eq(1)
          expect(value('kernel.printk_ratelimit')).to eq(7)
          machine.succeeds('/service/sysctl/check')
          machine.succeeds('test -f /run/service/sysctl/done')
        end

        it 'keeps a manual override when managed inputs are unchanged' do
          current = machine.succeeds('readlink -f /run/current-system')[1].strip
          before = attempts
          stamp = machine.succeeds('cat /run/service/sysctl/applied')[1]
          machine.succeeds('sysctl -w kernel.printk_ratelimit=6')
          _, output = machine.succeeds("#{current}/bin/switch-to-configuration test")
          expect(output).not_to include('> sv stop sysctl')
          expect(output).not_to include('> sv start sysctl')
          expect(value('kernel.printk_ratelimit')).to eq(6)
          expect(attempts).to eq(before)
          expect(machine.succeeds('cat /run/service/sysctl/applied')[1]).to eq(stamp)
          machine.succeeds('/service/sysctl/check')
        end

        it 'rejects an older generation stamp and does not apply during dry or boot actions' do
          before = attempts
          machine.fails('${added}/etc/runit/services/sysctl/check')
          machine.succeeds('test -f /run/service/sysctl/done')
          _, output = machine.succeeds('${added}/bin/switch-to-configuration dry-activate')
          expect(output).to include('> sv start sysctl')
          machine.succeeds('${added}/bin/switch-to-configuration boot')
          expect(value('kernel.printk_ratelimit')).to eq(6)
          expect(attempts).to eq(before)
        end

        it 'adds managed files by effective target and honors procps precedence on test' do
          output = switch_to('${added}')
          expect(output).to include('> sv start sysctl')
          expect(value('kernel.printk_ratelimit')).to eq(9)
          expect(value('vm.vfs_cache_pressure')).to eq(111)
          machine.succeeds('test -f /etc/sysctl.d/80-os-test.conf')
          machine.succeeds('/service/sysctl/check')
        end

        it 'changes managed contents on switch and detects a target-only rename' do
          switch_to('${changed}', 'switch')
          expect(value('kernel.printk_ratelimit')).to eq(11)
          expect(value('vm.vfs_cache_pressure')).to eq(112)
          before = machine.succeeds('cat /run/service/sysctl/applied')[1]
          switch_to('${renamed}')
          expect(machine.succeeds('cat /run/service/sysctl/applied')[1]).not_to eq(before)
          machine.succeeds('test ! -e /etc/sysctl.d/80-os-test.conf')
          machine.succeeds('test -f /etc/sysctl.d/81-os-test.conf')
          expect(value('vm.vfs_cache_pressure')).to eq(112)
          machine.succeeds('/service/sysctl/check')
        end

        it 'detects file removal and null values without resetting live values' do
          switch_to('${removed}')
          machine.succeeds('test ! -e /etc/sysctl.d/81-os-test.conf')
          machine.succeeds('test ! -e /etc/sysctl.conf')
          machine.fails('grep -q kernel.printk_ratelimit /etc/sysctl.d/60-nixos.conf')
          expect(value('kernel.printk_ratelimit')).to eq(11)
          expect(value('vm.vfs_cache_pressure')).to eq(112)
          machine.succeeds('/service/sysctl/check')
        end

        it 'reports a partial failure after success without retaining stale success or retrying' do
          switch_to('${failing}')
          expect(value('kernel.printk_ratelimit')).to eq(12)
          expect(value('vm.vfs_cache_pressure')).to eq(113)
          machine.fails('/service/sysctl/check')
          machine.succeeds('test ! -e /run/service/sysctl/applied')
          machine.succeeds('test ! -e /run/service/sysctl/done')
          machine.succeeds(%q{grep -Fq 'setting key "kernel.printk_ratelimit"' /var/log/sysctl/current})
          machine.succeeds("grep -Fq 'Unable to apply sysctl configuration' /var/log/sysctl/current")
          before = attempts
          machine.succeeds('sysctl -w vm.vfs_cache_pressure=114')
          machine.succeeds('sleep 3')
          expect(attempts).to eq(before)
          expect(value('vm.vfs_cache_pressure')).to eq(114)
        end

        it 'supports explicit successful and failed retries of the same managed generation' do
          # A local repair is read on retry without changing the managed identity.
          machine.succeeds(<<~CMD)
            set -e
            rm /etc/sysctl.d/99-os-test.conf
            echo vm.vfs_cache_pressure=115 > /etc/sysctl.d/99-os-test.conf
          CMD
          retry_sysctl
          machine.succeeds('/service/sysctl/check')
          expect(value('vm.vfs_cache_pressure')).to eq(115)

          machine.succeeds('echo kernel.printk_ratelimit=invalid >> /etc/sysctl.d/99-os-test.conf')
          retry_sysctl
          machine.fails('/service/sysctl/check')
          machine.succeeds('test ! -e /run/service/sysctl/applied')
          machine.succeeds('test ! -e /run/service/sysctl/done')
          before = attempts
          machine.succeeds('sleep 3')
          expect(attempts).to eq(before)
        end
      end
    '';
  }
)
