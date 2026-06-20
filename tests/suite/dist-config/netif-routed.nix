import ../../make-test.nix (
  { pkgs, distributions }:
  {
    name = "dist-config-netif-routed";

    description = ''
      Test that routed network interface works in containers
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (
        { distribution, version }:
        {
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

              testct = get_container_id
              suffix = testct.split("-").last.to_i(16)
              host_octet = suffix & 0xff
              host_octet = 1 if host_octet == 0
              host_octet = 254 if host_octet == 255
              ip = "10.250.#{(suffix >> 8) & 0xff}.#{host_octet}"

              machine.fails("ping -c 1 #{ip}")

              begin
                machine.all_succeed(
                  "osctl ct new --distribution ${distribution} --version ${version} #{testct}",
                  "osctl ct netif new routed #{testct} eth0",
                  "osctl ct netif ip add #{testct} eth0 #{ip}/32",
                  "osctl ct start #{testct}",
                )

                machine.wait_until_succeeds("ping -c 1 #{ip}", timeout: 20 * 60)
              ensure
                machine.execute("osctl ct del -f --prune #{testct}", timeout: 300)
                machine.execute("osctl repository images prune", timeout: 300)
              end
            '';
          };
        }
      ) distributions
    );
  }
)
