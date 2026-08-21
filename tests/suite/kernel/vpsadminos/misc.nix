{ common }:
let
  mkSimpleScript =
    name: description: script:
    let
      prefix = "kmisc-${name}";
    in
    {
      "misc-${name}" = {
        inherit description;

        script = common.useMachine 2 + ''
          @misc_testct = nil

          def self.testct
            @misc_testct ||= get_container_id('${prefix}')
          end

          before(:suite) do
            ensure_kernel_machine
            cleanup_containers_with_prefix('${prefix}')

            machine.all_succeed(
              "osctl ct new --distribution alpine #{testct}",
              "osctl ct start #{testct}"
            )
          end

          after(:suite) do
            cleanup_containers_with_prefix('${prefix}')
          end

          ${script}
        '';
      };
    };
in
(mkSimpleScript "attrs"
  ''
    Test that IMMUTABLE and APPEND_ONLY flags can be set/unset in containers
  ''
  ''
    describe 'attr' do
      { 'immutable' => 'i', 'append-only' => 'a' }.each do |attr, option|
        file = "/#{attr}.file"

        context attr do
          before(:context) do
            machine.succeeds("osctl ct exec #{testct} touch #{file}")
          end

          %w[+ -].each do |cmd|
            it "allows chattr #{cmd}#{option}" do
              machine.succeeds("osctl ct exec #{testct} chattr #{cmd}#{option} #{file}")
            end
          end
        end
      end
    end
  ''
)
// (mkSimpleScript "mknod"
  ''
    Containers can use mknod
  ''
  ''
    describe 'mknod' do
      { 'char' => 'c', 'block' => 'b' }.each do |type, cmd|
        it "can mknod any #{type} device by default" do
          machine.succeeds("osctl ct exec #{testct} mknod /my-#{type}-device #{cmd} #{rand(1..100)} #{rand(0..100)}")
        end
      end
    end
  ''
)
// (mkSimpleScript "nice"
  ''
    Test that container root can renice tasks at will
  ''
  ''
    describe 'nice' do
      [-20, 19].each do |nice|
        it "can renice to #{nice}" do
          machine.succeeds("osctl ct exec #{testct} nice -n #{nice} uptime")
        end
      end
    end
  ''
)
// {
  misc-oom-kill = {
    description = ''
      Test virtualized field `oom_kill` in `/proc/vmstat`
    '';

    script = common.useMachine 2 + ''
      def self.read_container_oom_count(testct)
        machine.succeeds("osctl ct exec #{testct} grep oom_kill /proc/vmstat")[1].strip.split[1].to_i
      end

      def self.read_host_oom_count
        machine.succeeds('grep oom_kill /proc/vmstat')[1].strip.split[1].to_i
      end

      prefix = 'kmisc-oom'
      testcts = [get_container_id(prefix), get_container_id(prefix)]
      oom_counts = testcts.length.times.map do |i|
        (i + 1) * 5
      end

      before(:suite) do
        ensure_kernel_machine
        cleanup_containers_with_prefix(prefix)

        testcts.each do |testct|
          machine.all_succeed(
            "osctl ct new --distribution alpine #{testct}",
            "osctl ct set memory #{testct} 128M",
            "osctl ct start #{testct}"
          )
        end
      end

      after(:suite) do
        cleanup_containers_with_prefix(prefix)
      end

      describe 'OOM' do
        testcts.each_with_index do |testct, i|
          context "in #{testct}", order: :defined do
            other_cts = testcts - [testct]

            before(:context) do
              @my_ooms = read_container_oom_count(testct)

              @other_ooms = other_cts.to_h do |other_ct|
                [other_ct, read_container_oom_count(other_ct)]
              end

              @host_ooms = read_host_oom_count
            end

            oom_counts[i].times do |j|
              it "triggers event ##{j}" do
                machine.succeeds(
                  "status=0; " \
                    "osctl ct exec #{testct} awk 'BEGIN { s=\"xxxxxxxxxxxxxxxxxxxxxxxx\"; while (1) s=s s s }' || status=$?; " \
                    'test "$status" -eq 137 || { echo "unexpected osctl status: $status" >&2; exit 1; }',
                  timeout: 60
                )
              end

              it 'increases oom_kill count in self' do
                @my_ooms += 1
                expect(read_container_oom_count(testct)).to eq(@my_ooms)
              end

              other_cts.each do |other_ct|
                it "does not increase oom_kill count in other container #{other_ct}" do
                  expect(read_container_oom_count(other_ct)).to eq(@other_ooms[other_ct])
                end
              end

              it 'increases oom_kill count on the host' do
                @host_ooms += 1
                expect(read_host_oom_count).to eq(@host_ooms)
              end
            end
          end
        end
      end
    '';
  };
}
// (mkSimpleScript "proc"
  ''
    Test that selected `/proc` files are empty within containers
  ''
  ''
    %w[/proc/diskstats].each do |file|
      describe file do
        it 'has content on the host' do
          expect(machine.succeeds("cat #{file}")[1].strip).not_to be_empty
        end

        it 'is empty within container' do
          expect(machine.succeeds("osctl ct exec #{testct} cat #{file}")[1].strip).to be_empty
        end
      end
    end

    describe '/proc/slabinfo' do
      it 'contains only zeroes when read from within containers' do
        slabinfo = machine.succeeds("osctl ct exec #{testct} cat /proc/slabinfo")[1].strip.split("\n")
        slabinfo.drop(2).each do |line|
          _, active_objs, num_objs, _ = line.split
          next if active_objs.to_i == 0 && num_objs.to_i == 0

          raise "non-zero stats found on line #{line.inspect}"
        end
      end
    end
  ''
)
