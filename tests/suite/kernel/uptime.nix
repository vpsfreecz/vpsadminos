import ../../make-test.nix ({ pkgs }:
let
  containerSysinfo = pkgs.runCommand "sysinfo-to-json.py" {} ''
    echo "#!/usr/bin/env python3" > $out
    cat ${pkgs.sysinfo-to-json}/bin/sysinfo-to-json >> $out
  '';
in {
  name = "kernel-uptime";

  description = ''
    Test uptime virtualization using time namespace

    This functionality is provided by the upstream kernel and time namespace
    is set up on the containers by osctld.
  '';

  tags = [ "ci" ];

  machine = import ../../machines/with-tank.nix {
    inherit pkgs;
    config =
      { config, pkgs, ... }:
      {
        environment.systemPackages = with pkgs; [ sysinfo-to-json ];
      };
  };

  testScript = ''
    def self.parse_sysinfo(content)
      JSON.parse(content)
    end

    def self.host_sysinfo
      parse_sysinfo(machine.succeeds('sysinfo-to-json')[1])
    end

    def self.container_sysinfo(testct)
      parse_sysinfo(machine.succeeds("osctl ct runscript #{testct} /scripts/sysinfo.py")[1])
    end

    def self.parse_uptime(content)
      uptime, idle = content.strip.split
      { 'uptime' => uptime.to_f, 'idle' => idle.to_f }
    end

    def self.host_uptime
      parse_uptime(machine.succeeds('cat /proc/uptime')[1])
    end

    def self.container_uptime(testct)
      parse_uptime(machine.succeeds("osctl ct exec #{testct} cat /proc/uptime")[1])
    end

    testcts = %w[testct1 testct2 testct3]

    configure_examples do |config|
      config.default_order = :defined
    end

    before(:suite) do
      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online

      machine.mkdir('/scripts')
      machine.push_file('${containerSysinfo}', '/scripts/sysinfo.py')

      testcts.each do |testct|
        machine.all_succeed(
          "osctl ct new --distribution alpine #{testct}",
          "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
          "osctl ct start #{testct}"
        )
        machine.wait_until_container_online(testct)
        machine.succeeds("osctl ct exec #{testct} apk add python3")
      end
    end

    describe 'container' do
      before(:context) do
        testcts.each do |testct|
          machine.succeeds("osctl ct restart #{testct}")
          sleep(5)
        end
      end

      testcts.each_with_index do |testct, i|
        it "#{testct} has uptime in /proc/uptime" do
          expect(container_uptime(testct)['uptime']).to be > 0
        end

        it "#{testct} has uptime in sysinfo()" do
          expect(container_sysinfo(testct)['uptime']).to be > 0
        end

        it "#{testct} has lower uptime than host in /proc/uptime" do
          expect(container_uptime(testct)['uptime']).to be < host_uptime['uptime']
        end

        it "#{testct} has lower uptime than host in sysinfo()" do
          expect(container_sysinfo(testct)['uptime']).to be < host_sysinfo['uptime']
        end

        it "#{testct} has idle in /proc/uptime" do
          expect(container_uptime(testct)['idle']).to be > 0
        end

        next if i == 0

        testcts[0..(i - 1)].each do |other_ct|
          it "#{testct} has lower uptime than #{other_ct} in /proc/uptime" do
            expect(container_uptime(testct)['uptime']).to be < (container_uptime(other_ct)['uptime'])
          end

          it "#{testct} has lower uptime than #{other_ct} in sysinfo()" do
            expect(container_sysinfo(testct)['uptime']).to be < (container_sysinfo(other_ct)['uptime'])
          end
        end
      end

      testcts.each do |testct|
        context "is reset in #{testct} after restart" do
          before(:context) do
            @ct_uptime = container_uptime(testct)
            @ct_sysinfo = container_sysinfo(testct)

            machine.succeeds("osctl ct restart #{testct}")
          end

          example 'in /proc/uptime' do
            expect(container_uptime(testct)['uptime']).to be < @ct_uptime['uptime']
          end

          example 'in sysinfo()' do
            expect(container_sysinfo(testct)['uptime']).to be < @ct_sysinfo['uptime']
          end
        end
      end
    end
  '';
})
