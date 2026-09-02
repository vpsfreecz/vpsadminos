import ./base.nix {
  distribution = "debian";
  tests = [
    {
      version = "latest";
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'podman',
          name: "Podman APT package installation in #{ct}",
        )

        configure_podman_registry_mirrors(ct)
      '';
    }
  ];
}
