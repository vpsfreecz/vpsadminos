{ distribution, version, setupScript }:
import ../../make-test.nix (pkgs: {
  name = "snap-hello-${distribution}-${version}";

  description = ''
    Test snap hello-world on ${distribution} ${version}
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.all_succeed(
      "osctl ct new --distribution ${distribution} --version ${version} snapct",
      "osctl ct unset start-menu snapct",
      "osctl ct netif new bridge --link lxcbr0 snapct eth0",
      "osctl ct devices add -p snapct char 10 229 rwm /dev/fuse",

      # TODO: why is this needed?
      "osctl ct set dns-resolver snapct 1.1.1.1",

      "osctl ct start snapct",
    )

    machine.wait_until_succeeds("osctl ct exec snapct bash -c 'curl --head https://vpsadminos.org || wget -O - https://vpsadminos.org'")

    ${setupScript}

    machine.succeeds("osctl ct exec snapct snap install hello-world")
    st, output = machine.succeeds("osctl ct exec snapct snap run hello-world")

    if output.strip != 'Hello World!'
      fail "snap run hello-world not working, output:\n#{output}"
    end
  '';
})
