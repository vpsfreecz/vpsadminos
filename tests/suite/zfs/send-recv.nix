import ../../make-test.nix (
  { pkgs }:
  {
    name = "zfs-send-recv";
    description = "Two-hop full and incremental ZFS sends across equal and different ashifts";
    tags = [
      "ci"
      "regression"
    ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        environment.systemPackages = with pkgs; [
          python3
          diffutils
        ];
        environment.etc."zfs-send-recv.py".source = ./send-recv.py;
      };
    };

    testScript = ''
      run = ->(command) { machine.succeeds(command, timeout: 60)[1] }
      fixture = 'python3 /etc/zfs-send-recv.py'
      scratch = '/tank/zfs-send-recv'
      reopen = lambda do
        run.call('zpool sync ashift-dst')
        run.call('zpool export ashift-dst')
        # cachefile is not persistent across export/import; zdb -e needs the
        # reopened pool absent from the default cache's imported namespace.
        run.call("zpool import -o cachefile=none -d #{scratch}/backing ashift-dst")
        expect(run.call('zpool get -H -o value cachefile ashift-dst').strip).to eq('none')
      end
      verify = lambda do |oracle, dataset, snapshot|
        root = "/mnt/#{dataset}"
        # Integrity reads must not dirty receivers before the next incremental.
        expect(run.call("zfs get -H -o value,source atime #{dataset}").strip).to eq(
          "off\tinherited from #{dataset.split('/').first}"
        )
        run.call("#{fixture} verify #{oracle} #{snapshot} #{root}")
        %w[s0 s1].take(snapshot == 's0' ? 1 : 2).each do |version|
          run.call("#{fixture} verify #{oracle} #{version} #{root}/.zfs/snapshot/#{version}")
        end
      end

      before(:suite) do
        machine.start
        machine.wait_for_osctl_pool('tank')
        run.call("mkdir -p #{scratch}/backing")
        %w[vdev_file_logical_ashift vdev_file_physical_ashift].each do |parameter|
          path = "/sys/module/zfs/parameters/#{parameter}"
          run.call("if test -e #{path}; then test \"$(cat #{path})\" = 9; fi")
        end
      end

      describe 'two-hop ZFS send/receive integrity', order: :defined do
        [[9, 12], [9, 9], [12, 12], [12, 9]].each do |source_ashift, destination_ashift|
          [true, false].each do |compressed|
            it "preserves full and incremental data #{source_ashift}->#{destination_ashift}, compressed=#{compressed}" do
              mode = compressed ? '-c -L' : '-L'
              oracle = "#{scratch}/#{source_ashift}-#{destination_ashift}-#{compressed}"
              critical = compressed && source_ashift == 9 && destination_ashift == 12
              [["ashift-src", source_ashift], ["ashift-dst", destination_ashift]].each do |pool, ashift|
                run.call("truncate -s 512M #{scratch}/backing/#{pool}")
                run.call("zpool create -o ashift=#{ashift} -o cachefile=none -o feature@embedded_data=disabled " \
                         "-O compression=lz4 -O recordsize=4K -O dedup=off -O copies=1 -O atime=off " \
                         "-O mountpoint=/mnt/#{pool} #{pool} #{scratch}/backing/#{pool}")
                puts run.call("zpool status -P #{pool}")
                config = run.call("zdb -e -p #{scratch}/backing -C #{pool}")
                puts config
                # Dedicated pools have one file leaf: bind its type/path/ashift.
                leaf = config.split(/children\[0\]:/).last
                expect(leaf).to match(/type: 'file'/)
                expect(leaf).to include("path: '#{scratch}/backing/#{pool}'")
                expect(leaf.scan(/ashift: (\d+)/).flatten).to eq([ashift.to_s])
              end
              run.call('zfs create -o compression=lz4 -o recordsize=4K -o dedup=off -o copies=1 ashift-src/source')
              puts run.call("#{fixture} generate #{oracle}")
              run.call("cp -r #{oracle}/s0/. /mnt/ashift-src/source/")
              run.call('zpool sync ashift-src && zfs snapshot ashift-src/source@s0')
              verify.call(oracle, 'ashift-src/source', 's0')

              %w[s0 s1].each do |snapshot|
                if snapshot == 's1'
                  run.call("#{fixture} update /mnt/ashift-src/source")
                  run.call('zpool sync ashift-src && zfs snapshot ashift-src/source@s1')
                  verify.call(oracle, 'ashift-src/source', 's1')
                end
                incremental = snapshot == 's1' ? '-i @s0' : ""
                # pipefail checks both producer and receiver; hold -L constant.
                run.call("bash -o pipefail -c 'zfs send #{mode} #{incremental} ashift-src/source@#{snapshot} | zfs receive ashift-dst/first'")
                verify.call(oracle, 'ashift-dst/first', snapshot)
                reopen.call
                verify.call(oracle, 'ashift-dst/first', snapshot)
                puts run.call("#{fixture} trigger #{oracle} #{snapshot}") if critical

                run.call("bash -o pipefail -c 'zfs send #{mode} #{incremental} ashift-dst/first@#{snapshot} | zfs receive ashift-dst/second'")
                verify.call(oracle, 'ashift-dst/second', snapshot)
                reopen.call
                %w[first second].each { |copy| verify.call(oracle, "ashift-dst/#{copy}", snapshot) }
                puts run.call("#{fixture} trigger #{oracle} #{snapshot} second") if critical
              end

              # Scrub supplements independent byte checks, which also catch
              # the historical corruption that scrub itself did not detect.
              run.call('zpool scrub ashift-dst')
              machine.succeeds('zpool wait -t scrub ashift-dst', timeout: 120)
              status = run.call('zpool status -p ashift-dst')
              puts status
              expect(status).to include('errors: No known data errors')
              expect(status).to match(/scan: scrub repaired 0B .* with 0 errors/)
              rows = status.lines.grep(/^\s+\S+\s+ONLINE\s+\d+/)
              expect(rows.length).to eq(2)
              rows.each { |row| expect(row).to match(/ONLINE\s+0\s+0\s+0\s*$/) }
              %w[first second].each { |copy| verify.call(oracle, "ashift-dst/#{copy}", 's1') }
            end
          end
        end

        after(:example) do
          # Only these two test-owned pools and their backing files are ours.
          %w[ashift-dst ashift-src].each do |pool|
            run.call("if zpool list -H #{pool} >/dev/null 2>&1; then zpool destroy #{pool}; fi")
            run.call("rm -f #{scratch}/backing/#{pool}")
          end
        end
      end
    '';
  }
)
