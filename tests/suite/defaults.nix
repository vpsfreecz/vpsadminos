import ../make-test.nix ({ pkgs }: {
  name = "defaults";

  description = ''
    Test expected default vpsAdminOS configuration
  '';

  tags = [ "ci" ];

  machine = import ../machines/empty.nix pkgs;

  testScript = ''
    machine.start
    machine.fails('cat /sys/module/apparmor/parameters/enabled')
  '';
})
