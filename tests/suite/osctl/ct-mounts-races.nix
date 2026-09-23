import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-mounts-races";

    description = ''
      Adversarial live-mount activation: container init death and
      shared-directory path replacement must stay bounded without a host-side
      escape or leak.
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'digest'

      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      ct = "mountct"
      mountpoint = "/mnt/race"
      hash = Digest::SHA2.hexdigest(mountpoint)
      shared_dir = "/run/osctl/pools/tank/mounts/#{ct}"
      host_path = File.join(shared_dir, hash)

      # A harmless decoy mountpoint: no adversarial attempt may mount over it
      # or tear it down through a replaced path.
      machine.all_succeed(
        "mkdir -p /tmp/decoy-target",
        "mount -t tmpfs tmpfs /tmp/decoy-target",
        "echo decoy-marker > /tmp/decoy-target/marker",
      )

      machine.all_succeed(
        "zfs create -p tank/race/src",
        "echo race-src > /tank/race/src/race.txt",
        "osctl ct new --distribution alpine #{ct}",
        "osctl ct unset start-menu #{ct}",
        "osctl ct mounts new --no-automount --fs /tank/race/src --type bind " \
          "--opts bind,create=dir --mountpoint #{mountpoint} #{ct}",
        "osctl ct start #{ct}",
      )
      machine.wait_until_succeeds("osctl ct exec #{ct} rc-service networking status")

      # (a) The container init dies while the live activation is in flight. The
      # activation must conclude with a numeric status; whatever it reports, no
      # shared-directory binding, leftover directory or runner helper may stay
      # behind, and the decoy must survive.
      machine.succeeds(
        "(osctl ct mounts activate #{ct} #{mountpoint} >/tmp/race-init.log 2>&1; " \
          "echo $? > /tmp/race-init.status) & echo $! > /tmp/race-init.pid"
      )
      machine.succeeds("osctl ct exec #{ct} sh -c 'kill -9 1' || true")
      machine.wait_until_succeeds('test -s /tmp/race-init.status', timeout: 120)
      machine.succeeds("grep -E '^[0-9]+$' /tmp/race-init.status")
      machine.wait_until_succeeds("! grep -F '#{host_path}' /proc/mounts", timeout: 60)
      # `test -e` follows links: require a leftover dangling symlink absent
      # too, not only the path's target.
      machine.wait_until_succeeds("test ! -e #{host_path} && test ! -L #{host_path}", timeout: 60)
      machine.wait_until_succeeds(
        "! ps -eo args= | grep -E '^osctld: tank:#{ct} runner:'",
        timeout: 60
      )
      machine.all_succeed(
        "mountpoint -q /tmp/decoy-target",
        "grep -Fx decoy-marker /tmp/decoy-target/marker",
      )

      # (b) Place a symlink to the host-owned decoy at the exact hashed host
      # path of the pending shared mount. This deterministically tests refusal
      # of an already-replaced path, not the narrower between-syscalls race.
      machine.wait_until_succeeds("osctl ct show -H -o state #{ct} | grep -Fx stopped", timeout: 60)
      machine.succeeds("osctl ct start #{ct}")
      machine.wait_until_succeeds("osctl ct exec #{ct} rc-service networking status")
      machine.all_succeed(
        "test ! -e #{host_path} && test ! -L #{host_path}",
        "ln -s /tmp/decoy-target #{host_path}",
        "test -L #{host_path}",
      )
      machine.fails("osctl ct mounts activate #{ct} #{mountpoint}")

      machine.all_succeed(
        "mountpoint -q /tmp/decoy-target",
        "grep -Fx decoy-marker /tmp/decoy-target/marker",
        "test -L #{host_path}",
        "! grep -F '#{host_path}' /proc/mounts",
        "! ps -eo args= | grep -E '^osctld: tank:#{ct} runner:'",
      )

      # Remove only the exact symlink created by this test; the product must
      # not remove an unrelated pre-existing entry on failed activation.
      machine.succeeds("test -L #{host_path} && rm #{host_path}")

      # A clean activation still works and shows the configured source.
      machine.succeeds("osctl ct mounts activate #{ct} #{mountpoint}")
      _, mounted = machine.succeeds("osctl ct exec #{ct} cat #{mountpoint}/race.txt")
      fail "unexpected mount content: #{mounted.inspect}" unless mounted.strip == "race-src"

      machine.all_succeed(
        "osctl ct stop #{ct}",
        "osctl ct del --prune #{ct}",
        "umount /tmp/decoy-target",
        "rmdir /tmp/decoy-target",
      )
    '';
  }
)
