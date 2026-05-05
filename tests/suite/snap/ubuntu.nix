import ./base.nix {
  distribution = "ubuntu";
  tests = [
    {
      name = "hello";
      description = "snap hello-world";
      version = "latest";
      mapBase = null;
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install snapd",
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
        machine.all_succeed(
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install screen snapd",
        )
      '';
      check = "check_snap_lxd(ct)";
    }
  ];
}
