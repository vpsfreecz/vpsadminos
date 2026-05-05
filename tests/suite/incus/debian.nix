import ./base.nix {
  distribution = "debian";
  tests = [
    {
      version = "latest";
      mapBase = 1600000;
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install incus",
        )
      '';
    }
  ];
}
