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

          elsif (mode = File.exist?('/tmp/flaky-server.mode') ? File.read('/tmp/flaky-server.mode').strip : 'good') != 'good' &&
                File.size(full_path) > 10_000
            # Adversarial framing for the repository-stream dispositions: the
            # stream body is either cut short under a full Content-Length or
            # replaced by garbage of the same length. The downloader/import must
            # fail cleanly and must not poison a later healthy fetch.
            body = File.binread(full_path)
            socket.write("HTTP/1.1 200 OK\r\n")
            socket.write("Content-Length: #{body.bytesize}\r\n")
            socket.write("Connection: close\r\n\r\n")
            case mode
            when 'truncated'
              socket.write(body.byteslice(0, body.bytesize / 2))
            when 'garbage'
              socket.write(Random.new(32_768).bytes(body.bytesize))
            end

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
        @truncated_ct = "truncatedct"
        @garbage_ct = "garbagect"
        @recovered_ct = "recoveredct"
        @rich_ct = "richct"

        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        machine.all_succeed(
          "osctl ct new --distribution alpine #{@preload_ct}",
          "osctl ct unset start-menu #{@preload_ct}"
        )

        # Rich payload for the repository import pipeline (row 31): contents,
        # numeric ownership, mode bits including setuid/sticky, symlink,
        # hardlink, FIFO, a sparse file and an ACL. Written from the host on the
        # mounted rootfs so no guest tooling is required.
        preload_rootfs = machine.succeeds(
          "osctl ct show -H -o rootfs #{@preload_ct}"
        )[1].strip
        machine.all_succeed(
          "osctl ct mount #{@preload_ct}",
          "mkdir -p #{preload_rootfs}/rich",
          "echo rich-content > #{preload_rootfs}/rich/plain",
          "echo setuid > #{preload_rootfs}/rich/setuid",
          "echo sticky > #{preload_rootfs}/rich/sticky",
          "echo sparse-head > #{preload_rootfs}/rich/sparse",
          "truncate -s 1048576 #{preload_rootfs}/rich/sparse",
          "dd if=/dev/urandom of=#{preload_rootfs}/rich/blob bs=1024 count=32 status=none",
          "sha256sum #{preload_rootfs}/rich/blob | awk '{print $1}' > /tmp/rich-blob.sha256",
          "chown 1234:5678 #{preload_rootfs}/rich/plain",
          "chmod 640 #{preload_rootfs}/rich/plain",
          "chmod 4755 #{preload_rootfs}/rich/setuid",
          "chmod 1777 #{preload_rootfs}/rich/sticky",
          "ln -s plain #{preload_rootfs}/rich/link",
          "ln #{preload_rootfs}/rich/plain #{preload_rootfs}/rich/hardlink",
          "mkfifo #{preload_rootfs}/rich/fifo",
          "echo acl > #{preload_rootfs}/rich/acl",
          "setfacl -m u:4321:rwx #{preload_rootfs}/rich/acl"
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
          "rm -f /tmp/flaky-server.count /tmp/flaky-server.error /tmp/flaky-server.mode",
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

        it 'fails cleanly on truncated and corrupt repository streams' do
          machine.succeeds("echo truncated > /tmp/flaky-server.mode")
          output = failed_output(
            "osctl ct new --repository flaky --distribution alpine " \
              "#{@truncated_ct}"
          )
          expect(output).not_to include("internal error")
          machine.fails("osctl ct show #{@truncated_ct}")

          machine.succeeds("echo garbage > /tmp/flaky-server.mode")
          output = failed_output(
            "osctl ct new --repository flaky --distribution alpine " \
              "#{@garbage_ct}"
          )
          expect(output).not_to include("internal error")
          machine.fails("osctl ct show #{@garbage_ct}")

          # A later healthy fetch must not be poisoned by the failed attempts.
          machine.succeeds("echo good > /tmp/flaky-server.mode")
          machine.all_succeed(
            "osctl ct new --repository flaky --distribution alpine " \
              "#{@recovered_ct}",
            "osctl ct unset start-menu #{@recovered_ct}",
            "osctl ct start #{@recovered_ct}",
            "osctl ct exec #{@recovered_ct} true",
            "osctl ct del -f --prune #{@recovered_ct}"
          )
        end

        it 'preserves a rich payload through the repository import pipeline' do
          machine.all_succeed(
            "osctl ct new --repository flaky --distribution alpine " \
              "#{@rich_ct}",
            "osctl ct unset start-menu #{@rich_ct}",
            "osctl ct mount #{@rich_ct}"
          )
          rootfs = machine.succeeds(
            "osctl ct show -H -o rootfs #{@rich_ct}"
          )[1].strip
          machine.all_succeed(
            "test \"$(cat #{rootfs}/rich/plain)\" = rich-content",
            "test \"$(stat -c '%u:%g:%a' #{rootfs}/rich/plain)\" = '1234:5678:640'",
            "test \"$(stat -c '%a' #{rootfs}/rich/setuid)\" = 4755",
            "test \"$(stat -c '%a' #{rootfs}/rich/sticky)\" = 1777",
            "test \"$(readlink #{rootfs}/rich/link)\" = plain",
            "test \"$(stat -c '%h' #{rootfs}/rich/plain)\" = 2",
            "test \"$(stat -c '%i' #{rootfs}/rich/plain)\" = \"$(stat -c '%i' #{rootfs}/rich/hardlink)\"",
            "test \"$(stat -c '%F' #{rootfs}/rich/fifo)\" = fifo",
            "test \"$(stat -c '%s' #{rootfs}/rich/sparse)\" = 1048576",
            "test \"$(head -c 11 #{rootfs}/rich/sparse)\" = sparse-head",
            "test \"$(stat -c '%b' #{rootfs}/rich/sparse)\" -lt 128",
            "sha256sum #{rootfs}/rich/blob | awk '{print $1}' | cmp - /tmp/rich-blob.sha256",
            "getfacl -p #{rootfs}/rich/acl | grep -E '^user:4321:rwx$'",
            "osctl ct del -f --prune #{@rich_ct}"
          )
        end
      end
    '';
  }
)
