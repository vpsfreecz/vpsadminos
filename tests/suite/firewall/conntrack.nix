let
  network = [
    { type = "user"; }
  ];

  noConntrackServerAddress = "192.168.10.10";
  noConntrackAllowedAddress = "192.168.10.11";
  noConntrackDeniedAddress = "192.168.10.12";

  conntrackServerAddress = "192.168.11.10";
  conntrackClientAddress = "192.168.11.11";

  loggingServerAddress = "192.168.12.10";
in
import ../../make-test.nix (
  { pkgs }:
  let
    lib = pkgs.lib;

    serverScript = pkgs.writeText "firewall-test-server.rb" ''
      require 'socket'

      def serve_tcp(port, reply, hold_seconds: 0)
        server = TCPServer.new('0.0.0.0', port)

        loop do
          socket = server.accept

          Thread.new(socket) do |client|
            begin
              client.write(reply)
              sleep hold_seconds if hold_seconds.positive?
            ensure
              client.close
            end
          end
        end
      end

      def serve_udp(port, reply)
        socket = UDPSocket.new
        socket.bind('0.0.0.0', port)

        loop do
          _, addr = socket.recvfrom(65_535)
          socket.send(reply, 0, addr[3], addr[1])
        end
      end

      threads = [
        Thread.new { serve_tcp(8080, "protected-tcp\n", hold_seconds: 20) },
        Thread.new { serve_tcp(8081, "open-tcp\n") },
        Thread.new { serve_udp(5353, "protected-udp\n") },
        Thread.new { serve_udp(5354, "open-udp\n") },
      ]

      threads.each(&:join)
    '';

    baseConfig =
      name: serverAddress: clientAddresses:
      { ... }:
      {
        networking = {
          hostName = name;
          lxcbr.enable = false;
          custom = ''
            ip netns del client 2>/dev/null || true
            ip link del veth-host 2>/dev/null || true

            ip link add veth-host type veth peer name veth-client
            ip addr add ${serverAddress}/24 dev veth-host
            ip link set veth-host up

            ip netns add client
            ip link set veth-client netns client
            ip -n client link set lo up
            ${lib.concatMapStringsSep "\n" (
              address: "ip -n client addr add ${address}/24 dev veth-client"
            ) clientAddresses}
            ip -n client link set veth-client up
          '';
        };

        environment.systemPackages = [
          pkgs.conntrack-tools
          pkgs.iproute2
          pkgs.ruby
        ];

        networking.chronyd = false;
        runit.services.network-online.runlevels = lib.mkForce [ ];
        services.openssh.openFirewall = false;
      };

    mkMachine =
      name: serverAddress: clientAddresses: extraConfig:
      (import ../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config =
          args@{ ... }:
          lib.mkMerge [
            (baseConfig name serverAddress clientAddresses args)
            (extraConfig args)
          ];
      })
      // {
        networks = network;
      };

    commonScript = serverAddress: ''
      command_output = lambda do |machine, command|
        status, output = machine.execute(command)
        expect(status).to eq(0), output
        output.strip
      end

      expect_command_to_fail = lambda do |machine, command|
        status, output = machine.execute(command)
        expect(status).not_to eq(0), output
      end

      refuse_log_rule_count = lambda do |machine|
        command_output.call(
          machine,
          'iptables-save | grep -- "^-A nixos-fw-log-refuse " | { grep -c -- " -j LOG" || true; }'
        )
      end

      tcp_command = lambda do |port, source_address|
        <<~CMD
          ip netns exec client ruby - <<'RUBY'
            require 'socket'
            require 'timeout'

            Timeout.timeout(3) do
              socket = Socket.new(:INET, :STREAM)
              socket.bind(Socket.sockaddr_in(0, "#{source_address}"))
              socket.connect(Socket.sockaddr_in(#{port}, "${serverAddress}"))

              begin
                puts socket.readpartial(4096).strip
            ensure
              socket.close
            end
          end
          RUBY
        CMD
      end

      tcp_hold_command = lambda do |port, source_address|
        <<~CMD
          ip netns exec client ruby - <<'RUBY' >/tmp/tcp-hold-#{port}.log 2>&1 &
            require 'socket'
            require 'timeout'

            Timeout.timeout(20) do
              socket = Socket.new(:INET, :STREAM)
              socket.bind(Socket.sockaddr_in(0, "#{source_address}"))
              socket.connect(Socket.sockaddr_in(#{port}, "${serverAddress}"))

              begin
                puts socket.readpartial(4096).strip
              sleep 15
            ensure
              socket.close
            end
          end
          RUBY
        CMD
      end

      udp_command = lambda do |port, source_address|
        <<~CMD
          ip netns exec client ruby - <<'RUBY'
          require 'socket'

          socket = UDPSocket.new
          socket.bind("#{source_address}", 0)
          socket.connect("${serverAddress}", #{port})
          socket.send("hello", 0)

          raise 'timeout' unless IO.select([socket], nil, nil, 3)

          puts socket.recv(4096).strip
          RUBY
        CMD
      end
    '';
  in
  {
    name = "firewall-conntrack";

    description = ''
      Test vpsAdminOS firewall with and without init network namespace conntrack
    '';

    tags = [ "ci" ];

    testScriptJobs = 2;

    machines = {
      no_conntrack_server =
        mkMachine "firewall-no-conntrack-server" noConntrackServerAddress
          [
            noConntrackAllowedAddress
            noConntrackDeniedAddress
          ]
          (
            { ... }:
            {
              networking.firewall = {
                conntrack.enable = false;
                protectedRules = [
                  {
                    protocol = "tcp";
                    ports = [ 8080 ];
                    allowedIPv4Ranges = [ "${noConntrackAllowedAddress}/32" ];
                    comment = "firewall-test-protected-tcp";
                  }
                  {
                    protocol = "udp";
                    ports = [ 5353 ];
                    allowedIPv4Ranges = [ "${noConntrackAllowedAddress}/32" ];
                    comment = "firewall-test-protected-udp";
                  }
                ];
              };

              runit.services.firewall-test-server = {
                run = ''
                  exec ${pkgs.ruby}/bin/ruby ${serverScript}
                '';
              };
            }
          );

      conntrack_server =
        mkMachine "firewall-conntrack-server" conntrackServerAddress
          [
            conntrackClientAddress
          ]
          (
            { ... }:
            {
              networking.firewall = {
                conntrack.enable = true;
                allowedTCPPorts = [ 8080 ];
                allowedUDPPorts = [ 5353 ];
              };

              runit.services.firewall-test-server = {
                run = ''
                  exec ${pkgs.ruby}/bin/ruby ${serverScript}
                '';
              };
            }
          );

      logging_server = mkMachine "firewall-logging-server" loggingServerAddress [ ] (
        { ... }:
        {
          networking.firewall = {
            conntrack.enable = true;
            logRefusedConnections = true;
          };
        }
      );
    };

    testScripts = {
      no-conntrack = {
        description = ''
          Check the stateless default-open firewall with raw-table notrack
        '';

        script = commonScript noConntrackServerAddress + ''
          describe 'firewall without conntrack' do
            before(:context) do
              no_conntrack_server.start
              no_conntrack_server.wait_for_service('firewall')
              no_conntrack_server.wait_for_service('firewall-test-server')
              no_conntrack_server.wait_until_succeeds(
                'ip netns exec client ip addr show veth-client | grep -q ${noConntrackAllowedAddress}',
                timeout: 60
              )
            end

            it 'installs raw-table notrack rules' do
              no_conntrack_server.wait_until_succeeds(
                'iptables-save -t raw | grep -- "^-A PREROUTING" | grep -q -- "nixos-fw-notrack"',
                timeout: 60
              )
              no_conntrack_server.wait_until_succeeds(
                'iptables-save -t raw | grep -- "^-A OUTPUT" | grep -q -- "nixos-fw-notrack"',
                timeout: 60
              )
            end

            it 'declares the notrack target kernel module' do
              expect(
                command_output.call(no_conntrack_server, 'test -d /sys/module/xt_CT && echo present')
              ).to eq('present')
            end

            it 'leaves unprotected ports open' do
              no_conntrack_server.wait_until_succeeds(
                tcp_command.call(8081, "${noConntrackDeniedAddress}"),
                timeout: 60
              )

              expect(
                command_output.call(no_conntrack_server, tcp_command.call(8081, "${noConntrackDeniedAddress}"))
              ).to eq('open-tcp')
              expect(
                command_output.call(no_conntrack_server, udp_command.call(5354, "${noConntrackDeniedAddress}"))
              ).to eq('open-udp')
            end

            it 'allows protected ports from configured sources' do
              expect(
                command_output.call(no_conntrack_server, tcp_command.call(8080, "${noConntrackAllowedAddress}"))
              ).to eq('protected-tcp')
              expect(
                command_output.call(no_conntrack_server, udp_command.call(5353, "${noConntrackAllowedAddress}"))
              ).to eq('protected-udp')
            end

            it 'drops protected ports from other sources' do
              expect_command_to_fail.call(
                no_conntrack_server,
                "timeout 4s " + tcp_command.call(8080, "${noConntrackDeniedAddress}")
              )
              expect_command_to_fail.call(
                no_conntrack_server,
                "timeout 4s " + udp_command.call(5353, "${noConntrackDeniedAddress}")
              )
            end

            it 'uses the compatibility refuse chain for protected denials' do
              expect(
                command_output.call(
                  no_conntrack_server,
                  'iptables-save | grep -- "--comment firewall-test-protected-tcp" | grep -c -- "-j nixos-fw-log-refuse"'
                )
              ).to eq('1')
              expect(
                command_output.call(
                  no_conntrack_server,
                  'iptables-save | grep -- "--comment firewall-test-protected-udp" | grep -c -- "-j nixos-fw-log-refuse"'
                )
              ).to eq('1')
            end

            it 'does not log refused traffic by default' do
              expect(refuse_log_rule_count.call(no_conntrack_server)).to eq('0')
            end

            it 'does not duplicate notrack rules on reload' do
              # `sv 1` returns before the control script runs. Make the old
              # table fail the two-rule completion predicate.
              reload_command = [
                'iptables -w -t raw -I PREROUTING 1 -m comment --comment nixos-fw-notrack -j CT --notrack',
                'sv 1 firewall',
              ].join(' && ')

              status, output = no_conntrack_server.execute(reload_command)
              expect(status).to eq(0), output

              reload_ready_command = [
                'test "$(iptables-save -t raw | grep -c -- "--comment nixos-fw-notrack")" = 2',
                'iptables-save | grep -- "--comment firewall-test-protected-tcp" | grep -q -- "-j nixos-fw-log-refuse"',
                'iptables-save | grep -- "--comment firewall-test-protected-udp" | grep -q -- "-j nixos-fw-log-refuse"',
                'iptables -w -C INPUT -j nixos-fw',
                '! iptables -w -C INPUT -j nixos-drop 2>/dev/null',
              ].join(' && ')

              no_conntrack_server.wait_until_succeeds(
                reload_ready_command,
                timeout: 60
              )
            end

            it 'does not create conntrack entries' do
              expect(
                command_output.call(no_conntrack_server, 'conntrack -L 2>/dev/null | sed "/^$/d" | wc -l')
              ).to eq('0')
            end
          end
        '';
      };

      conntrack = {
        description = ''
          Check the stateful default-deny firewall with conntrack enabled
        '';

        script = commonScript conntrackServerAddress + ''
          describe 'firewall with conntrack' do
            before(:context) do
              conntrack_server.start
              conntrack_server.wait_for_service('firewall')
              conntrack_server.wait_for_service('firewall-test-server')
              conntrack_server.wait_until_succeeds(
                'ip netns exec client ip addr show veth-client | grep -q ${conntrackClientAddress}',
                timeout: 60
              )
            end

            it 'uses the conntrack state rule without raw-table notrack' do
              conntrack_server.wait_until_succeeds(
                'iptables-save | grep -Eq -- "-m conntrack --ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED)"',
                timeout: 60
              )

              expect(
                command_output.call(conntrack_server, 'iptables-save -t raw | { grep -c -- "--comment nixos-fw-notrack" || true; }')
              ).to eq('0')
            end

            it 'allows configured legacy service ports' do
              conntrack_server.wait_until_succeeds(
                tcp_command.call(8080, "${conntrackClientAddress}"),
                timeout: 60
              )

              expect(
                command_output.call(conntrack_server, tcp_command.call(8080, "${conntrackClientAddress}"))
              ).to eq('protected-tcp')
              expect(
                command_output.call(conntrack_server, udp_command.call(5353, "${conntrackClientAddress}"))
              ).to eq('protected-udp')
            end

            it 'drops unconfigured service ports' do
              expect_command_to_fail.call(
                conntrack_server,
                "timeout 4s " + tcp_command.call(8081, "${conntrackClientAddress}")
              )
              expect_command_to_fail.call(
                conntrack_server,
                "timeout 4s " + udp_command.call(5354, "${conntrackClientAddress}")
              )
            end

            it 'uses a silent refuse chain by default' do
              conntrack_server.wait_until_succeeds(
                'iptables-save | grep -q -- "^-A nixos-fw -j nixos-fw-log-refuse"',
                timeout: 60
              )

              expect(refuse_log_rule_count.call(conntrack_server)).to eq('0')
            end

            it 'creates conntrack entries for active connections' do
              status, output = conntrack_server.execute(
                tcp_hold_command.call(8080, "${conntrackClientAddress}")
              )
              expect(status).to eq(0), output

              conntrack_server.wait_until_succeeds(
                'conntrack -L -p tcp 2>/dev/null | grep -q "dport=8080"',
                timeout: 20
              )
            end
          end
        '';
      };

      logging = {
        description = ''
          Check explicit refuse logging opt-in
        '';

        script = commonScript loggingServerAddress + ''
          describe 'firewall refuse logging opt-in' do
            before(:context) do
              logging_server.start
              logging_server.wait_for_service('firewall')
            end

            it 'adds LOG rules when refused connection logging is enabled' do
              logging_server.wait_until_succeeds(
                'iptables-save | grep -- "^-A nixos-fw-log-refuse " | grep -- "-j LOG" | grep -q -- "refused connection"',
                timeout: 60
              )

              expect(refuse_log_rule_count.call(logging_server)).to eq('1')
            end
          end
        '';
      };
    };
  }
)
