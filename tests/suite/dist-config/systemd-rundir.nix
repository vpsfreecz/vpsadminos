import ../../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = pkgs:
    let
      runScript = pkgs.writeScript "dist-config-systemd-rundir-script.sh" ''
        #!/bin/sh
        fail() {
          echo $@
          exit 1
        }

        # On NixOS, /run/current-system/sw/bin is not available when osctld
        # mounts /run as tmpfs
        export PATH="$PATH:/nix/var/nix/profiles/system/sw/bin"

        [ -d /run ] || fail "/run not found"

        grep "tmpfs /run tmpfs " /proc/mounts | grep nosuid | grep nodev | grep -q mode=755 \
          || fail "/run not found in /proc/mounts or has unexpected options:\n$(cat /proc/mounts)"

        [ -d /run/udev ] || fail "/run/udev" not found

        [ -e /run/udev/control ] || fail "/run/udev/control not found"

        exit 0
      '';
    in {
      name = "dist-config-systemd-rundir@${instance}";

      description = ''
        Test that containers with ${distribution}-${version} have /run
        pre-mounted before systemd is started
      '';

      machine = import ../../machines/tank.nix pkgs;

      testScript = ''
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        machine.succeeds(
          "osctl ct new --distribution ${distribution} --version ${version} testct",
        )

        ${pkgs.lib.optionalString (distribution == "nixos") ''
        # NixOS needs to be first activated in order for /bin/sh to exist.
        machine.succeeds("osctl ct unset start-menu testct")
        machine.succeeds("osctl ct start testct")
        machine.wait_until_succeeds("osctl ct exec testct systemctl status")
        machine.succeeds("osctl ct stop testct")
        ''}

        machine.push_file("${runScript}", "/tmp/test-script.sh")
        machine.succeeds("osctl ct runscript -r testct /tmp/test-script.sh")
      '';
    };
})
