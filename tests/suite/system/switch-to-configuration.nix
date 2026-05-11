import ../../make-test.nix (
  { pkgs }:
  let
    triggerA = pkgs.writeText "runit-restart-trigger-a" "a";
    triggerB = pkgs.writeText "runit-restart-trigger-b" "b";

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
      (import ../../../os {
        importedPkgs = pkgs;
        system = pkgs.system;
        modules = [
          ../../configs/vpsadminos/base.nix
          ../../configs/vpsadminos/pool-tank.nix
          (testService triggerB)
        ];
      }).config.system.build.toplevel;
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
        system.extraDependencies = [ nextSystem ];
      };
    };

    testScript = ''
      describe 'runit restart triggers', order: :defined do
        it 'restarts a service when only restartTriggers change' do
          machine.start
          machine.wait_for_service('restart-trigger-test')
          machine.wait_until_succeeds('test -f /run/restart-trigger-test/state')

          _, current_run = machine.succeeds('readlink -f /etc/runit/services/restart-trigger-test/run')
          _, next_run = machine.succeeds('readlink -f ${nextSystem}/etc/runit/services/restart-trigger-test/run')

          expect(next_run.strip).to eq(current_run.strip)

          _, output = machine.succeeds('${nextSystem}/bin/switch-to-configuration dry-activate')

          expect(output).to include('> sv stop restart-trigger-test')
          expect(output).to include('> sv start restart-trigger-test')
        end
      end
    '';
  }
)
