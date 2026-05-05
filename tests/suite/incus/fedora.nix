import ./base.nix {
  distribution = "fedora";
  tests = [
    {
      version = "latest";
      mapBase = 2200000;
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} dnf -y update",
          "osctl ct exec #{ct} dnf -y install incus",
        )
      '';
    }
  ];
}
