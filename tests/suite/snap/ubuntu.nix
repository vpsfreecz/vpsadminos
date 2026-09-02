import ./base.nix {
  distribution = "ubuntu";
  tests = [
    {
      name = "hello";
      description = "snap hello-world";
      version = "latest";
      mapBase = null;
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'snapd',
          name: "Snap APT package installation in #{ct}",
        )
      '';
      check = "check_snap_hello(ct)";
    }
    {
      name = "lxd";
      description = "lxd in snap";
      version = "latest";
      mapBase = 3400000;
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'screen',
          'snapd',
          name: "Snap APT package installation in #{ct}",
        )
      '';
      check = "check_snap_lxd(ct)";
    }
  ];
}
