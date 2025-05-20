import ../../make-test.nix (pkgs: {
  name = "zfs-xattr";

  description = ''
    Test that zfs xattr=on/sa by default
  '';

  tags = [ "ci" ];

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_service("pool-tank")

    st, output = machine.succeeds("zfs get -H -o value xattr tank")
    fail "xattr = '#{output}', expected 'on' or 'sa'" unless %w[on sa].include?(output.strip)
  '';
})
