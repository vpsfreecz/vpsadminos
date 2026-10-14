import ../../make-test.nix (
  { pkgs }:
  let
    inherit (pkgs) lib;
    guests = import ../../fixtures/nixos-persistence-guests.nix {
      system = pkgs.system;
      source = ../../..;
    };
    variantName = name: lib.replaceStrings [ "_" ] [ "." ] name;
    allClosures = lib.concatMap (
      v: builtins.attrValues v.generations ++ builtins.attrValues (v.failures or { })
    ) (builtins.attrValues guests.variants);
    registrations = lib.mapAttrs (
      _: variant:
      pkgs.closureInfo {
        rootPaths =
          builtins.attrValues variant.generations ++ builtins.attrValues (variant.failures or { });
      }
    ) guests.variants;
    script =
      name: variant:
      let
        g = variant.generations;
        registration = registrations.${name};
        storage =
          if variant.layout == "root" then
            "/root-storage"
          else if variant.layout == "declared" then
            "/guest-backing"
          else
            "/persistent";
        initial = if variant.fresh then g.newInitial else g.oldInitial;
        failurePaths = lib.mapAttrs (_: path: toString path) (variant.failures or { });
        setgidParent = variant.fresh && variant.layout == "ancestor-lib";
      in
      ''
        require 'json'
        require 'digest'
        require 'shellwords'

        machine.start unless machine.running?
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
        ct = get_container_id
        exec_guest = lambda do |command|
          machine.succeeds("osctl ct exec #{ct} bash -c #{Shellwords.escape(command)}")[1].strip
        end
        wait_for_guest_ready = lambda do |phase|
          begin
            machine.wait_until_succeeds("osctl ct exec #{ct} systemctl is-system-running --wait", timeout: 180)
          rescue StandardError => readiness_error
            # Keep the failed guest's evidence without accepting degraded or
            # allowing a diagnostic error to replace the readiness failure.
            [
              'systemctl --failed --plain --no-pager',
              'journalctl -b --no-pager -n 160 -o short-iso-precise',
              <<~'GUEST',
                systemctl --failed --plain --no-legend --no-pager | head -n 8 |
                  while read -r unit rest; do
                    printf '\n--- failed unit %s ---\n' "$unit"
                    systemctl status "$unit" --no-pager --full --lines=40
                    systemctl show "$unit" -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus
                    journalctl -b -u "$unit" --no-pager -n 40 -o short-iso-precise
                  done
              GUEST
            ].each do |diagnostic|
              begin
                command = "timeout -k 2 20 osctl ct exec #{ct} bash -c #{Shellwords.escape(diagnostic)}"
                status, output = machine.execute("{ #{command}; } 2>&1 | head -c 32768", timeout: 25)
                warn "NixOS guest #{ct} #{phase} readiness diagnostic (#{status}): #{diagnostic}\n#{output}"
              rescue StandardError => diagnostic_error
                warn "NixOS guest #{ct} #{phase} readiness diagnostic unavailable: #{diagnostic_error.class}: #{diagnostic_error.message}"
              end
            end
            raise readiness_error
          end
        end
        switch = lambda do |generation|
          exec_guest.call("nix-env -p /nix/var/nix/profiles/system --set #{generation} && #{generation}/bin/switch-to-configuration switch")
          expect(exec_guest.call('readlink /run/current-system')).to eq(generation)
        end
        layout = JSON.parse('${builtins.toJSON { inherit (variant) mounts absentExactMounts logBacking; }}')
        snapshot = lambda do |challenge|
          accounts = challenge ? %w[preservation-test a-preservation-test] : %w[preservation-test]
          ids = accounts.to_h do |account|
            live = exec_guest.call("id -u #{account}; id -g #{account}").split.map(&:to_i)
            saved = JSON.parse(exec_guest.call("jq -n --slurpfile u /var/lib/nixos/uid-map --slurpfile g /var/lib/nixos/gid-map --arg name #{account} '[$u[0][$name], $g[0][$name]]'"))
            backing = JSON.parse(exec_guest.call("jq -n --slurpfile u ${variant.stateBacking}/uid-map --slurpfile g ${variant.stateBacking}/gid-map --arg name #{account} '[$u[0][$name], $g[0][$name]]'"))
            expect(live).to eq(saved), "live IDs differ from allocation maps for #{account}"
            expect(saved).to eq(backing), "visible and backing maps differ for #{account}"
            [account, live]
          end
          exec_guest.call('test ${variant.stateBacking} -ef /var/lib/nixos')
          layout.fetch('mounts').each do |pair|
            target = pair.fetch('target')
            exec_guest.call("mountpoint -q #{target} && test #{pair.fetch('source')} -ef #{target}")
            expect(exec_guest.call("awk '$5 == \"#{target}\" {n++} END {print n+0}' /proc/self/mountinfo")).to eq('1')
          end
          layout.fetch('absentExactMounts').each do |target|
            expect(exec_guest.call("awk '$5 == \"#{target}\" {n++} END {print n+0}' /proc/self/mountinfo")).to eq('0')
          end
          exec_guest.call("test #{layout.fetch('logBacking')} -ef /var/log") if layout.fetch('logBacking')
          exec_guest.call('test ${storage}/var/lib/preservation-test/payload -ef /var/lib/preservation-test/payload && test ${storage}/etc/machine-id -ef /etc/machine-id')
          {
            'ids' => ids,
            'mount_options' => layout.fetch('mounts').to_h { |pair| target = pair.fetch('target'); [target, exec_guest.call("findmnt -n -o OPTIONS --mountpoint #{target}")] },
            'machine_id' => exec_guest.call('cat /etc/machine-id'),
            'payload' => exec_guest.call('sha256sum /var/lib/preservation-test/payload').split.first,
            'owner' => exec_guest.call("stat -c '%u:%g' /var/lib/preservation-test/payload"),
            'metadata' => exec_guest.call("stat -c '%u:%g:%a:%i' ${variant.sourceDirectory}"),
            ${lib.optionalString setgidParent ''
              'source_parent_metadata' => exec_guest.call("stat -c '%u:%g:%a:%i' ${builtins.dirOf variant.sourceDirectory}"),
            ''}
            'payload_directory' => exec_guest.call("stat -c '%u:%g:%a:%i' /var/lib/preservation-test")
          }
        end

        describe '${variantName name} ${
          if variant.fresh then "fresh persistence initialization" else "old-to-new persistence adoption"
        }' do
          it 'retains dynamic accounts, maps, data and bind identity' do
            puts 'Old compatibility source: ${guests.oldMetadata.rev} (${guests.oldMetadata.narHash})'
            puts 'Candidate compatibility source: ${../../..}'
            puts 'Guest release ${variant.release}; stateVersion 22.11'
            ${
              if variant.fresh then
                ''
                  puts 'Fresh candidate generations ${g.newInitial} -> ${g.newChallenge}'
                ''
              else
                ''
                  puts 'Prepared old-to-new generations ${g.oldInitial} -> ${g.oldChallenge} -> ${g.newChallenge}'
                ''
            }
            machine.all_succeed(
              "osctl ct new --skip-image --distribution nixos --version ${variant.release} --arch x86_64 #{ct}",
              "osctl ct unset start-menu #{ct}",
              "osctl ct dataset new #{ct} nix",
            )
            rootfs = machine.osctl_json("ct show #{ct}").fetch('rootfs')
            nix_root = machine.osctl_json("ct mounts ls #{ct}").find { |mount| mount.fetch('mountpoint') == '/nix' }.fetch('fs')
            # Use the declarative NixOS container's stopped-store copy contract.
            # Native mapping exposes these root-owned copies as guest root.
            machine.succeeds(<<~SHELL)
              set -e
              # The fresh dataset root is 0750; /nix needs non-root traversal.
              chmod 0755 "#{nix_root}"
              mkdir -p "#{nix_root}/store"
              while IFS= read -r store_path; do
                cp -a "$store_path" "#{nix_root}/store/"
              done < ${registration}/store-paths
              cp ${registration}/registration "#{nix_root}/nix-path-registration"
            SHELL
            machine.all_succeed(
              "mkdir -p #{nix_root}/var/nix/profiles #{rootfs}/sbin #{rootfs}/etc #{rootfs}/var",
              "ln -s ${initial} #{nix_root}/var/nix/profiles/system",
              "ln -s ${initial}/init #{rootfs}/sbin/init",
            )
            ${lib.optionalString (variant.layout != "root") ''
              machine.all_succeed(
                # The CLI mounts subdatasets; '/' denotes root only in image
                # configuration. Bind this container's queried private root.
                "osctl ct mounts new --fs #{rootfs} --type bind --opts bind,create=dir,rw --mountpoint /persistent #{ct}",
                "osctl ct set impermanence #{ct}",
              )
            ''}
            ${lib.optionalString (variant.layout == "declared") ''
              # Provision the old configuration's declared backing sources;
              # this is setup, before any accounts or data exist.
              machine.all_succeed(
                "mkdir -p #{rootfs}/backing/var/lib/nixos #{rootfs}/backing/var/lib/preservation-test #{rootfs}/backing/var/log #{rootfs}/backing/etc",
                "touch #{rootfs}/backing/etc/machine-id",
              )
            ''}
            ${lib.optionalString (variant.layout == "dependent") ''
              machine.succeeds("mkdir -p #{rootfs}/var/lib/nixos/usr")
            ''}
            ${lib.optionalString setgidParent ''
              # Only provision the absent source's parent, before allocation.
              # The candidate must clear inherited group/SGID on its new child.
              source_parent = File.dirname("#{rootfs}${variant.sourcePathInRoot}")
              machine.succeeds("install -d -m 02775 -o 0 -g 1234 #{source_parent}")
              expected_source_parent_metadata = machine.succeeds("stat -c '%u:%g:%a:%i' #{source_parent}")[1].strip
              expect(expected_source_parent_metadata.split(':').first(3).join(':')).to eq('0:1234:2775')
            ''}
            ${lib.optionalString (variant.fresh) ''
              machine.fails("test -e #{rootfs}${variant.sourcePathInRoot}")
            ''}
            expected_source_metadata = nil
            ${lib.optionalString (!variant.fresh) ''
              # Provision custom source metadata before any guest accounts/data.
              machine.succeeds("install -d -m ${builtins.elemAt (lib.splitString ":" variant.sourceMetadata) 2} -o ${builtins.elemAt (lib.splitString ":" variant.sourceMetadata) 0} -g ${builtins.elemAt (lib.splitString ":" variant.sourceMetadata) 1} #{rootfs}${variant.sourcePathInRoot}")
              expected_source_metadata = machine.succeeds("stat -c '%u:%g:%a:%i' #{rootfs}${variant.sourcePathInRoot}")[1].strip
            ''}
            machine.succeeds("osctl ct start #{ct}")
            wait_for_guest_ready.call('initial boot')
            expect(exec_guest.call('nixos-version')).to start_with('${guests.expectedRelease variant.release}')
            exec_guest.call('nix-store --load-db < /nix/nix-path-registration')
            ${lib.optionalString (!variant.fresh) ''
              # The old boot has already mounted state. A normal old live
              # switch establishes healthy persisted maps; no ID/map repair.
              switch.call('${g.oldInitial}')
            ''}
            ${lib.optionalString (variant.layout == "declared") ''
              # Initialize only the verified empty old-baseline fixture placeholder.
              exec_guest.call(<<~'GUEST')
                set -e
                mountpoint -q -- /guest-backing
                test /persistent/backing -ef /guest-backing
                mountpoint -q -- /var/lib/preservation-test
                test -d /guest-backing/var/lib/preservation-test
                test -d /var/lib/preservation-test
                test /guest-backing/var/lib/preservation-test -ef /var/lib/preservation-test
                source_entries=$(find -H /guest-backing/var/lib/preservation-test -mindepth 1 -maxdepth 1 -printf x -quit) || exit 1
                target_entries=$(find -H /var/lib/preservation-test -mindepth 1 -maxdepth 1 -printf x -quit) || exit 1
                test -z "$source_entries"
                test -z "$target_entries"
                payload_inode=$(stat -Lc '%d:%i' -- /var/lib/preservation-test)
                install -d -m 0750 -o preservation-test -g preservation-test -- /var/lib/preservation-test
                test "$payload_inode" = "$(stat -Lc '%d:%i' -- /var/lib/preservation-test)"
                test /guest-backing/var/lib/preservation-test -ef /var/lib/preservation-test
              GUEST
            ''}
            exec_guest.call("printf '%s\\n' persistence-upgrade-payload > /var/lib/preservation-test/payload && chown preservation-test:preservation-test /var/lib/preservation-test/payload")
            original = snapshot.call(false)
            expect(original.fetch('payload')).to eq(Digest::SHA256.hexdigest("persistence-upgrade-payload\n"))
            expect(original.fetch('owner')).to eq(original.fetch('ids').fetch('preservation-test').join(':'))
            expect(original.fetch('machine_id')).to match(/\A[0-9a-f]{32}\z/)
            expect(original.fetch('metadata').split(':').first(3).join(':')).to eq('${variant.sourceMetadata}')
            expect(original.fetch('metadata')).to eq(expected_source_metadata) if expected_source_metadata
            ${lib.optionalString setgidParent ''
              expect(original.fetch('source_parent_metadata')).to eq(expected_source_parent_metadata)
            ''}
            expect(original.fetch('payload_directory').split(':').first(3).join(':')).to eq(original.fetch('ids').fetch('preservation-test').join(':') + ':750')

            switch.call('${if variant.fresh then g.newChallenge else g.oldChallenge}')
            healthy = snapshot.call(true)
            expect(healthy.reject { |key, _| key == 'ids' }).to eq(original.reject { |key, _| key == 'ids' })
            expect(healthy.fetch('ids').fetch('preservation-test')).to eq(original.fetch('ids').fetch('preservation-test'))
            expect(healthy.fetch('ids').fetch('a-preservation-test')).not_to eq(healthy.fetch('ids').fetch('preservation-test'))
            ${lib.optionalString (!variant.fresh) ''
              # Keep this old guest running: an old restart is the known defect.
              # Only the raw compatibility source changes in this generation.
              switch.call('${g.newChallenge}')
              expect(snapshot.call(true)).to eq(healthy)
            ''}
            switch.call('${g.newChallenge}')
            expect(snapshot.call(true)).to eq(healthy)
            machine.succeeds("osctl ct restart #{ct}")
            wait_for_guest_ready.call('restart')
            expect(exec_guest.call('readlink /run/current-system')).to eq('${g.newChallenge}')
            expect(snapshot.call(true)).to eq(healthy)
            ${lib.optionalString (variant.layout == "declared") ''
              exec_guest.call('test /persistent/backing -ef /guest-backing')
              expect(exec_guest.call("findmnt -n -o OPTIONS --mountpoint /guest-backing")).to include('rw')
            ''}
            ${lib.optionalString (variant.layout == "dependent") ''
              exec_guest.call('test /persistent/var/lib/nixos/usr -ef /usr')
              expect(exec_guest.call("awk '$5 == \"/usr\" {n++} END {print n+0}' /proc/self/mountinfo")).to eq('1')
            ''}
            ${lib.optionalString (variant.layout == "failures") ''
              saved_files = exec_guest.call('sha256sum /etc/passwd /etc/group /var/lib/nixos/uid-map /var/lib/nixos/gid-map /var/lib/preservation-test/payload')
              # Positive execution control uses the complete generated activation
              # and real allocator; trace markers do not replace it.
              positive = "/root/persistence-#{ct}-positive.log"
              machine.succeeds("osctl ct exec #{ct} bash -c #{Shellwords.escape('echo TRACE_BEGIN; bash -x ${g.newChallenge}/activate; rc=$?; echo TRACE_END:$rc; exit $rc')} > #{positive} 2>&1")
              trace = machine.succeeds("cat #{positive}")[1]
              expect(trace).to include('TRACE_BEGIN', 'TRACE_END:0')
              expect(trace).to match(/^\+.*perl.*-update-users-groups\.pl/)
              failures = JSON.parse('${builtins.toJSON failurePaths}')
              # Visibility/order control: this log tmpfs is private to this
              # activation; durable allocation state stays on its healthy bind.
              nonbind = failures.delete('nonbind-positive')
              nonbind_log = "/root/persistence-#{ct}-nonbind-positive.log"
              command = "set -e; umount /var/log; echo TRACE_BEGIN; bash -x #{nonbind}/activate; rc=$?; echo TRACE_END:$rc; exit $rc"
              machine.succeeds("osctl ct exec #{ct} unshare --mount --propagation private bash -c #{Shellwords.escape(command)} > #{nonbind_log} 2>&1")
              trace = machine.succeeds("cat #{nonbind_log}")[1]
              expect(trace).to include('TRACE_BEGIN', 'TRACE_END:0')
              mount_position = trace.index(/^\++ mount -t tmpfs .* \/var\/log$/)
              allocator_position = trace.index(/^\+.*perl.*-update-users-groups\.pl/)
              expect(mount_position).not_to be_nil
              expect(allocator_position).not_to be_nil
              expect(mount_position).to be < allocator_position
              expect(snapshot.call(true)).to eq(healthy)
              failures.each do |failure, generation|
                # Isolate real mount faults without changing the live guest's
                # configured storage, maps or mounted destinations.
                preparation = case failure
                when 'missing'
                  'test ! -e /persistent/required'
                when 'bind'
                  'umount /var/lib/nixos'
                when 'conflict'
                  'umount /var/lib/nixos; mkdir -p /run/wrong-state; mount --bind /run/wrong-state /var/lib/nixos'
                when 'wrong-backing'
                  'mkdir -p /persistent/required /required-storage /run/wrong-backing; mount --bind /run/wrong-backing /required-storage; test ! -e /required-storage/absent-state'
                when 'ancestor-bind'
                  'umount /var/lib/nixos; umount /var/lib/preservation-test; ! mountpoint -q /var/lib'
                when 'ancestor-conflict'
                  'umount /var/lib/nixos; umount /var/lib/preservation-test; mkdir -p /run/wrong-ancestor; mount --bind /run/wrong-ancestor /var/lib'
                when 'nonbind'
                  'umount /var/log; test ! -e /dev/no-such-persistence-device'
                when 'nonbind-remount'
                  'umount /var/log; mount -t tmpfs tmpfs /var/log'
                when 'required-remount'
                  'mkdir -p /required-storage; mount -t tmpfs tmpfs /required-storage; test ! -e /required-storage/absent-state'
                end
                # Each preparation must succeed; no artificial allocator marker.
                after_failure = failure == 'required-remount' ? 'mountpoint -q /required-storage && test ! -e /required-storage/absent-state && echo REQUIRED_STILL_PRESENT' : 'true'
                command = "set -e; #{preparation}; set +e; echo TRACE_BEGIN; bash -x #{generation}/activate; rc=$?; echo TRACE_END:$rc; #{after_failure}; exit $rc"
                log = "/root/persistence-#{ct}-#{failure}.log"
                machine.fails("osctl ct exec #{ct} unshare --mount --propagation private bash -c #{Shellwords.escape(command)} > #{log} 2>&1")
                trace = machine.succeeds("cat #{log}")[1]
                expect(trace).to include('TRACE_BEGIN', 'TRACE_END:1', 'refusing user allocation')
                expect(trace).to match(/^\++ source .*mounts/)
                expect(trace).to match(/^\++ exit 1$/)
                expect(trace).not_to match(/^\+.*perl.*-update-users-groups\.pl/)
                operation = case failure
                when 'nonbind'
                  ['ext4', '/dev/no-such-persistence-device', '/var/log', %w[mode=0755]]
                when 'nonbind-remount'
                  ['tmpfs', 'tmpfs', '/var/log', %w[remount size=invalid]]
                when 'required-remount'
                  ['tmpfs', 'tmpfs', '/required-storage', %w[remount size=invalid]]
                when 'ancestor-bind'
                  ['none', '/persistent/var/lib', '/var/lib', %w[bind remount]]
                end
                if operation
                  fs_type, mount_source, mount_target, required_options = operation
                  lines = trace.lines
                  mount_position = lines.index do |line|
                    next false unless line.match?(/\A\++ mount -t /)
                    argv = Shellwords.split(line.sub(/\A\++ /, ""))
                    argv.length == 7 && argv.first(4) == ['mount', '-t', fs_type, '-o'] &&
                      argv.last(2) == [mount_source, mount_target] &&
                      (required_options - argv[4].split(',')).empty?
                  end
                  refusal_position = lines.index { |line| line.match?(/\A\++ printf .*refusing user allocation/) }
                  expect(mount_position).not_to be_nil
                  expect(refusal_position).not_to be_nil
                  expect(mount_position).to be < refusal_position
                end
                expect(trace).to include('REQUIRED_STILL_PRESENT') if failure == 'required-remount'
                expect(exec_guest.call('sha256sum /etc/passwd /etc/group /var/lib/nixos/uid-map /var/lib/nixos/gid-map /var/lib/preservation-test/payload')).to eq(saved_files)
                expect(snapshot.call(true)).to eq(healthy)
                exec_guest.call('test ! -e /persistent/required/absent-state && test ! -e /run/wrong-backing/absent-state') if failure == 'wrong-backing'
              end
            ''}
            machine.succeeds("osctl ct del -f --prune #{ct}")
          end
        end
      '';
  in
  {
    name = "dist-config-nixos-persistence-upgrade";
    description = "Pinned old-to-new NixOS persistence input adoption with real legacy allocation";
    tags = [ "ci" ];
    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        system.extraDependencies = allClosures ++ builtins.attrValues registrations;
      };
    };
    testScripts = lib.mapAttrs' (name: variant: {
      name = variantName name;
      value.script = script name variant;
    }) guests.variants;
  }
)
