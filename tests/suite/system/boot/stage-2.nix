import ../../../make-test.nix (
  { pkgs }:
  {
    name = "system-boot-stage-2";

    description = ''
      Test vpsAdminOS stage 2 boot initialization
    '';

    tags = [ "ci" ];

    machine = import ../../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      def self.parse_uptime_command(content)
        match = content.match(/\bup\s+(?:(\d+)\s+days?,?\s+)?(?:(\d+):(\d+)|(\d+)\s+min),/)
        raise "Unable to parse uptime output: #{content.inspect}" if match.nil?

        days = (match[1] || '0').to_i
        hours = (match[2] || '0').to_i
        minutes = (match[3] || match[4] || '0').to_i

        ((days * 24) + hours) * 60 + minutes
      end

      def self.proc_uptime_minutes
        (machine.succeeds('cat /proc/uptime')[1].split.first.to_f / 60).floor
      end

      before(:suite) do
        machine.start
        machine.wait_for_service('set-clock')
      end

      describe 'utmp boot record' do
        it 'records boot time' do
          _, boot_time = machine.succeeds(
            %q(utmpdump /run/utmp 2>/dev/null | awk '$1 == "[2]" { print }')
          )

          expect(boot_time).to include('[reboot')
        end

        it 'keeps uptime independent from the utmp file timestamp' do
          machine.succeeds("touch -d '2006-01-01 00:00:00 UTC' /run/utmp")

          _, uptime = machine.succeeds('uptime')

          expect(parse_uptime_command(uptime)).to be_within(1).of(proc_uptime_minutes)
        end
      end

      describe 'wtmp log' do
        it 'exists for last' do
          machine.succeeds('test -f /var/log/wtmp')
          machine.succeeds('last >/dev/null')
        end
      end
    '';
  }
)
