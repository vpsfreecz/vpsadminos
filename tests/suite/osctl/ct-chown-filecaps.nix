import ../../make-test.nix (
  { pkgs }:
  let
    commonScript = ''
      def self.output_of(cmd)
        machine.succeeds(cmd)[1].strip
      end

      def self.ct_output(ctid, script)
        machine.succeeds("osctl ct exec #{ctid} sh -c #{script.inspect}")[1].strip
      end

      def self.ct_execute(ctid, script)
        machine.execute("osctl ct exec #{ctid} sh -c #{script.inspect}")
      end

      def self.ct_failure_output(ctid, script)
        machine.fails("osctl ct exec #{ctid} sh -c #{script.inspect}")[1]
      end

      def self.wait_ct_exec(ctid)
        machine.wait_until_succeeds("osctl ct exec #{ctid} true", timeout: 120)
      end

      def self.install_ct_tools(ctid)
        status, = ct_execute(ctid, 'command -v getcap >/dev/null && command -v setcap >/dev/null')
        ct_output(ctid, 'dnf -y install libcap') if status != 0

        status, = ct_execute(ctid, 'command -v setpriv >/dev/null')
        ct_output(ctid, 'dnf -y install util-linux') if status != 0
      end

      def self.read_cap(ctid, path)
        ct_output(ctid, "getcap #{path} 2>/dev/null || true")
      end

      def self.read_image_caps(ctid)
        ct_output(ctid, "getcap -r /usr 2>/dev/null | LC_ALL=C sort")
      end

      def self.pick_focus_cap(ctid, image_caps)
        %w[/usr/bin/newuidmap /usr/bin/newgidmap /usr/bin/clockdiff /usr/bin/arping].each do |path|
          line = read_cap(ctid, path)
          return [path, line] unless line.empty?
        end

        path = image_caps.lines.first&.split&.first.to_s
        return ["", ""] if path.empty?

        [path, read_cap(ctid, path)]
      end

      def self.owner_of(ctid, path)
        ct_output(ctid, "stat -c %u:%g #{path}")
      end

      def self.reset_root_owned_file(ctid, path)
        ct_output(ctid, "install -m 0644 /dev/null #{path}; chown 0:0 #{path}")
      end

      def self.runtime_use_cmd(uid, gid, target)
        "setpriv --reuid #{uid} --regid #{gid} --clear-groups --reset-env /opt/filecap-test/chown-cap 123:123 #{target}"
      end
    '';

    mkScript = mode: ''
      map_mode = ${builtins.toJSON mode}
      ctid = get_container_id
      src_user = get_container_id
      dst_user = get_container_id
      next_user = get_container_id
      runtime_binary = "/opt/filecap-test/chown-cap"
      runtime_target_before = "/var/tmp/filecap-test/target-before"
      runtime_target_after = "/var/tmp/filecap-test/target-after"
      runtime_target_second = "/var/tmp/filecap-test/target-second"

      ${commonScript}

      configure_examples do |config|
        config.default_order = :defined
      end

      before(:suite) do
        machine.start unless machine.running?
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        machine.all_succeed(
          "osctl user new #{src_user}",
          "osctl user new #{dst_user}",
          "osctl user new #{next_user}",
          "osctl ct new --user #{src_user} --distribution fedora " \
            "--version latest --map-mode #{map_mode} #{ctid}",
          "osctl ct unset start-menu #{ctid}",
          "osctl ct start #{ctid}"
        )

        wait_ct_exec(ctid)
        install_ct_tools(ctid)

        @image_caps_before = read_image_caps(ctid)
        @focus_path, @focus_before = pick_focus_cap(ctid, @image_caps_before)
        @nobody_uid = ct_output(ctid, 'getent passwd nobody | cut -d: -f3')
        @nobody_gid = ct_output(ctid, 'getent passwd nobody | cut -d: -f4')

        ct_output(
          ctid,
          "install -d -m 0755 /opt/filecap-test /var/tmp/filecap-test; " \
            "cp /usr/bin/chown #{runtime_binary}"
        )
        reset_root_owned_file(ctid, runtime_target_before)
      end

      after(:suite) do
        cleanup = [
          "osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true",
          "osctl user del #{src_user} >/dev/null 2>&1 || true",
          "osctl user del #{dst_user} >/dev/null 2>&1 || true",
          "osctl user del #{next_user} >/dev/null 2>&1 || true",
          "osctl repository images prune >/dev/null 2>&1 || true"
        ].join("; ")

        machine.succeeds("sh -c #{cleanup.inspect}")
      end

      describe "ct chown file capabilities in #{map_mode} map mode" do
        it 'uses the requested map mode' do
          expect(output_of("osctl ct show -H -o map_mode #{ctid}")).to eq(map_mode)
        end

        it 'finds image-shipped capabilities in the Fedora image' do
          expect(@image_caps_before).not_to be_empty
        end

        it 'reads a focused image-shipped capability' do
          expect(@focus_path).not_to be_empty
          expect(@focus_before).not_to be_empty
        end

        it 'finds nobody uid and gid in the container' do
          expect(@nobody_uid).not_to be_empty
          expect(@nobody_gid).not_to be_empty
        end

        it 'does not let nobody chown without a file capability' do
          output = ct_failure_output(
            ctid,
            runtime_use_cmd(@nobody_uid, @nobody_gid, runtime_target_before)
          )

          expect(output).to include('Operation not permitted')
          expect(owner_of(ctid, runtime_target_before)).to eq('0:0')
        end

        context 'after creating a runtime file capability' do
          before(:context) do
            reset_root_owned_file(ctid, runtime_target_before)
            ct_output(ctid, "setcap cap_chown=ep #{runtime_binary}")
          end

          it 'reads the runtime-created capability' do
            expect(read_cap(ctid, runtime_binary)).to include('cap_chown=ep')
          end

          it 'lets nobody chown with the runtime-created capability' do
            machine.succeeds(
              "osctl ct exec #{ctid} sh -c " \
                "#{runtime_use_cmd(@nobody_uid, @nobody_gid, runtime_target_before).inspect}"
            )

            expect(owner_of(ctid, runtime_target_before)).to eq('123:123')
          end

          context 'after ct chown to another user namespace' do
            before(:context) do
              machine.all_succeed(
                "osctl ct stop #{ctid}",
                "osctl ct chown #{ctid} #{dst_user}",
                "osctl ct start #{ctid}"
              )

              wait_ct_exec(ctid)
            end

            it 'preserves the image capability list' do
              caps_after = read_image_caps(ctid)

              expect(caps_after).not_to be_empty
              expect(caps_after).to eq(@image_caps_before)
            end

            it 'preserves the focused image capability' do
              expect(@focus_path).not_to be_empty
              expect(@focus_before).not_to be_empty
              expect(read_cap(ctid, @focus_path)).to eq(@focus_before)
            end

            context 'runtime-created capability' do
              it 'keeps the runtime-created capability readable' do
                expect(read_cap(ctid, runtime_binary)).to include('cap_chown=ep')
              end

              it 'keeps the runtime-created capability working' do
                reset_root_owned_file(ctid, runtime_target_after)

                machine.succeeds(
                  "osctl ct exec #{ctid} sh -c " \
                    "#{runtime_use_cmd(@nobody_uid, @nobody_gid, runtime_target_after).inspect}"
                )

                expect(owner_of(ctid, runtime_target_after)).to eq('123:123')
              end
            end

            it 'passes osctl healthcheck' do
              machine.succeeds("osctl healthcheck -a")
            end

            context 'after a second ct chown' do
              before(:context) do
                machine.all_succeed(
                  "osctl ct stop #{ctid}",
                  "osctl ct chown #{ctid} #{next_user}",
                  "osctl ct start #{ctid}"
                )

                wait_ct_exec(ctid)
              end

              it 'keeps the runtime-created capability readable' do
                expect(read_cap(ctid, runtime_binary)).to include('cap_chown=ep')
              end

              it 'keeps the runtime-created capability working' do
                reset_root_owned_file(ctid, runtime_target_second)

                machine.succeeds(
                  "osctl ct exec #{ctid} sh -c " \
                    "#{runtime_use_cmd(@nobody_uid, @nobody_gid, runtime_target_second).inspect}"
                )

                expect(owner_of(ctid, runtime_target_second)).to eq('123:123')
              end

              it 'passes osctl healthcheck' do
                machine.succeeds("osctl healthcheck -a")
              end
            end
          end
        end
      end
    '';
  in
  {
    name = "osctl-ct-chown-filecaps";

    description = ''
      Test how file capabilities behave after osctl ct chown in native and zfs map modes
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = {
      native = {
        description = ''
          Runtime-created file caps survive ct chown in native map mode;
          image-shipped Fedora file caps remain preserved.
        '';
        script = mkScript "native";
      };

      zfs = {
        description = ''
          Runtime-created file caps survive repeated ct chown in zfs map mode;
          image-shipped Fedora file caps remain preserved.
        '';
        script = mkScript "zfs";
      };
    };
  }
)
