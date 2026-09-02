import ./base.nix {
  distribution = "debian";
  tests = [
    {
      version = "latest";
      mapBase = 1600000;
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'incus',
          name: "Incus APT package installation in #{ct}",
        )
      '';
    }
  ];
}
