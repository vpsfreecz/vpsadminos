{ name, config }:
import ../../make-test.nix (pkgs: {
  name = "osctl-ct-exec-${name}";

  description = ''
    Test osctl ct exec
  '';

  machine = import ../../machines/with-tank.nix {
    inherit pkgs config;
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
      _, output = machine.succeeds("osctl ct exec #{opts} #{ctid} echo hi")

      if output != "hi"
        fail "#{msg}: unexpected exec output: #{output.inspect}"
      end

      # capture stderr
      _, output = machine.succeeds("osctl ct exec #{opts} #{ctid} sh -c '>&2 echo hi'")

      if output != "hi"
        fail "#{msg}: unexpected exec output: #{output.inspect}"
      end

      # exit status
      st, output = machine.execute("osctl ct exec #{opts} #{ctid} sh -c 'exit 33'")

      if st != 33
        fail "#{msg}: unexpected exec status: #{st.inspect}"
      elsif output != "error: executed command failed"
        fail "#{msg}: unexpected exec output: #{output.inspect}"
      end

      # invalid command
      st, output = machine.execute("osctl ct exec #{opts} #{ctid} totally-madeup-command")

      # exitstatus and output differs based on whether the container is running
      # or is brought up with lxc-execute, so we just check that it returns
      # non-zero status
      if st == 0
        fail "#{msg}: unexpected exec status: #{st.inspect}"
      end
    end


    # Exec on a running container
    _, output = machine.succeeds("osctl ct show -H -o state startedct")

    if output != "running"
      fail "startedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'exec on a running container',
      'startedct',
      "",
    )


    # Exec on a stopped container
    _, output = machine.succeeds("osctl ct show -H -o state stoppedct")

    if output != "stopped"
      fail "stoppedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'exec on a stopped container',
      'stoppedct',
      '-r',
    )


    # Exec on a running container with -r
    _, output = machine.succeeds("osctl ct show -H -o state startedct")

    if output != "running"
      fail "startedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'exec on a running container with -r',
      'startedct',
      '-r',
    )


    # Exec on a stopped container with networking
    _, output = machine.succeeds("osctl ct show -H -o state stoppedct")

    if output != "stopped"
      fail "stoppedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'exec on a stopped container with networking',
      'stoppedct',
      '-rn',
    )

    machine.succeeds("osctl ct exec -rn stoppedct ping -c 1 1.2.3.4")
    machine.succeeds("osctl ct exec -rn stoppedct ping -c 1 255.255.255.254")

    _, output = machine.succeeds("osctl ct exec -rn stoppedct ip route show")

    if output != "default via 255.255.255.254 dev eth0 \r\n255.255.255.254 dev eth0 scope link"
      fail "unexpected default route: #{output.inspect}"
    end


    # Exec on a running container with networking
    _, output = machine.succeeds("osctl ct show -H -o state startedct")

    if output != "running"
      fail "startedct is in an unexpected state: #{output.inspect}"
    end

    common_tests.call(
      'exec on a running container with -rn',
      'startedct',
      '-rn',
    )
  '';
})
