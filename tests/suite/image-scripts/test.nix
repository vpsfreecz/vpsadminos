import ../../make-template.nix (
  { image-script }:
  rec {
    instance = image-script;

    test =
      { pkgs }:
      {
        name = "image-scripts/test@${instance}";

        description = ''
          Test that container image ${image-script} can be built and passes the tests
        '';

        machine = import ../../machines/with-tank.nix {
          inherit pkgs;
          config =
            { config, ... }:
            {
              boot.zfs.pools.tank.datasets = {
                "image-scripts" = { };
                "image-scripts/build" = { };
                "image-scripts/output" = { };
              };

              os.channel-registration.enable = true;
            };
        };

        testScript = ''
          machine.wait_for_osctl_pool("tank")
          machine.wait_until_online
          machine.succeeds(
            "osctl-image test --build-dataset tank/image-scripts/build --output-dir /tank/image-scripts/output ${image-script}",
            timeout: 3 * 60 * 60
          )
        '';
      };
  }
)
