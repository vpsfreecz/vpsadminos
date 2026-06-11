import ../../make-test.nix (
  { pkgs }:
  let
    triggerA = pkgs.writeText "runit-restart-trigger-a" "a";
    triggerB = pkgs.writeText "runit-restart-trigger-b" "b";
    removedModule = "bonding";
    addedModule = "macvlan";
    keptModule = "8021q";
    failedModule = "vpsadminos_missing_test_module";

    testService = trigger: {
      runit.services.restart-trigger-test = {
        run = ''
          ${pkgs.coreutils}/bin/mkdir -p /run/restart-trigger-test
          echo started > /run/restart-trigger-test/state
          exec ${pkgs.coreutils}/bin/sleep 3600
        '';
        restartTriggers = [ trigger ];
      };
    };

    nextSystem =
      (import ../../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            (testService triggerB)
            {
              boot.kernelModules = [
                addedModule
                keptModule
                failedModule
              ];
            }
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;

    nextFirewallSystem =
      (import ../../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            (testService triggerA)
            {
              networking.firewall.logRefusedConnections = true;
            }
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;
  in
  {
    name = "system-switch-to-configuration";

    description = ''
      Test switch-to-configuration service restart decisions
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        imports = [ (testService triggerA) ];
        boot.kernelModules = [
          removedModule
          keptModule
          failedModule
        ];
        system.extraDependencies = [
          nextSystem
          nextFirewallSystem
        ];
      };
    };

    testScript = ''
      require 'shellwords'

      describe 'switch-to-configuration', order: :defined do
        tracked_module_state = lambda do
          _, output = machine.succeeds(<<~CMD)
            set -e
            for module in ${removedModule} ${addedModule} ${keptModule} ${failedModule}; do
              if lsmod | awk '{print $1}' | grep -qx "$module"; then
                state=loaded
              else
                state=absent
              fi
              printf '%s=%s\\n' "$module" "$state"
            done
          CMD

          output.lines.map { |line| line.strip.split('=', 2) }.to_h
        end

        service_log_contains = lambda do |pattern|
          machine.wait_until_succeeds(
            "grep -R -q #{Shellwords.escape(pattern)} /var/log/kernel-modules"
          )
        end

        service_log_not_contains = lambda do |pattern|
          machine.succeeds(
            "! grep -R -q #{Shellwords.escape(pattern)} /var/log/kernel-modules"
          )
        end

        syslog_contains = lambda do |pattern|
          machine.wait_until_succeeds(
            "grep -F #{Shellwords.escape(pattern)} /var/log/messages | grep -Fq kernel-modules"
          )
        end

        syslog_not_contains = lambda do |pattern|
          machine.succeeds(
            "if grep -F #{Shellwords.escape(pattern)} /var/log/messages | grep -Fq kernel-modules; then exit 1; else exit 0; fi"
          )
        end

        log_contains = lambda do |pattern|
          service_log_contains.call(pattern)
          syslog_contains.call(pattern)
        end

        log_not_contains = lambda do |pattern|
          service_log_not_contains.call(pattern)
          syslog_not_contains.call(pattern)
        end

        before(:context) do
          machine.start
          machine.wait_for_service('rsyslog')
          machine.wait_for_service('restart-trigger-test')
          machine.wait_for_service('kernel-modules')
        end

        it 'restarts a service when only restartTriggers change' do
          machine.wait_until_succeeds('test -f /run/restart-trigger-test/state')

          _, current_run = machine.succeeds('readlink -f /etc/runit/services/restart-trigger-test/run')
          _, next_run = machine.succeeds('readlink -f ${nextSystem}/etc/runit/services/restart-trigger-test/run')

          expect(next_run.strip).to eq(current_run.strip)

          _, output = machine.succeeds('${nextSystem}/bin/switch-to-configuration dry-activate')

          expect(output).to include('> sv stop restart-trigger-test')
          expect(output).to include('> sv start restart-trigger-test')
        end

        it 'reloads the firewall when its kernel module requirements change' do
          _, output = machine.succeeds('${nextFirewallSystem}/bin/switch-to-configuration dry-activate')

          expect(output).to include('> sv 1 firewall')
          expect(output).not_to include('> sv stop firewall')
          expect(output).not_to include('> sv start firewall')
        end

        it 'updates loaded modules to match boot.kernelModules' do
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
          log_contains.call('loading module ${removedModule}')
          log_contains.call('loading module ${keptModule}')
          log_contains.call('failed to load module ${failedModule}')

          _, output = machine.succeeds('${nextSystem}/bin/switch-to-configuration test')

          expect(output).to include('> sv reload kernel-modules')
          machine.wait_for_service('kernel-modules')
          log_contains.call('loading module ${addedModule}')
          log_contains.call('unloading removed module ${removedModule}')
          log_not_contains.call('unloading removed module ${addedModule}')
          log_not_contains.call('unloading removed module ${keptModule}')
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'absent',
            '${addedModule}' => 'loaded',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end

        it 'does not unload modules when kernel-modules is stopped' do
          machine.succeeds('sv stop kernel-modules')
          log_not_contains.call('unloading module ${addedModule}')
          log_not_contains.call('unloading module ${keptModule}')

          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'absent',
            '${addedModule}' => 'loaded',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end
      end
    '';
  }
)
