import ../make-test.nix ({ pkgs }: {
  name = "defaults";

  description = ''
    Test expected default vpsAdminOS configuration
  '';

  tags = [ "ci" ];

  machine = import ../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.fails('cat /sys/module/apparmor/parameters/enabled')

    machine.wait_for_service('pool-tank')

    st, output = machine.succeeds('zfs get -H -o value xattr tank')
    fail "xattr = '#{output}', expected 'on' or 'sa'" unless %w[on sa].include?(output.strip)
  '';
})
