import ../../../make-test.nix (
  { pkgs }:
  let
    scriptPathPackage = pkgs.writeShellScriptBin "runit-script-env-probe" ''
      set -e
      test "$RUNIT_SCRIPT_ENV" = present
      ${pkgs.coreutils}/bin/mkdir -p /run/runit-script-env
      ${pkgs.coreutils}/bin/touch "/run/runit-script-env/$1"
    '';
    entryMachine =
      version:
      let
        hierarchy =
          if version == 1 then "/sys/fs/cgroup/systemd/runit" else "/sys/fs/cgroup/system/service";
        membership =
          if version == 1 then
            "^[0-9]+:name=systemd:/runit/runit-entry-kernel$"
          else
            "^0::/system/service/runit-entry-kernel$";
        fsType = if version == 1 then "cgroupfs" else "cgroup2fs";
        child = pkgs.writeShellScript "runit-entry-child" ''
          set -e
          test "$(${pkgs.procps}/bin/ps -o sid= -p "$$" | ${pkgs.coreutils}/bin/tr -d ' ')" = "$$"
          ${pkgs.gnugrep}/bin/grep -E '${membership}' /proc/$$/cgroup
          ${pkgs.gnugrep}/bin/grep -Fx "$$" ${hierarchy}/runit-entry-kernel/cgroup.procs
          printf 'child\n' > /run/runit-entry-child
        '';
      in
      import ../../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config = {
          boot.enableUnifiedCgroupHierarchy = version == 2;
          system.extraDependencies = [ namespaceProbe ];
          runit.services.runit-entry-kernel = {
            oneShot = true;
            run = ''
              set -e
              test "$(cat /run/osctl/cgroup.version)" = ${toString version}
              test "$(readlink -f /run/runit/cgroup.service)" = ${hierarchy}
              test "$(stat -f -c %T ${hierarchy})" = ${fsType}
              ${pkgs.gnugrep}/bin/grep -E '${membership}' /proc/$$/cgroup
              ${pkgs.gnugrep}/bin/grep -Fx "$$" ${hierarchy}/runit-entry-kernel/cgroup.procs
              ${pkgs.util-linux}/bin/setsid --wait ${child} &
              child_pid=$!
              wait "$child_pid"
              printf 'body\n' > /run/runit-entry-body
            '';
          };
          runit.services.runit-entry-refuse-create = {
            runlevels = [ ];
            oneShot = true;
            run = "printf 'body\\n' > /run/runit-entry-refuse-create-body";
          };
          runit.services.runit-entry-refuse-attach = {
            runlevels = [ ];
            oneShot = true;
            run = "printf 'body\\n' > /run/runit-entry-refuse-attach-body";
          };
        };
      };
    namespaceProbe = pkgs.writeShellScript "runit-entry-refusal" ''
      set -eu
      hierarchy="$1"
      service="$2"
      failure="$3"
      case "$failure" in
        creation)
          test ! -e "$hierarchy/$service"
          label='runit: cgroup creation failed'
          ;;
        attachment)
          mkdir "$hierarchy/$service"
          members=$(cat "$hierarchy/$service/cgroup.procs")
          test -z "$members"
          label='runit: cgroup attachment failed'
          ;;
        *) exit 2 ;;
      esac
      test ! -e "/run/$service-body"
      test ! -e "/run/service/$service/done"
      result="/run/runit-entry-refusal/$service"
      test ! -e "$result"
      mkdir -p "$result"
      export RUNIT_ENTRY_HIERARCHY="$hierarchy" RUNIT_ENTRY_SERVICE="$service"
      export RUNIT_ENTRY_RESULT="$result" RUNIT_ENTRY_LABEL="$label"
      ${pkgs.util-linux}/bin/unshare --mount ${pkgs.bash}/bin/bash -c '
        set -eu
        mount --make-rprivate /
        mount --bind "$RUNIT_ENTRY_HIERARCHY" "$RUNIT_ENTRY_HIERARCHY"
        mount -o remount,bind,ro "$RUNIT_ENTRY_HIERARCHY"
        options=$(findmnt -n -o VFS-OPTIONS --mountpoint "$RUNIT_ENTRY_HIERARCHY")
        case ",$options," in *,ro,*) ;; *) exit 2 ;; esac
        cd "/etc/runit/services/$RUNIT_ENTRY_SERVICE"
        set +e
        ./run > "$RUNIT_ENTRY_RESULT/stdout" 2> "$RUNIT_ENTRY_RESULT/stderr"
        status=$?
        set -e
        printf "%s\n" "$status" > "$RUNIT_ENTRY_RESULT/status"
        test "$status" -eq 1
        test "$(grep -Fxc "$RUNIT_ENTRY_LABEL" "$RUNIT_ENTRY_RESULT/stderr")" -eq 1
        test ! -e "/run/$RUNIT_ENTRY_SERVICE-body"
        test ! -e "/run/service/$RUNIT_ENTRY_SERVICE/done"
      '
      test "$(cat "$result/status")" = 1
      # Namespace setup must finish normally; only the installed run may refuse.
      printf 'entry-refusal-verified\n'
    '';
  in
  {
    name = "system-boot-runit";

    description = ''
      Test runit service generation
    '';

    tags = [ "ci" ];

    machines.machine = import ../../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config = {
        runit.services.runit-script-env = {
          path = [ scriptPathPackage ];
          environment = {
            RUNIT_SCRIPT_ENV = "present";
          };
          run = ''
            runit-script-env-probe run
            exec ${pkgs.coreutils}/bin/sleep 3600
          '';
          finish = ''
            runit-script-env-probe finish
          '';
          check = ''
            runit-script-env-probe check
          '';
          control.hangup = ''
            runit-script-env-probe control
          '';
        };
      };
    };

    machines.entry_v1 = entryMachine 1;
    machines.entry_v2 = entryMachine 2;

    testScript = ''
      def expect_probe(name)
        status, output = machine.execute("test -f /run/runit-script-env/#{name}")
        expect(status).to eq(0), output
      end

      before(:suite) do
        machine.start
        machine.wait_for_service("runit-script-env")
        entry_v1.start
        entry_v2.start
      end

      describe 'runit service script environment', order: :defined do
        it 'passes path and environment to run scripts' do
          expect_probe("run")
        end

        it 'passes path and environment to check scripts' do
          expect_probe("check")
        end

        it 'passes path and environment to control scripts' do
          status, output = machine.execute("sv hup runit-script-env")
          expect(status).to eq(0), output

          machine.wait_until_succeeds("test -f /run/runit-script-env/control")
          expect_probe("control")
        end

        it 'passes path and environment to finish scripts' do
          status, output = machine.execute("sv down runit-script-env")
          expect(status).to eq(0), output

          machine.wait_until_succeeds("test -f /run/runit-script-env/finish")
          expect_probe("finish")
        end
      end

      describe 'installed runit cgroup entry', order: :defined do
        { 1 => entry_v1, 2 => entry_v2 }.each do |version, node|
          hierarchy = version == 1 ? '/sys/fs/cgroup/systemd/runit' : '/sys/fs/cgroup/system/service'

          it "enters the actual v#{version} hierarchy and waits an inheriting separate-session child" do
            node.wait_until_succeeds('test -f /run/service/runit-entry-kernel/done')
            status, output = node.execute("test \"$(cat /run/osctl/cgroup.version)\" = #{version} && test \"$(readlink -f /run/runit/cgroup.service)\" = #{hierarchy} && test \"$(cat /run/runit-entry-body)\" = body && test \"$(cat /run/runit-entry-child)\" = child")
            expect(status).to eq(0), output
            status, output = node.execute('sv down runit-entry-kernel')
            expect(status).to eq(0), output
          end

          { 'creation' => 'runit-entry-refuse-create', 'attachment' => 'runit-entry-refuse-attach' }.each do |failure, service|
            it "refuses v#{version} #{failure} before the installed run body and one-shot effects" do
              node.succeeds("test ! -e /etc/runit/runsvdir/default/#{service}")
              status, output = node.execute("${namespaceProbe} #{hierarchy} #{service} #{failure}")
              expect(status).to eq(0), output
              expect(output.strip).to eq('entry-refusal-verified')
              status, output = node.execute("test \"$(cat /run/runit-entry-refusal/#{service}/status)\" = 1 && test ! -e /run/#{service}-body && test ! -e /run/service/#{service}/done")
              expect(status).to eq(0), output
            end
          end
        end
      end
    '';
  }
)
