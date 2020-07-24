import ../../make-test.nix (pkgs: {
  name = "lxcfs-loadavgs";

  description = ''
    Test that /var/lib/lxcfs/proc/.loadavgs is available on the host
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.wait_for_service("lxcfs")
    machine.wait_until_succeeds("ls /var/lib/lxcfs/proc")

    _, output = machine.succeeds("ls -a1 /var/lib/lxcfs/proc")

    if output.include?(".loadavgs")
      fail ".loadavgs file is visible in /var/lib/lxcfs/proc, content:\n#{output}"
    end

    _, output = machine.succeeds("cat /var/lib/lxcfs/proc/.loadavgs")

    if output != ""
      fail "proc/.loadavgs not empty on boot, content:\n#{output}"
    end

    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.all_succeed(
      "osctl ct new --distribution alpine testct",
      "osctl ct mounts new --fs /var/lib/lxcfs/proc/.loadavgs --mountpoint /loadavgs --opts bind,rw,create=file --type bind testct",
      "osctl ct start testct",
    )

    _, output = machine.fails("osctl ct exec testct cat /loadavgs")

    unless output.include?("read error: Operation not permitted")
      fail "EPERM expected, got '#{output}'"
    end

    _, output = machine.succeeds("cat /var/lib/lxcfs/proc/.loadavgs")

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
