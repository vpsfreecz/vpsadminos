{ name, description, distribution, version, preSetupScript ? "", setupScript, testScript }:
import ../../make-test.nix (pkgs: {
  name = "snap-${name}-${distribution}-${version}";

  description = ''
    Test ${description} on ${distribution} ${version}
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    ${preSetupScript}

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

    sleep(15)
    machine.succeeds("osctl ct exec snapct snap wait system seed.loaded")

    ${testScript}
  '';
})
