let
  makeMachine = addr: {
    disks = [
      {
        type = "file";
        device = "{machine}-sda.img";
        size = "10G";
      }
    ];

    networks = [
      { type = "user"; }
      { type = "socket"; }
    ];

    config = {
      imports = [
        ../../configs/vpsadminos/pool-tank.nix
      ];

      networking.custom = ''
        ip addr add ${addr}/24 dev eth1
        ip link set eth1 up
      '';

      networking.hosts = {
        "192.168.10.11" = [ "node1" ];
        "192.168.10.12" = [ "node2" ];
      };
    };
  };

  commonScript = ''
    def self.ensure_cluster_ready
      machines.each_value do |machine|
        machine.start unless machine.running?
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
      end

      node1.wait_until_succeeds('ping -c 1 node2', timeout: 60)
      node2.wait_until_succeeds('ping -c 1 node1', timeout: 60)
    end

    def self.refresh_send_keys
      pubkeys = {}

      {
        'node1' => node1,
        'node2' => node2,
      }.each do |name, machine|
        machine.succeeds('osctl send key gen -f -t ed25519')
        pubkeys[name] = machine.succeeds('cat $(osctl send key path public)')[1].strip
      end

      node1.succeeds('osctl receive authorized-keys del node2 >/dev/null 2>&1 || true')
      node2.succeeds('osctl receive authorized-keys del node1 >/dev/null 2>&1 || true')

      node1.succeeds(
        %Q{printf '%s\n' "#{pubkeys['node2']}" | osctl receive authorized-keys add node2}
      )
      node2.succeeds(
        %Q{printf '%s\n' "#{pubkeys['node1']}" | osctl receive authorized-keys add node1}
      )
    end

    def self.ct_state(machine, ctid)
      machine.osctl_json("ct show #{ctid}")['state']
    end

    def self.ct_config_path(ctid)
      "/tank/conf/ct/#{ctid}.yml"
    end

    def self.send_log_present?(machine, ctid)
      status, = machine.execute("grep -q '^send_log:' #{ct_config_path(ctid)}")
      status == 0
    end

    def self.ct_exec(machine, ctid, command)
      machine.succeeds("osctl ct exec #{ctid} /bin/sh -c #{command.inspect}")
    end

    def self.wait_ct_exec(machine, ctid, command, timeout: 120)
      machine.wait_until_succeeds(
        "osctl ct exec #{ctid} /bin/sh -c #{command.inspect}",
        timeout:
      )
    end

    def self.write_ct_file(machine, ctid, path, value)
      ct_exec(
        machine,
        ctid,
        "mkdir -p /#{File.dirname(path)} && printf '%s\\n' #{value.inspect} > /#{path}"
      )
    end

    def self.expect_ct_file(machine, ctid, path, value)
      _, out = ct_exec(machine, ctid, "cat /#{path}")
      expect(out.strip).to eq(value)
    end

    def self.expect_ct_files(machine, ctid, files)
      files.each do |path, value|
        expect_ct_file(machine, ctid, path, value)
      end
    end

    def self.install_test_service(machine, ctid, value)
      rootfs = machine.succeeds("osctl ct show -H -o rootfs #{ctid}")[1].strip

      machine.succeeds(<<~CMD)
        cat > #{rootfs}/etc/init.d/transfer-service <<'EOF'
        #!/sbin/openrc-run
        command="/bin/sleep"
        command_args="2147483647"
        command_background="yes"
        pidfile="/run/transfer-service.pid"

        start_pre() {
          printf '%s\\n' #{value.inspect} > /run/transfer-service.value
        }
        EOF
        chmod +x #{rootfs}/etc/init.d/transfer-service
      CMD

      ct_exec(machine, ctid, 'rc-update add transfer-service default')
      ct_exec(machine, ctid, 'rc-service transfer-service start')
      expect_test_service(machine, ctid, value)
    end

    def self.expect_test_service(machine, ctid, value)
      wait_ct_exec(machine, ctid, 'rc-service transfer-service status', timeout: 60)
      _, out = wait_ct_exec(machine, ctid, 'cat /run/transfer-service.value', timeout: 60)
      expect(out.strip).to eq(value)
    end

    def self.hook_path(ctid, hook_name)
      "/tank/hook/ct/#{ctid}/#{hook_name}"
    end

    def self.install_hook(machine, ctid, hook_name, script)
      path = hook_path(ctid, hook_name)

      machine.succeeds(<<~CMD)
        install -d -m 700 #{File.dirname(path)}
        cat > #{path} <<'EOF'
        #{script}
        EOF
        chmod 700 #{path}
      CMD
    end

    def self.remove_hook(machine, ctid, hook_name)
      machine.succeeds("rm -f #{hook_path(ctid, hook_name)}")
    end

    def self.prepare_send(ctid)
      node1.all_succeed(
        "osctl ct send config #{ctid} node2",
        "osctl ct send rootfs #{ctid}"
      )
    end

    def self.wait_ct_running(machine, ctid)
      wait_for_block(name: "#{ctid} becomes running", timeout: 120) do
        state = ct_state(machine, ctid)
        next false unless state == 'running'

        state
      end

      machine.wait_until_succeeds("osctl ct exec #{ctid} true", timeout: 120)
    end

    def self.expect_ct_absent(machine, ctid, timeout: 60)
      wait_until_block_fails(name: "#{ctid} disappears", timeout: timeout) do
        machine.succeeds("osctl ct show #{ctid}")
      end
    end

    def self.cleanup_container_everywhere(ctid)
      {
        'node1' => node1,
        'node2' => node2,
      }.each_value do |machine|
        machine.succeeds("osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true")
      end
    end

    configure_examples do |config|
      config.default_order = :defined
    end
  '';
