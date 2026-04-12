import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-passwd";

    description = ''
      Test osctl ct passwd
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = { };
    };

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.all_succeed(
        "osctl ct new --distribution debian startedct",
        "osctl ct unset start-menu startedct",
        "osctl ct new --distribution debian stoppedct",
        "osctl ct unset start-menu stoppedct",
        "osctl ct start startedct",
      )

      check_password = Proc.new do |msg, ctid, exec_opts|
        machine.succeeds("osctl ct passwd #{ctid} root sup3rS3cret")
        machine.succeeds("osctl ct exec #{exec_opts} #{ctid} sh -c \"grep -q '^root:[^!*]' /etc/shadow\"")
      end

      _, output = machine.succeeds("osctl ct show -H -o state startedct")

      if output.strip != "running"
        fail "startedct is in an unexpected state: #{output.inspect}"
      end

      check_password.call(
        'passwd on a running container',
        'startedct',
        "",
      )

      _, output = machine.succeeds("osctl ct show -H -o state stoppedct")

      if output.strip != "stopped"
        fail "stoppedct is in an unexpected state: #{output.inspect}"
      end

      check_password.call(
        'passwd on a stopped container',
        'stoppedct',
        '-r',
      )
    '';
  }
)
