import ../../make-test.nix (
  { pkgs }:
  {
    name = "kernel-livepatch-kernel-identity";
    description = "Livepatch lifecycle and exact boot-kernel identity guard";
    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        { lib, ... }:
        {
          boot.kernelVersion = "6.12.95";
          services.live-patches.enable = true;
          runit.services.live-patches.run = lib.mkForce "sleep inf";
        };
    };

    testScript = ''
      require 'json'

      before(:suite) do
        machine.start
        machine.wait_until_online
        @boot_release = machine.succeeds('uname -r')[1].strip
        @livepatch_config = JSON.parse(machine.succeeds('cat /etc/vpsadminos/livepatch-monitor.json')[1])
        @module_name = @livepatch_config.fetch('module')
        @patch_dir = "/sys/kernel/livepatch/#{@module_name}"
        @kernel_notes = @livepatch_config.fetch('kernelNotes')
        @kernel_image = @livepatch_config.fetch('kernelImage')
        @livepatch_tool = machine.succeeds('readlink -f "$(command -v live-patches)"')[1].strip
        @dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
      end

      def wait_enabled
        machine.wait_until_succeeds(
          "test \"$(cat #{@patch_dir}/enabled)\" = 1 && " \
            "test \"$(cat #{@patch_dir}/transition)\" = 0",
          timeout: 180,
        )
      end

      describe 'source-matched livepatch', order: :defined do
        it 'loads only after the configured build notes match the running kernel' do
          machine.all_succeed(
            "test -s #{@kernel_notes}",
            "${pkgs.diffutils}/bin/cmp #{@kernel_notes} /sys/kernel/notes",
            "test \"$(readlink -f /run/booted-system/kernel)\" = #{@kernel_image}",
            'live-patches load',
          )
          wait_enabled
          expect(machine.succeeds('uname -r')[1].strip).to eq("#{@boot_release}.#{@livepatch_config.fetch('patchVersion')}")
          machine.succeeds('live-patches status')
        end

        it 'refuses mismatched load and unload without disturbing active protection' do
          machine.succeeds('printf wrong-kernel > /run/wrong-kernel-notes')
          %w[load unload status].each do |operation|
            _, output = machine.fails(
              "unshare --mount sh -c 'mount --make-rslave /; " \
                "mount --bind /run/wrong-kernel-notes /sys/kernel/notes; " \
                "live-patches #{operation}'",
            )
            expect(output).to include('does not match the running boot kernel')
            wait_enabled
          end
          # The private mount above must not have changed the host view.
          machine.succeeds("${pkgs.diffutils}/bin/cmp #{@kernel_notes} /sys/kernel/notes")
        end

        it 'refuses a different boot image even when kernel notes are identical' do
          machine.succeeds('mkdir -p /run/wrong-boot; ln -s /run/wrong-kernel-notes /run/wrong-boot/kernel')
          %w[load unload].each do |operation|
            _, output = machine.fails(
              "unshare --mount sh -c 'mount --make-rslave /; " \
                "mount --bind /run/wrong-boot /run/booted-system; " \
                "${pkgs.diffutils}/bin/cmp #{@kernel_notes} /sys/kernel/notes || exit 2; " \
                "#{@livepatch_tool} #{operation}'",
            )
            expect(output).to include('does not match the running boot kernel')
            wait_enabled
          end
          machine.succeeds("test \"$(readlink -f /run/booted-system/kernel)\" = #{@kernel_image}")
        end

        it 'unloads, restores boot identity, and reloads on the matching kernel' do
          machine.succeeds('live-patches unload', timeout: 180)
          machine.wait_until_succeeds("test ! -d #{@patch_dir}", timeout: 180)
          expect(machine.succeeds('uname -r')[1].strip).to eq(@boot_release)
          machine.succeeds('live-patches load')
          wait_enabled
          expect(machine.succeeds('uname -r')[1].strip).to eq("#{@boot_release}.#{@livepatch_config.fetch('patchVersion')}")
          machine.succeeds('live-patches unload', timeout: 180)
          machine.wait_until_succeeds("test ! -d #{@patch_dir}", timeout: 180)
        end

        it 'leaves no kernel fault or unresolved symbol warnings' do
          output = machine.succeeds("dmesg | tail -n +#{@dmesg_start + 1}")[1]
          expect(output).not_to match(/BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|Invalid relocation target|disagrees about version|Unknown symbol/)
        end
      end
    '';
  }
)
