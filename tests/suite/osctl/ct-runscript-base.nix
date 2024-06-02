{ name, config }:
import ../../make-test.nix (pkgs:
let
  templateConfig = config;

  scripts = {
    stdout = pkgs.writeScript "test-stdout-script" ''
      #!/bin/sh
      echo hi
    '';

    stderr = pkgs.writeScript "test-stderr-script" ''
      #!/bin/sh
      >&2 echo hi
    '';

    error = pkgs.writeScript "test-error-script" ''
      #!/bin/sh
      exit 33
    '';

    net = pkgs.writeScript "test-net-script" ''
      #!/bin/sh
      set -e
      ping -c 1 1.2.3.4 > /dev/null
      ping -c 1 255.255.255.254 > /dev/null
      ip route show default
    '';
  };
in {
  name = "osctl-ct-runscript-${name}";

  description = ''
    Test osctl ct runscript
  '';

  machine = import ../../machines/with-tank.nix {
    inherit pkgs;
    config =
      { config, ... }:
      {
        imports = [ templateConfig ];

        # Add the test scripts to the test machine
        environment.etc."test-scripts".text = builtins.toJSON scripts;
      };
  };

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.all_succeed(
      "osctl ct new --distribution alpine startedct",
      "osctl ct unset start-menu startedct",
      "osctl ct new --distribution alpine stoppedct",
      "osctl ct netif new routed stoppedct eth0",
      "osctl ct netif ip add stoppedct eth0 1.2.3.4/32",
      "osctl ct start startedct",
    )

    common_tests = Proc.new do |msg, ctid, opts|
      # capture stdout
      _, output = machine.succeeds("osctl ct runscript #{opts} #{ctid} ${scripts.stdout}")

      if output != "hi"
        fail "#{msg}: unexpected runscript output: #{output.inspect}"
      end

      # capture stderr
      _, output = machine.succeeds("osctl ct runscript #{opts} #{ctid} ${scripts.stderr}")

      if output != "hi"
        fail "#{msg}: unexpected runscript output: #{output.inspect}"
      end

      # exit status
      st, output = machine.execute("osctl ct runscript #{opts} #{ctid} ${scripts.error}")

      if st != 33
        fail "#{msg}: unexpected runscript status: #{st.inspect}"
      elsif output != "error: executed command failed"
        fail "#{msg}: unexpected runscript output: #{output.inspect}"
      end

      # invalid script
      st, output = machine.execute("osctl ct runscript #{opts} #{ctid} totally-invalid-script")

      if st != 1
        fail "#{msg}: unexpected runscript status: #{st.inspect}"
      elsif !output.start_with?('error: ')
        fail "#{msg}: unexpected runscript output: #{output.inspect}"
      end
    end

    # Runscript on a running container
    _, output = machine.succeeds("osctl ct show -H -o state startedct")

    if output != "running"
      fail "startedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'runscript on a running container',
      'startedct',
      "",
    )

    # Runscript on a stopped container
    _, output = machine.succeeds("osctl ct show -H -o state stoppedct")

    if output != "stopped"
      fail "stoppedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'runscript on a stopped container',
      'stoppedct',
      '-r',
    )


    # Runscript on a running container with -r
    _, output = machine.succeeds("osctl ct show -H -o state startedct")

    if output != "running"
      fail "startedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'runscript on a running container with -r',
      'startedct',
      '-r',
    )


    # Runscript on a stopped container with networking
    _, output = machine.succeeds("osctl ct show -H -o state startedct")

    if output != "running"
      fail "startedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'runscript on a stopped container with networking',
      'startedct',
      '-rn',
    )

    # Runscript on a stopped container with networking
    _, output = machine.succeeds("osctl ct show -H -o state stoppedct")

    if output != "stopped"
      fail "stoppedct is in an unexpected state: #{output.inspect}"
    end

    _, output = machine.succeeds("osctl ct runscript -rn stoppedct ${scripts.net}")

    if output != "default via 255.255.255.254 dev eth0 \r\n255.255.255.254 dev eth0 scope link"
      fail "unexpected default route: #{output.inspect}"
    end


    # Runscript on a running container with -rn
    _, output = machine.succeeds("osctl ct show -H -o state startedct")

    if output != "running"
      fail "startedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'runscript on a running container with -rn',
      'startedct',
      '-rn',
    )
  '';
})
