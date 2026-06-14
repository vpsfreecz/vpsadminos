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

    switchedSystem =
      module:
      (import ../../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            (testService triggerB)
            module
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;

    nextSystem = switchedSystem {
      boot.kernelModules = [
        addedModule
        keptModule
        failedModule
      ];
    };

    unloadSystem = switchedSystem {
      boot.kernelModules = [
        keptModule
        failedModule
      ];
      boot.kernel.unloadRemovedModules = true;
    };

    loadDisabledSystem = switchedSystem {
      boot.kernelModules = [
        addedModule
        keptModule
        failedModule
      ];
      boot.kernel.loadNewModules = false;
    };

    moduleAndFirewallSystem = switchedSystem {
      boot.kernelModules = [
        addedModule
        keptModule
        failedModule
      ];
      networking.firewall.logRefusedConnections = true;
    };

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
          unloadSystem
          loadDisabledSystem
          moduleAndFirewallSystem
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

        clear_kernel_module_logs = lambda do
          machine.succeeds(<<~CMD)
            set -e
            if [ -d /var/log/kernel-modules ]; then
              find /var/log/kernel-modules -type f -exec truncate -s 0 {} +
            fi
            [ ! -e /var/log/messages ] || truncate -s 0 /var/log/messages
          CMD
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

        it 'keeps kernel-modules available while reloading firewall' do
          _, output = machine.succeeds('${moduleAndFirewallSystem}/bin/switch-to-configuration dry-activate')

          kernel_modules_reload = output.index('> sv reload kernel-modules')
          firewall_reload = output.index('> sv 1 firewall')

          expect(kernel_modules_reload).not_to be_nil
          expect(firewall_reload).not_to be_nil
          expect(kernel_modules_reload).to be < firewall_reload
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          expect(output).not_to include('> sv stop firewall')
          expect(output).not_to include('> sv start firewall')
        end

        it 'loads added modules without unloading removed modules by default' do
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
          log_contains.call('loading module ${removedModule}')
          log_contains.call('loading module ${keptModule}')
          log_contains.call('failed to load module ${failedModule}')
          clear_kernel_module_logs.call

          _, output = machine.succeeds('${nextSystem}/bin/switch-to-configuration test')

          expect(output).to include('> sv reload kernel-modules')
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          machine.wait_for_service('kernel-modules')
          log_contains.call('reloading kernel modules from service control')
          log_contains.call('loading module ${addedModule}')
          log_contains.call('not unloading removed kernel modules because boot.kernel.unloadRemovedModules is false')
          log_not_contains.call('unloading removed module ${removedModule}')
          log_not_contains.call('unloading removed module ${addedModule}')
          log_not_contains.call('unloading removed module ${keptModule}')
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'loaded',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end

        it 'unloads removed modules when enabled' do
          clear_kernel_module_logs.call

          _, output = machine.succeeds('${unloadSystem}/bin/switch-to-configuration test')

          expect(output).to include('> sv reload kernel-modules')
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          machine.wait_for_service('kernel-modules')
          log_contains.call('reloading kernel modules from service control')
          log_contains.call('unloading removed module ${addedModule}')
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end

        it 'does not load modules when loading is disabled' do
          clear_kernel_module_logs.call

          _, output = machine.succeeds('${loadDisabledSystem}/bin/switch-to-configuration test')

          expect(output).to include('> sv reload kernel-modules')
          expect(output).not_to include('> sv stop kernel-modules')
          expect(output).not_to include('> sv start kernel-modules')
          machine.wait_for_service('kernel-modules')
          log_contains.call('reloading kernel modules from service control')
          log_contains.call('not loading new kernel modules because boot.kernel.loadNewModules is false')
          log_not_contains.call('loading module ${addedModule}')
          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end

        it 'does not unload modules when kernel-modules is stopped' do
          machine.succeeds('sv stop kernel-modules')
          log_not_contains.call('unloading module ${addedModule}')
          log_not_contains.call('unloading module ${keptModule}')

          expect(tracked_module_state.call).to eq(
            '${removedModule}' => 'loaded',
            '${addedModule}' => 'absent',
            '${keptModule}' => 'loaded',
            '${failedModule}' => 'absent',
          )
        end
      end
    '';
  }
)
