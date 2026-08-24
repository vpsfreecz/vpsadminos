import ../make-test.nix (
  { pkgs }:
  let
    mkNixosContainer =
      { shareStore }:
      {
        user = "testuser";

        inherit shareStore;

        autostart.enable = true;

        startMenu.enable = false;

        config = { config, ... }: { };
      };
  in
  {
    name = "declarative-containers";

    description = ''
      Test declarative containers

      Currently only NixOS with shared/standalone store is tested.
    '';

    tags = [ "ci" ];

    machine = import ../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          osctl.pools.tank = {
            users.testuser = {
              uidMap = [ "0:500000:65536" ];
              gidMap = [ "0:600000:65536" ];
            };

            containers = {
              nixos-shared = mkNixosContainer { shareStore = true; };
              nixos-standalone = mkNixosContainer { shareStore = false; };
            };
          };
        };
    };

    testScript = ''
      before(:suite) do
        machine.wait_for_osctl_pool('tank')
      end

      %w[nixos-shared nixos-standalone].each do |testct|
        describe testct, order: :defined do
          before(:context) do
            machine.wait_for_osctl_container(testct)
          end

          it 'is running' do
            machine.wait_until_succeeds("osctl ct exec #{testct} systemctl is-system-running")
          end

          it 'has mapped uid/gid on /nix/store' do
            _, ugid_str = machine.succeeds("osctl ct exec #{testct} stat -c %u:%g /nix/store")

            ugid = ugid_str.split(':', 2).map(&:to_i)

            if testct == 'nixos-shared'
              expect(ugid).to eq([0, 0])
            else
              expect(ugid).to eq([0, 30_000])
            end
          end

          it 'has system profile' do
            current_system = machine.succeeds("osctl ct exec #{testct} realpath /run/current-system")[1].strip
            system_profile = machine.succeeds("osctl ct exec #{testct} realpath /nix/var/nix/profiles/system")[1].strip

            expect(current_system).not_to be_empty
            expect(current_system).to eq(system_profile)
          end

          describe '/nix/store in rootfs' do
            before(:context) do
              ct_rootfs = machine.osctl_json("ct show #{testct}")['rootfs']
              @store_contents = machine.succeeds("ls -A #{ct_rootfs}/nix/store/")[1].strip
            end

            if testct == 'nixos-shared'
              it 'is empty' do
                expect(@store_contents).to be_empty
              end
            else
              it 'is not empty' do
                expect(@store_contents).not_to be_empty
              end
            end
          end
        end
      end

      describe 'existing declarations', order: :defined do
        %w[nixos-shared nixos-standalone].each do |testct|
          it "reapplies #{testct} using its runtime state" do
            service = "ct-tank-#{testct}"
            done = "/run/service/#{service}/done"

            machine.succeeds("rm -f #{done}")
            machine.succeeds("sv once #{service}")
            machine.wait_until_succeeds("test -f #{done}", timeout: 180)
            machine.wait_until_succeeds(
              "osctl ct exec #{testct} systemctl is-system-running",
              timeout: 180
            )
          end
        end

        it 'sweeps the declarative pool without changing defined containers' do
          machine.succeeds('gc-sweep-tank')

          %w[nixos-shared nixos-standalone].each do |testct|
            state = machine.osctl_json("ct show #{testct}")['runtime_state']
            expect(state).to eq('running')
          end
        end
      end
    '';
  }
)
