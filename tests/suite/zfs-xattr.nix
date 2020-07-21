import ../make-test.nix (pkgs: {
  name = "zfs-xattr";

  description = ''
    Test that zfs xattr=sa by default
  '';

  machine = import ../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_service("pool-tank")

    st, output = machine.succeeds("zfs get -H -o value xattr tank")
    fail "xattr = '#{output}', expected 'sa'" if output != 'sa'
  '';
})
