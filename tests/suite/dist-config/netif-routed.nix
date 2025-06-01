import ../../make-test.nix ({ pkgs, distributions }: {
  name = "dist-config-netif-routed";

  description = ''
    Test that routed network interface works in containers
  '';

  tags = [ "ci" ];

  machine = import ../../machines/tank.nix pkgs;

  testScripts = builtins.listToAttrs (map ({ distribution, version }: {
    name = "${distribution}-${version}";
    value = {
      script = ''
        # CentOS 7 requires cgroups v1, all other distributions use v2
        kernel_params = ["osctl.cgroupv=${if distribution != "centos" || version != "7" then "2" else "1"}"]

        if machine.running? && machine.start_kernel_params != kernel_params
          machine.stop
        end

        machine.start(kernel_params:) unless machine.running?
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        ip = "1.2.3.4"

        machine.fails("ping -c 1 #{ip}")

        testct = get_container_id

        machine.all_succeed(
          "osctl ct new --distribution ${distribution} --version ${version} #{testct}",
          "osctl ct netif new routed #{testct} eth0",
          "osctl ct netif ip add #{testct} eth0 #{ip}/32",
          "osctl ct start #{testct}",
        )

        machine.wait_until_succeeds("ping -c 1 #{ip}")
        machine.succeeds("osctl ct del -f --prune #{testct}")
      '';
    };
  }) distributions);
})
