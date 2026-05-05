import ./base.nix {
  distribution = "fedora";
  tests = [
    {
      name = "hello";
      description = "snap hello-world";
      version = "latest";
      mapBase = null;
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} dnf -y update",
          "osctl ct exec #{ct} dnf -y install squashfuse snapd",
        )
      '';
      check = "check_snap_hello(ct)";
    }
    {
      name = "lxd";
      description = "lxd in snap";
      version = "latest";
      mapBase = 2800000;
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} dnf -y update",
          "osctl ct exec #{ct} dnf -y install screen squashfuse snapd",
          "osctl ct exec #{ct} ln -s /var/lib/snapd/snap /snap",
        )
      '';
      check = "check_snap_lxd(ct)";
    }
  ];
}
