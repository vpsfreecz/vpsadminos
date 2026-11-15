args@{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
  ...
}:

let
  nixpkgs = import pkgs { inherit system; };
  recorder = nixpkgs.writeShellScript "livepatch-activation-recorder" ''
    root=/run/livepatch-activation
    ${nixpkgs.coreutils}/bin/mkdir -p "$root"
    count=0
    if [ -f "$root/count" ]; then
      count=$(${nixpkgs.coreutils}/bin/cat "$root/count")
    fi
    printf '%s\n' "$((count + 1))" > "$root/count"
    printf '%s\n' "$*" >> "$root/calls"
    if [ -e "$root/fail" ]; then
      exit 42
    fi
  '';
  fakeKpatchBuild = nixpkgs.writeText "livepatch-activation-kpatch-build" "fixture\n";
  livepatchTest = {
    catalog = [ ];
    kpatchBuild = fakeKpatchBuild;
    builder = {
      kpatchBuild = toString fakeKpatchBuild;
      kpatchRevision = "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
    };
    manager = recorder;
  };
  makeTest = import ../../make-test.nix (
    { pkgs }:
    let
      fixtureArgs = (pkgs.vpsadminosTestFrameworkInputs or { }) // {
        inherit livepatchTest;
      };
      switchedSystem =
        module:
        (import ../../../os {
          importedPkgs = pkgs;
          system = pkgs.system;
          extraArgs = fixtureArgs;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            module
          ];
        }).config.system.build.toplevel;
      defaultSystem = switchedSystem {
        services.live-patches.enable = true;
      };
      neitherSystem = switchedSystem {
        services.live-patches = {
          enable = true;
          loadOnBoot = false;
          loadOnSwitch = false;
        };
      };
      switchSystem = switchedSystem {
        services.live-patches = {
          enable = true;
          loadOnBoot = false;
          loadOnSwitch = true;
        };
      };
      bothSystem = switchedSystem {
        services.live-patches = {
          enable = true;
          loadOnBoot = true;
          loadOnSwitch = true;
        };
      };
    in
    {
      name = "system-livepatch-activation";

      description = ''
        Test boot and live-switch livepatch activation policy
      '';

      tags = [ "ci" ];

      machines = {
        machine = import ../../machines/vpsadminos/with-tank.nix {
          inherit pkgs;
          config = {
            services.live-patches.enable = true;
            runit.services.live-patches.runlevels = pkgs.lib.mkForce [ ];
            system.extraDependencies = [
              defaultSystem
              neitherSystem
              switchSystem
              bothSystem
            ];
          };
        };
        boot_off = import ../../machines/vpsadminos/with-tank.nix {
          inherit pkgs;
          config.services.live-patches = {
            enable = true;
            loadOnBoot = false;
            loadOnSwitch = false;
          };
        };
        both_on = import ../../machines/vpsadminos/with-tank.nix {
          inherit pkgs;
          config.services.live-patches = {
            enable = true;
            loadOnBoot = true;
            loadOnSwitch = true;
          };
        };
      };

      testScript = ''
        describe 'livepatch activation policy', order: :defined do
          activation_count = lambda do |target|
            _, output = target.succeeds(
              "test -f /run/livepatch-activation/count && " \
              "cat /run/livepatch-activation/count || echo 0"
            )
            output.to_i
          end

          expect_only_load_calls = lambda do |target, count|
            _, output = target.succeeds(
              "test -f /run/livepatch-activation/calls && " \
              "cat /run/livepatch-activation/calls || true"
            )
            expect(output.lines.map(&:strip)).to eq(Array.new(count, 'load'))
          end

          before(:context) do
            machine.start
            boot_off.start
            both_on.start
          end

          it 'applies each boot policy after booted-system exists' do
            expect(activation_count.call(machine)).to eq(1)
            expect_only_load_calls.call(machine, 1)
            machine.succeeds('test -e /run/booted-system')
            machine.fails('sv status live-patches')
            expect(activation_count.call(boot_off)).to eq(0)
            expect(activation_count.call(both_on)).to eq(1)
            expect_only_load_calls.call(both_on, 1)
          end

          it 'introduces and restarts the dormant service without loading' do
            machine.succeeds('${defaultSystem}/bin/switch-to-configuration test')
            machine.wait_for_service('live-patches')
            expect(activation_count.call(machine)).to eq(1)
            machine.succeeds('sv restart live-patches')
            machine.wait_for_service('live-patches')
            expect(activation_count.call(machine)).to eq(1)
          end

          it 'loads once for each opted-in live activation' do
            machine.succeeds('${switchSystem}/bin/switch-to-configuration test')
            expect(activation_count.call(machine)).to eq(2)
            machine.succeeds('${switchSystem}/bin/switch-to-configuration test')
            expect(activation_count.call(machine)).to eq(3)
            machine.succeeds('${bothSystem}/bin/switch-to-configuration test')
            expect(activation_count.call(machine)).to eq(4)
            expect_only_load_calls.call(machine, 4)

            both_on.succeeds('/run/current-system/bin/switch-to-configuration test')
            expect(activation_count.call(both_on)).to eq(2)
            expect_only_load_calls.call(both_on, 2)
          end

          it 'does not load or unload for the disabled live policy' do
            machine.succeeds('${neitherSystem}/bin/switch-to-configuration test')
            expect(activation_count.call(machine)).to eq(4)
            machine.succeeds('/run/booted-system/bin/switch-to-configuration test')
            expect(activation_count.call(machine)).to eq(4)
            expect_only_load_calls.call(machine, 4)
          end

          it 'logs one failed attempt without retrying or failing the switch' do
            machine.succeeds('touch /run/livepatch-activation/fail')
            machine.succeeds('${switchSystem}/bin/switch-to-configuration test')
            expect(activation_count.call(machine)).to eq(5)
            machine.succeeds('sleep 1')
            expect(activation_count.call(machine)).to eq(5)
            expect_only_load_calls.call(machine, 5)
          end
        end
      '';
    }
  );
in
makeTest (
  args
  // {
    extraArgs = (args.extraArgs or { }) // {
      inherit livepatchTest;
    };
  }
)
