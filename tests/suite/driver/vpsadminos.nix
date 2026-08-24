import ../../make-test.nix (
  { pkgs }:
  {
    name = "driver-vpsadminos";

    description = ''
      Test the vpsAdminOS driver
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      def run_expect(name, expected)
        ret = yield

        if ret != expected
          fail "#{name} returned '#{ret.inspect}' instead of '#{expected.inspect}'"
        end

        ret
      end

      ctids = []

      100.times do
        ctid = get_container_id

        if ctids.include?(ctid)
          fail "Duplicit container id #{ctid.inspect}"
        end

        ctids << ctid
      end

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

      machine.destroy_disks

      machine.start

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

      wait_i = 0

      wait_ret =
        wait_for_block(name: 'successful block', timeout: 5) do
          if wait_i < 3
            wait_i += 1
            sleep(0.5)
            next(false)
          end

          123
        end

      if wait_ret != 123
        fail "#wait_for_block did not return expected value: got #{wait_ret.inspect}, expected 123"
      end

      expect_wait_i = 0

      wait_ret =
        wait_for_block(name: 'expectation block', timeout: 5) do
          expect_wait_i += 1
          expect(expect_wait_i).to be >= 3
          expect_wait_i
        end

      if wait_ret != 3
        fail "#wait_for_block did not retry on expectation failure: got #{wait_ret.inspect}, expected 3"
      end

      wait_success_i = 0

      wait_ret =
        wait_until_block_succeeds(name: 'block eventually succeeds', timeout: 5) do
          wait_success_i += 1

          if wait_success_i < 3
            machine.succeeds("false")
          else
            "ok"
          end
        end

      if wait_ret != "ok"
        fail "#wait_until_block_succeeds did not return expected value: got #{wait_ret.inspect}, expected 'ok'"
      end

      wait_ret =
        wait_until_block_succeeds(name: 'CommandSucceeded success', timeout: 5) do
          machine.fails("true")
        end

      if wait_ret != true
        fail "#wait_until_block_succeeds did not handle CommandSucceeded: got #{wait_ret.inspect}"
      end

      wait_ret =
        wait_until_block_fails(name: 'CommandFailed failure', timeout: 5) do
          machine.succeeds("false")
        end

      if wait_ret != true
        fail "#wait_until_block_fails did not handle CommandFailed: got #{wait_ret.inspect}"
      end

      retry_i = 0

      wait_ret =
        wait_until_block_fails(name: 'CommandSucceeded retry', timeout: 5) do
          retry_i += 1

          if retry_i < 3
            machine.fails("true")
          else
            machine.succeeds("false")
          end
        end

      if wait_ret != true
        fail "#wait_until_block_fails did not retry on CommandSucceeded: got #{wait_ret.inspect}"
      end

      wait_ret =
        wait_until_block_fails(name: 'falsey failure', timeout: 5) do
          false
        end

      if wait_ret != false
        fail "#wait_until_block_fails did not return block value: got #{wait_ret.inspect}"
      end

      begin
        wait_for_block(name: 'failed block', timeout: 5) do
          sleep(1)
          false
        end
      rescue OsVm::TimeoutError
        # ok
      else
        fail "#wait_for_block timeout not caught"
      end

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
      elsif pools.first['name'] != 'tank'
        fail "expected osctl pool 'tank', got '#{pools.first['name']}'"
      elsif pools.first['state'] != 'active'
        fail "expected osctl pool to be active, is '#{pools.first['state']}'"
      end

      existing_ct = get_container_id

      begin
        machine.wait_for_osctl_container(existing_ct, timeout: 10)
      rescue OsVm::TimeoutError
        # ok
      else
        fail "wait_for_osctl_container() did not raise TimeoutError on non-existent container"
      end

      machine.succeeds("osctl ct new --distribution alpine #{existing_ct}")

      begin
        machine.wait_for_osctl_container(existing_ct, timeout: 10)
      rescue OsVm::TimeoutError
        # ok
      else
        fail "wait_for_osctl_container() did not raise TimeoutError on stopped container"
      end

      machine.wait_for_osctl_container(existing_ct, runtime_state: 'stopped', timeout: 10)

      machine.succeeds("osctl ct start --wait 0 #{existing_ct}")

      machine.wait_for_osctl_container(existing_ct, timeout: 30)

      begin
        machine.wait_until_container_online('nonexistent-ct', timeout: 30)
      rescue OsVm::TimeoutError
        # ok
      else
        fail "wait_until_container_online() did not raise TimeoutError on non-existent container"
      end

      online_ct = get_container_id

      machine.all_succeed(
        "osctl ct new --distribution alpine #{online_ct}",
        "osctl ct unset start-menu #{online_ct}",
        "osctl ct start #{online_ct}"
      )

      begin
        machine.wait_until_container_online(online_ct, timeout: 30)
      rescue OsVm::TimeoutError
        # ok
      else
        fail "wait_until_container_online() did not raise TimeoutError"
      end

      machine.all_succeed(
        "osctl ct stop #{online_ct}",
        "osctl ct netif new bridge --link lxcbr0 #{online_ct} eth0",
        "osctl ct start #{online_ct}"
      )

      machine.wait_until_container_online(online_ct, timeout: 30)

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

      machine.wait_for_console_text(/vpsadminos login:/, timeout: 30)

      begin
        machine.wait_for_console_text(/something completely made up/, timeout: 10)
      rescue OsVm::TimeoutError
        # pass
      else
        fail "wait_for_console_text() did not raise TimeoutError"
      end

      begin
        machine.execute('echo b > /proc/sysrq-trigger')
      rescue OsVm::MachineShellClosed
        # pass
      else
        fail 'Expected OsVm::MachineShellClosed to be raised after reset'
      end

      15.times do
        break unless machine.running?

        sleep(1)
      end

      if machine.running?
        fail "Expected machine to be stopped after echo b > /proc/sysrq-trigger"
      end

      machine.start
      machine.wait_for_boot
      machine.succeeds('uptime')
      machine.stop
    '';
  }
)
