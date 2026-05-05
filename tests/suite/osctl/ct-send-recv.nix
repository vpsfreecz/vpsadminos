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
    require 'shellwords'

    def self.ensure_cluster_ready
      machines.each_value do |machine|
        machine.start unless machine.running?
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
      end

      node1.wait_until_succeeds('ping -c 1 node2', timeout: 60)
      node2.wait_until_succeeds('ping -c 1 node1', timeout: 60)
    end

    def self.restart_osctld(machine)
      machine.succeeds('sv -w 60 restart osctld')
      machine.wait_for_service('osctld')
      machine.wait_for_osctl_pool('tank')
    end

    def self.restart_transfer_daemons
      machines.each_value { |machine| restart_osctld(machine) }

      node1.wait_until_succeeds('ping -c 1 node2', timeout: 60)
      node2.wait_until_succeeds('ping -c 1 node1', timeout: 60)
    end

    def self.delete_authorized_key(machine, name)
      machine.succeeds(
        "osctl receive authorized-keys del #{Shellwords.escape(name)} >/dev/null 2>&1 || true"
      )
    end

    def self.delete_authorized_keys(machine, *names)
      names.each { |name| delete_authorized_key(machine, name) }
    end

    def self.authorize_send_key(
      machine,
      name,
      pubkey,
      from: nil,
      ctid: nil,
      passphrase: nil,
      single_use: false
    )
      opts = []
      opts << "--from #{Shellwords.escape(from)}" if from
      opts << "--ctid #{Shellwords.escape(ctid)}" if ctid
      opts << "--passphrase #{Shellwords.escape(passphrase)}" if passphrase
      opts << '--single-use' if single_use
      opts << Shellwords.escape(name)

      machine.succeeds(
        "printf '%s\\n' #{Shellwords.escape(pubkey)} | osctl receive authorized-keys add #{opts.join(' ')}"
      )
    end

    def self.authorized_keys(machine)
      machine.osctl_json('receive authorized-keys ls')
    end

    def self.authorized_key(machine, name)
      authorized_keys(machine).detect { |key| key['name'] == name }
    end

    def self.authorized_key_names(machine)
      authorized_keys(machine).map { |key| key['name'] }
    end

    def self.expect_authorized_key(machine, name, present: true)
      if present
        expect(authorized_key_names(machine)).to include(name)
      else
        expect(authorized_key_names(machine)).not_to include(name)
      end
    end

    def self.refresh_send_keys(authorize_defaults: true)
      pubkeys = {}

      {
        'node1' => node1,
        'node2' => node2,
      }.each do |name, machine|
        machine.succeeds('osctl send key gen -f -t ed25519')
        pubkeys[name] = machine.succeeds('cat $(osctl send key path public)')[1].strip
      end

      delete_authorized_key(node1, 'node2')
      delete_authorized_key(node2, 'node1')

      if authorize_defaults
        authorize_send_key(node1, 'node2', pubkeys['node2'])
        authorize_send_key(node2, 'node1', pubkeys['node1'])
      end

      pubkeys
    end

    def self.ct_state(machine, ctid)
      machine.osctl_json("ct show #{ctid}")['state']
    end

    def self.ct_config_path(ctid)
      "/tank/conf/ct/#{ctid}.yml"
    end

    def self.send_public_key(machine)
      machine.succeeds('cat $(osctl send key path public)')[1].strip
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

    def self.cancel_send(machine, ctid)
      machine.succeeds("osctl ct send cancel #{ctid} >/dev/null 2>&1 || true")
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

      "restart-between-steps" = {
        description = ''
          Split send survives osctld restarts between transfer phases
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
            install_test_service(node1, ctid, 'send-restart-service')
          end

          after(:suite) do
            cleanup_container_everywhere(ctid)
          end

          describe 'restart between split send steps' do
            it 'persists and reloads source and destination transfer state' do
              transfer_files = {
                'tmp/send-transfer/restart-base' => 'restart-base',
                'tmp/send-transfer/restart-sync' => 'restart-sync',
                'tmp/send-transfer/restart-state' => 'restart-state'
              }

              write_ct_file(
                node1,
                ctid,
                'tmp/send-transfer/restart-base',
                'restart-base'
              )

              node1.succeeds("osctl ct send config #{ctid} node2")
              restart_transfer_daemons

              expect(send_log_present?(node1, ctid)).to be(true)
              expect(ct_state(node2, ctid)).to eq('staged')

              node1.succeeds("osctl ct send rootfs #{ctid}")
              restart_transfer_daemons

              expect(send_log_present?(node1, ctid)).to be(true)
              expect(ct_state(node2, ctid)).to eq('staged')

              write_ct_file(
                node1,
                ctid,
                'tmp/send-transfer/restart-sync',
                'restart-sync'
              )
              node1.succeeds("osctl ct send sync #{ctid}")
              restart_transfer_daemons

              expect(send_log_present?(node1, ctid)).to be(true)
              expect(ct_state(node2, ctid)).to eq('staged')

              write_ct_file(
                node1,
                ctid,
                'tmp/send-transfer/restart-state',
                'restart-state'
              )
              node1.succeeds("osctl ct send state #{ctid}")
              restart_transfer_daemons

              expect(send_log_present?(node1, ctid)).to be(true)
              wait_ct_running(node2, ctid)

              node1.succeeds("osctl ct send cleanup #{ctid}")

              expect_ct_absent(node1, ctid)
              expect(ct_state(node2, ctid)).to eq('running')
              expect(send_log_present?(node2, ctid)).to be(false)
              expect_ct_files(node2, ctid, transfer_files)
              expect_test_service(node2, ctid, 'send-restart-service')
            end
          end
        '';
      };

      "authorization" = {
        description = ''
          Container send authorization respects passphrases, single-use keys, and source restrictions
        '';

        script = ''
          ctid = get_container_id
          node1_pubkey = nil
          auth_key_names = %w[
            node1-repeat
            node1-once
            node1-from-ok
            node1-from-bad
          ]

          ${commonScript}

          def self.reset_authorization_state(ctid, auth_key_names)
            cancel_send(node1, ctid)
            node2.succeeds("osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true")
            delete_authorized_keys(node2, *auth_key_names)
          end

          before(:suite) do
            ensure_cluster_ready
            node1_pubkey = refresh_send_keys(authorize_defaults: false)['node1']
            reset_authorization_state(ctid, auth_key_names)

            node1.all_succeed(
              "osctl ct new --distribution alpine #{ctid}",
              "osctl ct unset start-menu #{ctid}",
              "osctl ct start #{ctid}"
            )

            wait_ct_running(node1, ctid)
          end

          after(:suite) do
            reset_authorization_state(ctid, auth_key_names)
            cleanup_container_everywhere(ctid)
          end

          describe 'authorization' do
            it 'allows reusable keys to authorize subsequent sends' do
              reset_authorization_state(ctid, auth_key_names)
              authorize_send_key(node2, 'node1-repeat', node1_pubkey, passphrase: 'repeat')

              node1.succeeds("osctl ct send --clone --passphrase repeat #{ctid} node2")
              expect_authorized_key(node2, 'node1-repeat')

              node2.succeeds("osctl ct del -f --prune #{ctid}")
              node1.succeeds("osctl ct send config --passphrase repeat #{ctid} node2")
              expect_authorized_key(node2, 'node1-repeat')

              node1.succeeds("osctl ct send cancel #{ctid}")
              expect_ct_absent(node2, ctid)
            end

            it 'consumes single-use keys and rejects later sends' do
              reset_authorization_state(ctid, auth_key_names)
              authorize_send_key(
                node2,
                'node1-once',
                node1_pubkey,
                passphrase: 'once',
                single_use: true
              )

              node1.succeeds("osctl ct send --clone --passphrase once #{ctid} node2")
              expect_authorized_key(node2, 'node1-once', present: false)

              node2.succeeds("osctl ct del -f --prune #{ctid}")
              node1.fails("osctl ct send config --passphrase once #{ctid} node2")
              expect_ct_absent(node2, ctid)
            end

            it 'disambiguates duplicate public keys by passphrase' do
              reset_authorization_state(ctid, auth_key_names)
              authorize_send_key(
                node2,
                'node1-once',
                node1_pubkey,
                passphrase: 'once',
                single_use: true
              )
              authorize_send_key(node2, 'node1-repeat', node1_pubkey, passphrase: 'repeat')

              node1.succeeds("osctl ct send --clone --passphrase repeat #{ctid} node2")
              expect_authorized_key(node2, 'node1-repeat')
              expect_authorized_key(node2, 'node1-once')
              expect(authorized_key(node2, 'node1-once')['in_use']).to be(false)

              node2.succeeds("osctl ct del -f --prune #{ctid}")
              node1.succeeds("osctl ct send --clone --passphrase once #{ctid} node2")
              expect_authorized_key(node2, 'node1-repeat')
              expect_authorized_key(node2, 'node1-once', present: false)
            end

            it 'enforces source address restrictions' do
              reset_authorization_state(ctid, auth_key_names)
              authorize_send_key(
                node2,
                'node1-from-ok',
                node1_pubkey,
                from: '192.168.10.11',
                passphrase: 'from-ok'
              )

              node1.succeeds("osctl ct send config --passphrase from-ok #{ctid} node2")
              node1.succeeds("osctl ct send cancel #{ctid}")
              expect_ct_absent(node2, ctid)

              authorize_send_key(
                node2,
                'node1-from-bad',
                node1_pubkey,
                from: '203.0.113.*',
                passphrase: 'from-bad'
              )

              node1.fails("osctl ct send config --passphrase from-bad #{ctid} node2")
              expect_ct_absent(node2, ctid)
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

      "incremental-receive-failure" = {
        description = ''
          A failed final incremental receive keeps the cutover retryable
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
            write_ct_file(
              node1,
              ctid,
              'tmp/send-transfer/before-failed-state',
              'before-failed-state'
            )

            delete_authorized_key(node2, 'node1')
            node1.fails("osctl ct send state #{ctid}")
          end

          after(:suite) do
            delete_authorized_key(node2, 'node1')
            authorize_send_key(node2, 'node1', send_public_key(node1))
            cleanup_container_everywhere(ctid)
          end

          describe 'incremental receive failure' do
            it 'keeps the source stopped with an open send state' do
              expect(ct_state(node1, ctid)).to eq('stopped')
              expect(send_log_present?(node1, ctid)).to be(true)
            end

            it 'keeps the staged target container' do
              expect(ct_state(node2, ctid)).to eq('staged')
            end

            it 'can complete the migration with another send state attempt' do
              delete_authorized_key(node2, 'node1')
              authorize_send_key(node2, 'node1', send_public_key(node1))

              node1.succeeds("osctl ct send state #{ctid}")
              node1.succeeds("osctl ct send cleanup #{ctid}")

              wait_ct_running(node2, ctid)
              expect_ct_absent(node1, ctid)
              expect(send_log_present?(node2, ctid)).to be(false)
              expect_ct_file(
                node2,
                ctid,
                'tmp/send-transfer/before-failed-state',
                'before-failed-state'
              )
            end
          end
        '';
      };

    };
  }
)
