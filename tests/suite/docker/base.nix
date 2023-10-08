{ distribution, version, setupScript }:
import ../../make-test.nix (pkgs: {
  name = "docker-${distribution}-${version}";

  description = ''
    Test docker hello-world on ${distribution} ${version}
  '';

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.all_succeed(
      "osctl ct new --distribution ${distribution} --version ${version} docker",
      "osctl ct unset start-menu docker",
      "osctl ct netif new bridge --link lxcbr0 docker eth0",

      # TODO: why is this needed?
      "osctl ct set dns-resolver docker 1.1.1.1",

      "osctl ct start docker",
    )

    machine.wait_until_succeeds("osctl ct exec docker bash -c 'ping -c 1 vpsadminos.org || curl --head https://vpsadminos.org || wget -O - https://vpsadminos.org'")

    ${setupScript}

    st, output = machine.succeeds("osctl ct exec docker docker info")

    if /Storage Driver: ([^\s]+)\s/ =~ output
      if $1.strip != 'overlay2'
        fail "using '#{$1}' storage driver instead of overlay2"
      end
    else
      fail "unable to find storage driver in docker info, output:\n#{output}"
    end

    st, output = machine.succeeds("osctl ct exec docker docker run hello-world")

    if /Hello from Docker/ !~ output
      fail "docker hello-world not working, output:\n#{output}"
    end

    st, output = machine.succeeds("osctl ct exec docker docker pull gitlab/gitlab-ee:latest")

    if (output !~ /Status: Image is up to date for gitlab\/gitlab-ee:latest/) &&
       (output !~ /Status: Downloaded newer image for gitlab\/gitlab-ee:latest/)
      fail "docker pull gitlab/gitlab-ee:latest not working, output:\n#{output}"
    end
  '';
})
