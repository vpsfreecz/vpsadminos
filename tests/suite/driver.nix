import ../make-test.nix ({ pkgs }: {
  name = "driver";

  description = ''
    Test the test driver itself
  '';

  tags = [ "ci" ];

  machine = import ../machines/tank.nix pkgs;

  testScripts = {
    base = {
      description = ''
        Test basic functionality
      '';
      script = ''
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

        machine.wait_for_osctl_container(existing_ct, state: 'stopped', timeout: 10)

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
    };

    rspec-base = {
      description = ''
        Test RSpec example groups and expectations
      '';
      script = ''
        execution_order = []

        before(:suite) do
          execution_order << :before_suite

          machine.stop if machine.running?
        end

        after(:suite) do
          execution_order << :after_suite

          machine.stop if machine.running?

          expect(execution_order).to eq(%i[
            before_suite
            before_context
            before_example
            it
            after_example
            before_example
            it
            after_example
            before_context_nested
            before_example_nested
            it_nested
            after_example_nested
            before_example_nested
            it_nested
            after_example_nested
            after_context_nested
            after_context
            after_suite
          ])
        end

        expect { before(:context) {} }.to raise_error(RuntimeError)
        expect { before(:example) {} }.to raise_error(RuntimeError)
        expect { after(:context) {} }.to raise_error(RuntimeError)
        expect { after(:example) {} }.to raise_error(RuntimeError)

        describe 'machine' do
          before(:context) do
            execution_order << :before_context
          end

          after(:context) do
            execution_order << :after_context
          end

          before(:example) do
            execution_order << :before_example
          end

          after(:example) do
            execution_order << :after_example
          end

          it 'is really not running' do
            execution_order << :it

            expect(machine.running?).to be(false)
          end

          it 'is truly not running' do
            execution_order << :it

            expect(machine.running?).to be(false)
          end

          context 'when running' do
            before(:context) do
              execution_order << :before_context_nested

              machine.start unless machine.running?
            end

            after(:context) do
              execution_order << :after_context_nested
            end

            before(:example) do
              execution_order << :before_example_nested
            end

            after(:example) do
              execution_order << :after_example_nested
            end

            it 'is really running' do
              execution_order << :it_nested

              expect(machine.running?).to be(true)
            end

            it 'is truly running' do
              execution_order << :it_nested

              expect(machine.running?).to be(true)
            end
          end
        end

        describe 'pending' do
          it 'can be marked as pending without reason' do
            pending
            expect(0).to eq(1)
          end

          it 'can be marked as pending with reason' do
            pending('this needs fixing')
            expect(0).to eq(1)
          end

          pending 'can be declared like this' do
            expect(0).to eq(1)
          end

          pending 'without a block is skipped'

          it 'can also be set by option', pending: true do
            expect(0).to eq(1)
          end

          begin
            pending 'pending with pending option cannot be called', pending: false
          rescue ArgumentError
            # pass
          else
            raise 'pending was called with pending option'
          end
        end

        describe 'skip' do
          it 'it without a block is skipped'

          skip 'skip without a block is skipped'

          skip 'declare as skipped' do
            aise Exception, "this shouldn't be executed"
          end

          it 'can be skipped from example block without reason' do
            skip
            raise Exception, "this shouldn't be executed"
          end

          it 'can be skipped from example block with reason' do
            skip("it's not ready")
            raise Exception, "this shouldn't be executed"
          end

          it 'can be skipped using option', skip: true do
            raise Exception, "this shouldn't be executed"
          end

          begin
            skip 'skip with skip option cannot be called', skip: false
          rescue ArgumentError
            # pass
          else
            raise 'skip was called with skip option'
          end

          begin
            skip 'skip with pending option cannot be called', pending: false
          rescue ArgumentError
            # pass
          else
            raise 'skip was called with pending option'
          end
        end

        example_range = (1..5).to_a
        group_range = (6..10).to_a
        order_rand = []
        order_defined = []
        order_nested = []
        seed = 1

        describe 'order' do
          context 'by rand (default)' do
            before(:context) do
              order_rand.clear
            end

            example_range.each do |i|
              example "example ##{i}" do
                order_rand << i
              end
            end

            group_range.each do |i|
              context "context ##{i}" do
                example "example ##{i}" do
                  order_rand << i
                end
              end
            end

            after(:context) do
              expect(order_rand.sort).to eq(example_range + group_range)
            end
          end

          context 'by rand with seed', order: seed do
            before(:context) do
              order_rand.clear
            end

            example_range.each do |i|
              example "example ##{i}" do
                order_rand << i
              end
            end

            group_range.each do |i|
              context "context ##{i}" do
                example "example ##{i}" do
                  order_rand << i
                end
              end
            end

            after(:context) do
              expect(order_rand).to eq(example_range.shuffle(random: Random.new(seed)) + group_range.shuffle(random: Random.new(seed)))
            end
          end

          context 'by defined', order: :defined do
            example_range.each do |i|
              example "##{i}" do
                order_defined << i
              end
            end

            group_range.each do |i|
              context "context ##{i}" do
                example "example ##{i}" do
                  order_defined << i
                end
              end
            end

            after(:context) do
              expect(order_defined).to eq(example_range + group_range)
            end
          end

          context 'is per group', order: seed do
            example_range.each do |i|
              example "##{i}" do
                order_nested << i
              end
            end

            context 'nested', order: :defined do
              example_range.each do |i|
                example "##{i}" do
                  order_nested << i
                end
              end
            end

            after(:context) do
              expect(order_nested).to eq(example_range.shuffle(random: Random.new(seed)) + example_range)
            end
          end
        end
      '';
    };

    rspec-config = {
      description = ''
        Test RSpec with modified default configuration
      '';
      script = ''
        seed = 2
        range = (1..5).to_a
        order = []

        configure_examples do |config|
          config.default_order = seed
        end

        describe 'order by preconfigured random seed' do
          range.each do |i|
            example "example ##{i}" do
              order << i
            end
          end

          after(:context) do
            expect(order).to eq(range.shuffle(random: Random.new(seed)))
          end
        end
      '';
    };
  };
})
