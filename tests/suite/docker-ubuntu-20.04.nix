import ../make-test.nix (pkgs: {
  name = "docker-ubuntu-20.04";

  description = ''
    Test docker hello-world on Ubuntu 20.04 (focal)
  '';

  machine = import ../machines/tank.nix pkgs;

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.succeeds("osctl ct new --distribution ubuntu docker")
    machine.succeeds("osctl ct netif new bridge --link lxcbr0 docker eth0")

    # TODO: why is this needed?
    machine.succeeds("osctl ct set dns-resolver docker 1.1.1.1")

    machine.succeeds("osctl ct start docker")

    machine.succeeds("osctl ct exec docker apt-update -y")
    machine.succeeds("osctl ct exec docker apt-get -y install apt-transport-https ca-certificates curl software-properties-common")

    machine.succeeds("osctl ct exec docker bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"")
    machine.succeeds("osctl ct exec docker add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable\"")
    machine.succeeds("osctl ct exec docker apt-update -y")
    machine.succeeds("osctl ct exec docker apt-get -y install docker-ce")

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
  '';
})
