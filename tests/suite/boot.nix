import ../make-test.nix (pkgs: {
  name = "boot";

  description = ''
    Test that the system is capable of booting
  '';

  machine = import ../machines/empty.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_boot
  '';
})
