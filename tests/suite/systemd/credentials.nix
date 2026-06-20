import ../../make-test.nix (
  { pkgs }:
  let
    mkSystemdContainer = {
      user = "testuser";

      shareStore = true;

      autostart.enable = true;

      startMenu.enable = false;

      config = { ... }: {
        documentation.enable = false;
        documentation.nixos.enable = false;
      };
    };
  in
  {
    name = "systemd-credentials";

    description = ''
      Test systemd credentials inside a container
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        osctl.pools.tank = {
          users.testuser = {
            uidMap = [ "0:500000:65536" ];
            gidMap = [ "0:600000:65536" ];
          };

          containers.testct = mkSystemdContainer;
        };
      };
    };

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online
      machine.wait_for_osctl_container("testct")
      machine.wait_until_succeeds("osctl ct exec testct systemctl is-system-running", timeout: 120)

      # LoadCredential
      _, output = machine.all_succeed(
        "osctl ct exec testct bash -c 'echo mysecretcontent > /mysecretfile'",
        "osctl ct exec testct chmod og-rwx /mysecretfile",
        "osctl ct exec testct systemd-run --quiet --pipe --property LoadCredential=mysecret:/mysecretfile /run/current-system/sw/bin/bash -c '/run/current-system/sw/bin/cat $CREDENTIALS_DIRECTORY/mysecret'",
      ).last

      if output.strip != "mysecretcontent"
        fail "invalid credential, got #{output.inspect}"
      end
    '';
  }
)
