import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-cat";

    description = ''
      Test osctl ct cat command
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      # Prepare a container
      machine.all_succeed(
        "osctl ct new --distribution alpine testct",
        "osctl ct unset start-menu testct"
      )

      # cat doesn't work on stopped containers
      machine.fails("osctl ct cat testct /etc/os-release")

      # Start the container
      machine.succeeds("osctl ct start testct")

      # Wrong arguments
      machine.all_fail(
        "osctl ct cat",
        "osctl ct cat testct"
      )

      id_rx = /^ID=alpine\n/

      # Read files
      _, cat_output = machine.succeeds("osctl ct cat testct /etc/os-release")
      cat_ids = cat_output.scan(id_rx)

      if cat_ids.empty?
        fail "ID=alpine not found in #{cat_output.inspect}"
      elsif cat_ids.size > 1
        fail "found multiple ID=alpine lines in #{cat_output.inspect}"
      end

      # Compare output with ct exec
      _, exec_output = machine.succeeds("osctl ct exec testct cat /etc/os-release")

      if exec_output != cat_output
        fail "osctl ct cat output does not match osctl ct exec: #{cat_output.inspect} vs #{exec_output.inspect}"
      end

      # Cat multiple files
      _, multi_output = machine.succeeds("osctl ct cat testct /etc/os-release /etc/os-release")
      multi_ids = multi_output.scan(id_rx)

      if multi_ids.size != 2
        fail "expected two ID=alpine lines, found #{multi_ids.size} in #{multi_output.inspect}"
      end

      # Non-existent files
      machine.fails("osctl ct cat testct /no/file")

      # One error sets non-zero exit status
      _, error_output = machine.fails("osctl ct cat testct /etc/os-release /no/file /etc/os-release")
      error_ids = error_output.scan(id_rx)

      if error_ids.size != 2
        fail "expected two ID=alpine lines, found #{error_ids.size} in #{error_output.inspect}"
      end
    '';
  }
)
