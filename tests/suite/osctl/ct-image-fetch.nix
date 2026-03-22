import ../../make-test.nix (
  { pkgs }:
  let
    flakyServer = pkgs.writeText "flaky-server.rb" ''
      require 'socket'
      require 'time'

      root = '/tmp/flaky-repo'
      count_file = '/tmp/flaky-server.count'
      error_file = '/tmp/flaky-server.error'
      failures = 2
      server = TCPServer.new('0.0.0.0', 18080)
      root_path = File.expand_path(root)

      loop do
        socket = nil

        begin
          socket = server.accept
          request = socket.gets
          next unless request

          while (line = socket.gets)
            break if line == "\r\n"
          end

          count = File.exist?(count_file) ? File.read(count_file).to_i : 0
          count += 1
          File.write(count_file, "#{count}\n")

          path = request.split[1].split('?', 2).first.sub(%r{^/}, "")
          full_path = File.expand_path(path, root_path)

          if count <= failures
            body = "temporary failure\n"
            socket.write("HTTP/1.1 503 Service Unavailable\r\n")
            socket.write("Content-Length: #{body.bytesize}\r\n")
            socket.write("Connection: close\r\n\r\n")
            socket.write(body)

          elsif !full_path.start_with?(root_path) || !File.file?(full_path)
            body = "not found\n"
            socket.write("HTTP/1.1 404 Not Found\r\n")
            socket.write("Content-Length: #{body.bytesize}\r\n")
            socket.write("Connection: close\r\n\r\n")
            socket.write(body)

          else
            body = File.binread(full_path)
            socket.write("HTTP/1.1 200 OK\r\n")
            socket.write("Content-Length: #{body.bytesize}\r\n")
            socket.write(
              "Last-Modified: #{File.mtime(full_path).httpdate}\r\n"
            )
            socket.write("Connection: close\r\n\r\n")
            socket.write(body)
          end
        rescue StandardError => e
          File.write(error_file, "#{e.class}: #{e.message}\n")
          raise
        ensure
          socket.close if socket && !socket.closed?
        end
      end
    '';
  in
  {
    name = "osctl-ct-image-fetch";

    description = ''
      Test container image fetch retries and lookup errors
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      machine.start

      def failed_output(cmd)
        machine.fails(cmd)[1]
      end

      configure_examples do |config|
        config.default_order = :defined
      end

      before(:suite) do
        @local_vendor = "fixture"
        @local_variant = "base"
        @preload_ct = "preloadct"
        @retried_ct = "retriedct"
        @missing_ct = "missingct"
        @dead_ct = "deadct"

        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        machine.all_succeed(
          "osctl ct new --distribution alpine #{@preload_ct}",
          "osctl ct unset start-menu #{@preload_ct}"
        )

        _, arch = machine.succeeds("uname -m")
        @arch = arch.strip

        machine.all_succeed(
          "rm -f /tmp/preloadct-stream.tar",
          "osctl ct export #{@preload_ct} /tmp/preloadct-stream.tar",
          "test -f /tmp/preloadct-stream.tar",
          "rm -rf /tmp/flaky-repo",
          "mkdir -p /tmp/flaky-repo",
          "cd /tmp/flaky-repo && osctl-repo local init",
          "cd /tmp/flaky-repo && osctl-repo local add " \
            "--stream /tmp/preloadct-stream.tar #{@local_vendor} " \
            "#{@local_variant} #{@arch} alpine stable",
          "cd /tmp/flaky-repo && osctl-repo local default #{@local_vendor}",
          "cd /tmp/flaky-repo && osctl-repo local default " \
            "#{@local_vendor} #{@local_variant}",
          "osctl ct del -f #{@preload_ct}"
        )

        machine.push_file("${flakyServer}", "/tmp/flaky-server.rb")

        machine.all_succeed(
          "rm -f /tmp/flaky-server.count /tmp/flaky-server.error",
          "ruby /tmp/flaky-server.rb >/tmp/flaky-server.log 2>&1 " \
            "& echo $! > /tmp/flaky-server.pid",
          "osctl repo add flaky http://127.0.0.1:18080",
          "osctl repo add dead http://127.0.0.1:18081"
        )

        machine.wait_until_succeeds(
          "test -s /tmp/flaky-server.pid " \
          "&& kill -0 $(cat /tmp/flaky-server.pid)"
        )
      end

      describe 'container image fetch' do
        it 'retries flaky repository downloads' do
          machine.all_succeed(
            "osctl ct new --repository flaky --distribution alpine " \
              "#{@retried_ct}",
            "osctl ct unset start-menu #{@retried_ct}"
          )

          count = machine.succeeds("cat /tmp/flaky-server.count")[1].to_i

          expect(count).to be >= 3
        end

        it 'reports missing images clearly' do
          output = failed_output(
            "osctl ct new --repository flaky --distribution void " \
              "#{@missing_ct}"
          )

          expect(output).to include("container image void:stable")
          expect(output).to include("not found in repositories: flaky")
          expect(output).not_to include("internal error")
        end

        it 'reports unavailable repositories clearly' do
          output = failed_output(
            "osctl ct new --repository dead --distribution alpine " \
              "#{@dead_ct}"
          )

          expect(output).to include(
            "unable to fetch container image alpine:stable"
          )
          expect(output).to include("repositories unavailable: dead")
          expect(output).not_to include("internal error")
        end
      end
    '';
  }
)
