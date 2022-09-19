import ../../make-test.nix (pkgs: {
  name = "lxcfs-loadavgs";

  description = ''
    Test that LXCFS proc/.loadavgs summary file is available
  '';

    machine = import ../../machines/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          services.lxcfs.enable = false;
        };
    };

  testScript = ''
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.all_succeed(
      "osctl ct new --distribution alpine testct",
    )

    _, output = machine.succeeds("osctl ct show -H -o lxcfs_mountpoint testct")
    lxcfs_mountpoint = output.strip

    machine.all_succeed(
      "osctl ct mounts new --fs #{lxcfs_mountpoint}/proc/.loadavgs --mountpoint /loadavgs --opts bind,rw,create=file --type bind testct",
      "osctl ct start testct",
    )

    _, output = machine.fails("osctl ct exec testct cat /loadavgs")

    unless output.include?("read error: Operation not permitted")
      fail "EPERM expected, got '#{output}'"
    end

    _, output = machine.succeeds("cat #{lxcfs_mountpoint}/proc/.loadavgs")

    rx = Regexp.new(
      "^"+
      "#{Regexp.escape('/osctl/pool.tank/group.default/user.testct/ct.testct/user-owned/lxc.payload.testct')}"+
      " "+
      "\\d+\\.\\d+ \\d+\\.\\d+ \\d+.\\d+ \\d+/\\d+ \\d+"+
      "$"
    )

    if rx !~ output
      fail "testct not found in .loadavgs:\n#{output}"
    end
  '';
})