in
import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-send-recv";

    description = ''
      Test osctl ct send/recv
    '';

    tags = [ "ci" ];

    machines = {
      node1 = makeMachine "192.168.10.11";

      node2 = makeMachine "192.168.10.12";
    };

    testScripts = {
      "happy-path" = {
        description = ''
          Container send and receive works in both directions
        '';

        script = ''
          ctid = get_container_id

          ${commonScript}

          before(:suite) do
            ensure_cluster_ready
            refresh_send_keys

            node2.fails("osctl ct show #{ctid}")

            node1.all_succeed(
              "osctl ct new --distribution alpine #{ctid}",
              "osctl ct unset start-menu #{ctid}",
              "osctl ct start #{ctid}"
            )

            wait_ct_running(node1, ctid)
            install_test_service(node1, ctid, 'send-service')
          end

          after(:suite) do
            cleanup_container_everywhere(ctid)
          end

          describe 'happy path' do
            it 'moves the container to node2 and back to node1' do
              transfer_files = {
                'tmp/send-transfer/before-rootfs' => 'before-rootfs',
                'tmp/send-transfer/after-rootfs' => 'after-rootfs',
                'tmp/send-transfer/after-sync' => 'after-sync'
              }

              write_ct_file(node1, ctid, 'tmp/send-transfer/before-rootfs', 'before-rootfs')

              node1.all_succeed(
                "osctl ct send config #{ctid} node2",
                "osctl ct send rootfs #{ctid}"
              )

              write_ct_file(node1, ctid, 'tmp/send-transfer/after-rootfs', 'after-rootfs')
              node1.succeeds("osctl ct send sync #{ctid}")

              write_ct_file(node1, ctid, 'tmp/send-transfer/after-sync', 'after-sync')
              node1.all_succeed(
                "osctl ct send state #{ctid}",
                "osctl ct send cleanup #{ctid}"
              )

              wait_ct_running(node2, ctid)
              expect_ct_absent(node1, ctid)
              expect(ct_state(node2, ctid)).to eq('running')
              expect(send_log_present?(node2, ctid)).to be(false)
              expect_ct_files(node2, ctid, transfer_files)
              expect_test_service(node2, ctid, 'send-service')

              write_ct_file(node2, ctid, 'tmp/send-transfer/before-return', 'before-return')

              node2.succeeds("osctl ct send #{ctid} node1")

              wait_ct_running(node1, ctid)
              expect_ct_absent(node2, ctid)
              expect(ct_state(node1, ctid)).to eq('running')
              expect(send_log_present?(node1, ctid)).to be(false)
              expect_ct_files(
                node1,
                ctid,
                transfer_files.merge('tmp/send-transfer/before-return' => 'before-return')
              )
              expect_test_service(node1, ctid, 'send-service')
            end
          end
        '';
      };

      "source-stop-failure" = {
        description = ''
          A failed source stop keeps the cutover retryable
        '';

        script = ''
          ctid = get_container_id

          ${commonScript}

          before(:suite) do
            ensure_cluster_ready
            refresh_send_keys

            node1.all_succeed(
              "osctl ct new --distribution alpine #{ctid}",
              "osctl ct unset start-menu #{ctid}",
              "osctl ct start #{ctid}"
            )

            wait_ct_running(node1, ctid)
            prepare_send(ctid)

            install_hook(node1, ctid, 'pre-stop', <<~HOOK)
              #!/bin/sh
              exit 1
            HOOK

            node1.fails("osctl ct send state #{ctid}")
          end

          after(:suite) do
            remove_hook(node1, ctid, 'pre-stop')
            cleanup_container_everywhere(ctid)
          end

          describe 'source stop failure' do
            it 'keeps the container on the source node' do
              expect(ct_state(node1, ctid)).to eq('running')
            end

            it 'keeps the send state on the source' do
              expect(send_log_present?(node1, ctid)).to be(true)
            end

            it 'keeps the staged target container' do
              expect(ct_state(node2, ctid)).to eq('staged')
            end

            it 'can complete the migration with another send state attempt' do
              remove_hook(node1, ctid, 'pre-stop')

              node1.succeeds("osctl ct send state #{ctid}")
              node1.succeeds("osctl ct send cleanup #{ctid}")

              wait_ct_running(node2, ctid)
              expect_ct_absent(node1, ctid)
              expect(send_log_present?(node2, ctid)).to be(false)
            end
          end
        '';
      };

      "source-restart-failure" = {
        description = ''
          A failed source restart in clone mode keeps the cutover retryable
        '';

        script = ''
          ctid = get_container_id

          ${commonScript}

          before(:suite) do
            ensure_cluster_ready
            refresh_send_keys

            node1.all_succeed(
              "osctl ct new --distribution alpine #{ctid}",
              "osctl ct unset start-menu #{ctid}",
              "osctl ct start #{ctid}"
            )

            wait_ct_running(node1, ctid)
            prepare_send(ctid)

            install_hook(node1, ctid, 'pre-start', <<~HOOK)
              #!/bin/sh
              exit 1
            HOOK

            node1.fails("osctl ct send state --clone #{ctid}")
          end

          after(:suite) do
            remove_hook(node1, ctid, 'pre-start')
            cleanup_container_everywhere(ctid)
          end

          describe 'source restart failure' do
            it 'keeps the source container stopped on node1' do
              expect(ct_state(node1, ctid)).to eq('stopped')
            end

            it 'keeps the transfer state open' do
              expect(send_log_present?(node1, ctid)).to be(true)
              expect(ct_state(node2, ctid)).to eq('staged')
            end

            it 'can finish with another send state attempt' do
              remove_hook(node1, ctid, 'pre-start')

              node1.succeeds("osctl ct send state --clone #{ctid}")
              node1.succeeds("osctl ct send cleanup #{ctid}")

              wait_ct_running(node1, ctid)
              wait_ct_running(node2, ctid)

              expect(ct_state(node1, ctid)).to eq('running')
              expect(ct_state(node2, ctid)).to eq('running')
              expect(send_log_present?(node1, ctid)).to be(false)
              expect(send_log_present?(node2, ctid)).to be(false)
            end
          end
        '';
      };

      "target-start-failure" = {
        description = ''
          A failed target start keeps the cutover retryable
        '';

        script = ''
          ctid = get_container_id

          ${commonScript}

          before(:suite) do
            ensure_cluster_ready
            refresh_send_keys

            node1.all_succeed(
              "osctl ct new --distribution alpine #{ctid}",
              "osctl ct unset start-menu #{ctid}",
              "osctl ct start #{ctid}"
            )

            wait_ct_running(node1, ctid)
            prepare_send(ctid)

            install_hook(node2, ctid, 'pre-start', <<~HOOK)
              #!/bin/sh
              exit 1
            HOOK

            node1.fails("osctl ct send state #{ctid}")
          end

          after(:suite) do
            remove_hook(node2, ctid, 'pre-start')
            cleanup_container_everywhere(ctid)
          end

          describe 'target start failure' do
            it 'keeps the source container on node1' do
              expect(ct_state(node1, ctid)).to eq('stopped')
            end

            it 'keeps the transfer state open' do
              expect(send_log_present?(node1, ctid)).to be(true)
              expect(ct_state(node2, ctid)).to eq('staged')
            end

            it 'can finish with another send state attempt' do
              remove_hook(node2, ctid, 'pre-start')

              node1.succeeds("osctl ct send state #{ctid}")
              wait_ct_running(node2, ctid)
              node1.succeeds("osctl ct send cleanup #{ctid}")

              expect_ct_absent(node1, ctid)
              expect(send_log_present?(node2, ctid)).to be(false)
            end
          end
        '';
      };

    };
  }
)
