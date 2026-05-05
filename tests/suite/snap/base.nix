{
  distribution,
  tests,
}:
import ../../make-test.nix (
  { pkgs }:
  let
    common = ''
      def ensure_machine
        machine.start unless machine.running?
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
      end

      def cleanup_container(ct)
        return unless machine.running?

        begin
          machine.succeeds("osctl ct del -f --prune #{ct}")
        rescue OsVm::CommandFailed
          # Best effort cleanup after failed setup.
        end

        begin
          machine.succeeds("osctl user del #{ct}")
        rescue OsVm::CommandFailed
          # The user may have been removed with the container.
        end

        begin
          machine.succeeds('osctl repository images prune')
        rescue OsVm::CommandFailed
          # Best effort cleanup after failed setup.
        end
      end

      def create_snap_container(ct, distribution, version, map_base)
        user_arg =
          if map_base
            machine.succeeds("osctl user new --no-standalone --map 0:#{map_base}:524288 #{ct}")
            "--user #{ct} "
          else
            ""
          end

        machine.all_succeed(
          "osctl ct new #{user_arg}--distribution #{distribution} --version #{version} #{ct}",
          "osctl ct unset start-menu #{ct}",
          "osctl ct netif new bridge --link lxcbr0 #{ct} eth0",
          "osctl ct devices add -p #{ct} char 10 229 rwm /dev/fuse",

          # TODO: why is this needed?
          "osctl ct set dns-resolver #{ct} 1.1.1.1",

          "osctl ct start #{ct}",
        )

        machine.wait_until_container_online(ct)
      end

      def wait_for_snap_seed(ct)
        sleep(15)
        machine.succeeds("osctl ct exec #{ct} snap wait system seed.loaded")
      end

      def check_snap_hello(ct)
        machine.succeeds("osctl ct exec #{ct} snap install hello-world")
        _, output = machine.succeeds("osctl ct exec #{ct} snap run hello-world")

        if output.strip != 'Hello World!'
          fail "snap run hello-world not working, output:\n#{output}"
        end
      end

      def check_snap_lxd(ct)
        machine.all_succeed(
          "osctl ct exec #{ct} snap install lxd",
          "osctl ct exec #{ct} /snap/bin/lxd init --auto",

          # We have to run lxc launch from within a screen, as otherwise it hangs
          # and does nothing.
          "osctl ct exec #{ct} screen -d -m /bin/sh -c '/snap/bin/lxc launch ubuntu:22.04 u1 ; echo $? > /lxc.status'"
        )

        _, output = machine.wait_until_succeeds("osctl ct exec #{ct} cat /lxc.status")

        if output.strip != '0'
          fail "lxc launch failed with exit status #{output.inspect}"
        end

        sleep(15)

        _, output = machine.succeeds("osctl ct exec #{ct} /snap/bin/lxc info u1")

        if /Status: RUNNING/ !~ output
          fail "lxd container not running, lxc info output: #{output.inspect}"
        end

        if /Type: container/ !~ output
          fail "expected type container, lxc info output: #{output.inspect}"
        end
      end
    '';
  in
  {
    name = "snap-${distribution}";

    description = ''
      Test snap on ${distribution}
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (test: {
        name = test.name;
        value = {
          description = ''
            Test ${test.description} on ${distribution} ${test.version}
          '';
          attempts = 3;
          script = common + ''
            ct = get_container_id('snap')

            begin
              ensure_machine
              create_snap_container(ct, '${distribution}', '${test.version}', ${
                if test.mapBase == null then "nil" else toString test.mapBase
              })
              ${test.setup}
              wait_for_snap_seed(ct)
              ${test.check}
            ensure
              cleanup_container(ct)
            end
          '';
        };
      }) tests
    );
  }
)
