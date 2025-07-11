import ../../make-test.nix ({ pkgs }: {
  name = "kernel-syslogns";

  description = ''
    Test syslog namespace
  '';

  tags = [ "ci" ];

  machine = import ../../machines/tank.nix pkgs;

  testScript = ''
    testct1 = get_container_id
    testct2 = get_container_id
    testcts = [testct1, testct2]
    host_message = 'host-only message'

    before(:suite) do
      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online

      testcts.each do |testct|
        machine.all_succeed(
          "osctl ct new --distribution alpine #{testct}",
          "osctl ct start #{testct}"
        )
      end
    end

    describe 'syslogns' do
      before(:context) do
        machine.succeeds("echo #{host_message} > /dev/kmsg")
      end

      testcts.each do |testct|
        context "in container #{testct}" do
          it 'does not see messages from the host' do
            _, output = machine.succeeds("osctl ct exec #{testct} dmesg")
            expect(output).not_to include(host_message)
          end

          it 'can write to kernel log' do
            msg = "write by #{testct}"
            machine.succeeds("osctl ct exec #{testct} sh -c 'echo #{msg} > /dev/kmsg'")

            _, output = machine.succeeds("osctl ct exec #{testct} dmesg")
            expect(output).to match(/^\[\s*\d+\.\d+\] #{Regexp.escape(msg)}$/)
          end

          it 'does not see messages from other containers' do
            other_cts = testcts - [testct]
            other_msgs = []

            other_cts.each do |other_ct|
              other_msgs << "message from other ct #{other_ct}"
              machine.succeeds("osctl ct exec #{other_ct} sh -c 'echo #{other_msgs.last} > /dev/kmsg'")

              _, other_output = machine.succeeds("osctl ct exec #{other_ct} dmesg")
              expect(other_output).to include(other_msgs.last)
            end

            _, output = machine.succeeds("osctl ct exec #{testct} dmesg")

            other_msgs.each do |msg|
              expect(output).not_to include(msg)
            end
          end
        end
      end

      context 'on the host' do
        it 'sees host-only message' do
            _, output = machine.succeeds('dmesg')
          expect(output).to include(host_message)
        end

        testcts.each do |testct|
          it "sees messages from container #{testct}" do
            msg = "message for host from #{testct}"
            machine.succeeds("osctl ct exec #{testct} sh -c 'echo #{msg} > /dev/kmsg'")

            _, output = machine.succeeds('dmesg')
            expect(output).to match(/^\[\s*\d+\.\d+\] \[\s*#{Regexp.escape(testct)}\s*\] #{Regexp.escape(msg)}$/)
          end
        end
      end
    end
  '';
})
