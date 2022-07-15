import ../../make-test.nix (pkgs: {
  name = "systemd-credentials";

  description = ''
    Test systemd credentials inside a container
  '';

  machine = import ../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online
    machine.all_succeed(
      "osctl ct new --distribution arch testct",
      "osctl ct start testct",
    )

    # LoadCredential
    _, output = machine.all_succeed(
      "osctl ct exec testct bash -c 'echo mysecretcontent > /mysecretfile'",
      "osctl ct exec testct chmod og-rwx /mysecretfile",
      "osctl ct exec testct systemd-run --quiet --pipe --property LoadCredential=mysecret:/mysecretfile /bin/bash -c 'cat $CREDENTIALS_DIRECTORY/mysecret'",
    ).last

    if output.strip != "mysecretcontent"
      fail "invalid credential, got #{output.inspect}"
    end
  '';
})
