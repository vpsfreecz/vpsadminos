import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-uid-gid";

    description = ''
      Test osctl ct uid/gid commands
    '';

    tags = [ "ci" ];

    machine = import ../../machines/tank.nix pkgs;

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      pool = 'tank'

      id1 = get_container_id
      testct1 = "#{pool}:#{id1}"

      id2 = get_container_id
      testct2 = "#{pool}:#{id2}"

      id3 = get_container_id
      testct3 = "#{pool}:#{id3}"

      def self.check_output(output, line_array)
        lines = output.strip.split("\n")

        if lines.empty? && line_array.any?
          fail 'Empty output'
        end

        lines.each_with_index do |line, i|
          if line.strip.split != line_array[i]
            fail "Expected output:\n#{line_array.map { |cols| cols.join(' ') }.join("\n")}\n" \
                 "Returned output:\n#{output}"
          end
        end
      end

      def self.check_command(type, ids, line_array)
        it "finds #{type}s as arguments" do
          _, output = machine.succeeds("osctl ct #{type} #{ids.join(' ')} 2> /dev/null")
          check_output(output, line_array)
        end

        it "finds #{type}s from stdin" do
          _, output = machine.succeeds("echo -e \"#{ids.join("\n")}\" | osctl ct #{type} - 2> /dev/null")
          check_output(output, line_array)
        end
      end

      machine.all_succeed(
        # testct1 has different uid and gid mapping
        "osctl user new --map-uid 0:100000:65536 --map-gid 0:200000:65536 #{id1}",
        "osctl ct new --user #{id1} --distribution alpine #{id1}",

        # testct2 and testct3 share the same mapping, but have different users
        "osctl user new --map 0:300000:65536 #{id2}",
        "osctl ct new --user #{id2} --distribution alpine #{id2}",

        "osctl user new --map 0:300000:65536 #{id3}",
        "osctl ct new --user #{id3} --distribution alpine #{id3}"
      )

      describe 'ct uid/gid' do
        it 'fails without arguments' do
          machine.fails('osctl ct uid')
          machine.fails('osctl ct gid')
        end
      end

      uid_header = %w[UID CONTAINER CT_UID]
      gid_header = %w[GID CONTAINER CT_GID]

      describe 'uid on testct1' do
        check_command(
          'uid',
          %w[0 1 -1 str 99999 100000 100001 165535 165536],
          [
            uid_header,
            %w[0 - -],
            %w[1 - -],
            # -1 is ignored
            # str is ignored
            %w[99999 - -],
            %W[100000 #{testct1} 0],
            %W[100001 #{testct1} 1],
            %W[165535 #{testct1} 65535],
            %w[165536 - -]
          ]
        )
      end

      describe 'gid on testct1' do
        check_command(
          'gid',
          %w[0 1 -1 str 199999 200000 200001 265535 265536],
          [
            gid_header,
            %w[0 - -],
            %w[1 - -],
            # -1 is ignored
            # str is ignored
            %w[199999 - -],
            %W[200000 #{testct1} 0],
            %W[200001 #{testct1} 1],
            %W[265535 #{testct1} 65535],
            %w[265536 - -]
          ]
        )
      end

      describe 'uid on testct2/testct3' do
        check_command(
          'uid',
          %w[299999 300000 300001 365535 365536],
          [
            uid_header,
            %w[299999 - -],
            %W[300000 #{testct2} 0],
            %W[300000 #{testct3} 0],
            %W[300001 #{testct2} 1],
            %W[300001 #{testct3} 1],
            %W[365535 #{testct2} 65535],
            %W[365535 #{testct3} 65535],
            %w[365536 - -]
          ],
        )
      end

      describe 'gid on testct2/testct3' do
        check_command(
          'gid',
          %w[299999 300000 300001 365535 365536],
          [
            gid_header,
            %w[299999 - -],
            %W[300000 #{testct2} 0],
            %W[300000 #{testct3} 0],
            %W[300001 #{testct2} 1],
            %W[300001 #{testct3} 1],
            %W[365535 #{testct2} 65535],
            %W[365535 #{testct3} 65535],
            %w[365536 - -]
          ],
        )
      end
    '';
  }
)
