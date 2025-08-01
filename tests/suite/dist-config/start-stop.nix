import ../../make-test.nix (
  { pkgs, distributions }:
  {
    name = "dist-config-start-stop";

    description = ''
      Test that containers can be started/stopped
    '';

    tags = [ "ci" ];

    machine = import ../../machines/tank.nix pkgs;

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

              machine.all_succeed(
                "osctl ct new --distribution ${distribution} --version ${version} #{testct}",
                "osctl ct start #{testct}",
              )

              sleep(15)

              machine.succeeds("osctl ct stop --dont-kill #{testct}")
              machine.all_succeed(
                "osctl ct del -f --prune #{testct}",
                "osctl repository images prune"
              )
            '';
          };
        }
      ) distributions
    );
  }
)
