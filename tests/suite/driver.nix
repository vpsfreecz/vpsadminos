import ../make-test.nix (pkgs: {
  name = "driver";

  description = ''
    Test the test driver itself
  '';

  tags = [ "ci" ];

  machine = import ../machines/tank.nix pkgs;

  testScript = ''
    fail "machine running but not started" if machine.running?
    fail "machine booted but not started" if machine.booted?

    machine.start
    fail "machine booted but shouldn't be" if machine.booted?
    machine.wait_for_boot
    fail "machine not running but was started" unless machine.running?
    fail "machine not booted but should be" unless machine.booted?
    machine.stop
    machine.wait_for_shutdown

    fail "machine running but was stopped" if machine.running?
    fail "machine booted but was stopped" if machine.booted?

    machine.start
    machine.kill

    fail "machine running but was killed" if machine.running?
    fail "machine booted but was killed" if machine.booted?

    # It is possible that the machine.kill above left the pool in an unexpected
    # state during initial osctld setup, etc., which is what we don't test for.
    machine.destroy_disks

    machine.start

    def run_expect(name, expected)
      ret = yield

      if ret != expected
        fail "#{name} returned '#{ret.inspect}' instead of '#{expected.inspect}'"
      end

      ret
    end

    run_expect("execute", [0, "hey\n"]) { machine.execute("echo hey") }
    run_expect("succeeds", [0, "root\n"]) { machine.succeeds("whoami") }
    run_expect("fails", [1, ""]) { machine.fails("false") }

    run_expect(
      "all_succeed",
      [[0, "hey\n"], [0, "hou\n"]]
    ) do
      machine.all_succeed("echo hey", "echo hou")
    end

    run_expect(
      "all_fail",
      [[1, ""], [1, ""]]
    ) do
      machine.all_fail("false", "false")
    end

    machine.wait_until_succeeds("sleep 10")
    machine.wait_until_fails("sleep 10 ; false")

    begin
      machine.execute("sleep 10", timeout: 5)
    rescue OsVm::TimeoutError
      # ok
    else
      fail "Execution timeout not caught"
    end

    begin
      machine.wait_for_shutdown(timeout: 5)
    rescue OsVm::TimeoutError
      # ok
    else
      fail "Shutdown timeout not caught"
    end

    machine.succeeds("poweroff -f")
    machine.wait_for_shutdown

    fail "machine running but was stopped" if machine.running?
    fail "machine booted but was stopped" if machine.booted?

    machine.start
    machine.wait_for_zpool("tank")
    machine.wait_for_osctl_pool("tank")

    pools = machine.osctl_json("pool ls")

    if pools.length != 1
      fail "invalid pool list, got '#{pools.inspect}'"
    elsif pools.first[:name] != 'tank'
      fail "expected osctl pool 'tank', got '#{pools.first[:name]}'"
    elsif pools.first[:state] != 'active'
      fail "expected osctl pool to be active, is '#{pools.first[:state]}'"
    end

    machine.stop

    machine.start
    machine.mkdir("/mydir")

    begin
      machine.mkdir("/mynested/dir")
    rescue OsVm::CommandFailed
      # ok
    else
      fail "mkdir can create parent directories"
    end

    machine.mkdir_p("/mynested/dir")

    machine.fails("ls -l /myresolvconf")
    machine.push_file("/etc/resolv.conf", "/myresolvconf")
    machine.succeeds("ls -l /myresolvconf")

    machine.fails("ls -l /mynestedresolvconf/conf")
    begin
      machine.push_file("/etc/resolv.conf", "/mynestedresolvconf/conf")
    rescue OsVm::CommandError
      # ok
    else
      fail "push_file() should not create parent directories"
    end

    machine.fails("ls -l /mynestedresolvconf/conf")
    machine.push_file("/etc/resolv.conf", "/mynestedresolvconf/conf", mkpath: true)
    machine.succeeds("ls -l /mynestedresolvconf/conf")

    pulled = machine.pull_file("/etc/resolv.conf")
    unless File.exist?(pulled)
      fail "pulled file not found at '#{pulled}'"
    end

    machine.stop
  '';
})
