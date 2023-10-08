{ distribution, version, setupScript }:
import ../../make-test.nix (pkgs: {
  name = "podman-${distribution}-${version}";

  description = ''
    Test podman hello-world on ${distribution} ${version}
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.all_succeed(
      "osctl ct new --distribution ${distribution} --version ${version} podmanct",
      "osctl ct unset start-menu podmanct",
      "osctl ct netif new bridge --link lxcbr0 podmanct eth0",

      # TODO: why is this needed?
      "osctl ct set dns-resolver podmanct 1.1.1.1",

      "osctl ct start podmanct",
    )

    machine.wait_until_succeeds("osctl ct exec podmanct bash -c 'ping -c 1 vpsadminos.org || curl --head https://vpsadminos.org || wget -O - https://vpsadminos.org'")

    ${setupScript}

    st, output = machine.succeeds("osctl ct exec podmanct podman info")

    if /graphDriverName: ([^\s]+)\s/ =~ output
      if $1.strip != 'overlay'
        fail "using '#{$1}' storage driver instead of overlay"
      end
    else
      fail "unable to find storage driver in podman info, output:\n#{output}"
    end

    st, output = machine.succeeds("osctl ct exec podmanct podman run hello-world")

    # Some distros/podman versions fetch hello-world from different registries.
    # On Fedora we get podman's hello world and on Debian and Ubuntu we get
    # docker's hello world...
    if /Hello Podman World/ !~ output && /Hello from Docker/ !~ output
      fail "podman hello-world not working, output:\n#{output}"
    end
  '';
})
