import ../make-test.nix (pkgs: {
  name = "defaults";

  description = ''
    Test expected default vpsAdminOS configuration
  '';

  machine = import ../machines/empty.nix pkgs;

  testScript = ''
    machine.start

    _, output = machine.succeeds('cat /sys/module/apparmor/parameters/enabled')

    if output.strip != 'N'
      fail "apparmor enabled on boot, output=#{output.inspect}"
    end
  '';
})
