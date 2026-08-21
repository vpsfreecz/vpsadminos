import ../../make-test.nix (
  { pkgs }:
  let
    rootDisk = "system-install-root.img";
    poolDisk = "system-install-pool.img";
    configuration =
      let
        cfg = builtins.getEnv "VPSADMINOS_CONFIG";
      in
      if cfg == "" then null else import cfg;

    isoSystem = import ../../../os (
      {
        importedPkgs = pkgs;
        system = pkgs.system;
        modules = [
          ../../../os/configs/iso.nix
          {
            boot.initrd.kernelModules = [
              "ahci"
              "sd_mod"
              "ext4"
              "virtio"
              "virtio_pci"
              "virtio_console"
            ];
            boot.initrd.supportedFilesystems.ext4 = true;
            boot.kernelParams = [ "console=ttyS0" ];
            boot.kernelModules = [ "ext4" ];
            boot.loader.timeout = pkgs.lib.mkForce 1;
            boot.supportedFilesystems.ext4 = true;
            os.channel-registration.enable = true;
            osctl.test-shell = {
              enable = true;
              shells = 1;
            };
          }
        ];
      }
      // pkgs.lib.optionalAttrs (configuration != null) { inherit configuration; }
      // (pkgs.vpsadminosTestFrameworkInputs or { })
    );

    isoPath = "${isoSystem.config.system.build.isoImage}/iso/${isoSystem.config.isoImage.isoName}";
    installUnstable = isoSystem.config.system.vpsadminos.enableUnstable;
    expectedKernelVersion = isoSystem.config.boot.kernelVersion;

    disks = [
      {
        type = "file";
        device = rootDisk;
        size = "12G";
      }
      {
        type = "file";
        device = poolDisk;
        size = "4G";
      }
    ];
  in
  {
    name = "system-install";

    description = ''
      Test vpsAdminOS installation from ISO and management using vpsAdminOS tools
    '';

    tags = [ "ci" ];

    machines = {
      installer = {
        bootMode = "firmware";
        bootOrder = "d";
        cores = 4;
        cpus = 4;
        memory = 4096;
        inherit disks;
        iso = isoPath;
      };

      installed = {
        bootMode = "firmware";
        bootOrder = "c";
        cores = 4;
        cpus = 4;
        memory = 4096;
        inherit disks;
      };
    };

    testScript = ''
      def append_nix_config(machine, path, text)
        machine.succeeds(<<~SH)
          set -e
          tmp="$(mktemp)"
          head -n -1 #{path} > "$tmp"
          cat >> "$tmp" <<'EOF'
          #{text}
          EOF
          echo "}" >> "$tmp"
          cat "$tmp" > #{path}
          rm "$tmp"
        SH
      end

      describe 'vpsAdminOS installation', order: :defined do
        root_device = nil
        root_partition = nil
        pool_device = nil
        pool_guid = nil

        it 'boots the ISO installer with vpsAdminOS tools' do
          installer.start
          installer.wait_for_boot
          installer.wait_until_succeeds('test -e /var/lib/nixos/did-channel-init', timeout: 300)

          installer.all_succeed(
            'command -v vpsadminos-install',
            'command -v vpsadminos-generate-config',
            'command -v vpsadminos-enter',
            'command -v vpsadminos-version',
            'command -v vpsadminos-rebuild',
            'vpsadminos-version',
            'test "$(uname -r)" = "${expectedKernelVersion}"'
          )
        end

        it 'prepares target disks and generates config' do
          _, root_device = installer.succeeds(%q(lsblk -bndo NAME,SIZE,TYPE | awk '$3 == "disk" && $1 ~ /^sd/ && $2 >= 8000000000 { print "/dev/" $1; exit }'))
          _, pool_device = installer.succeeds(%q(lsblk -bndo NAME,SIZE,TYPE | awk '$3 == "disk" && $1 ~ /^sd/ && $2 >= 3000000000 && $2 < 8000000000 { print "/dev/" $1; exit }'))
          root_device = root_device.strip
          pool_device = pool_device.strip
          root_partition = "#{root_device}1"

          expect(root_device).to match(%r{\A/dev/})
          expect(pool_device).to match(%r{\A/dev/})

          installer.succeeds("parted -s #{root_device} -- mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on")
          installer.succeeds('udevadm settle || true')
          installer.wait_until_succeeds("test -b #{root_partition}", timeout: 60)
          installer.succeeds("mkfs.ext4 -F -L VPSADMINOS_ROOT #{root_partition}", timeout: 120)
          installer.succeeds("mkdir -p /mnt && mount #{root_partition} /mnt")
          installer.succeeds("zpool create -f -o feature@block_cloning=disabled tank #{pool_device}", timeout: 120)
          _, pool_guid = installer.succeeds('zpool get -H -o value guid tank')
          pool_guid = pool_guid.strip
          expect(pool_guid).to match(/\A[0-9]+\z/)
          installer.succeeds('zpool export tank', timeout: 120)

          installer.succeeds(<<~SH)
            vpsadminos_source="$(readlink -f /nix/var/nix/profiles/per-user/root/channels/vpsadminos)"
            nixpkgs_source="$(readlink -f /nix/var/nix/profiles/per-user/root/channels/nixos)"
            VPSADMINOS_FLAKE_URL="path:$vpsadminos_source" \\
            VPSADMINOS_NIXPKGS_FLAKE_URL="path:$nixpkgs_source" \\
              vpsadminos-generate-config --root /mnt --hostname vpsadminos-installed
          SH
          installer.all_succeed(
            'test -f /mnt/etc/vpsadminos/configuration.nix',
            'test -f /mnt/etc/vpsadminos/hardware-configuration.nix',
            'test -f /mnt/etc/vpsadminos/flake.nix',
            'grep -q "path:/nix/store/" /mnt/etc/vpsadminos/flake.nix'
          )

          append_nix_config(
            installer,
            '/mnt/etc/vpsadminos/configuration.nix',
            <<~NIX
              boot.loader.grub.device = "#{root_device}";
              boot.loader.timeout = 1;
              boot.kernelParams = [ "console=ttyS0" ];
              boot.initrd.kernelModules = [
                "ahci"
                "sd_mod"
                "ext4"
                "virtio"
                "virtio_pci"
                "virtio_console"
              ];
              boot.initrd.supportedFilesystems.ext4 = true;
              boot.kernelModules = [ "ext4" ];
              boot.supportedFilesystems.ext4 = true;
              boot.zfs.devNodes = [ "/dev" ];
              boot.zfs.pools.tank = {
                guid = "#{pool_guid}";
                doCreate = false;
                importAttempts = 3;
                install = true;
                properties."feature@block_cloning" = "disabled";
              };
              networking.hostId = "f3276671";
              networking.hostName = "vpsadminos-installed";
              networking.nameservers = [ "10.0.2.3" ];
              networking.useDHCP = true;
              system.vpsadminos.enableUnstable = ${pkgs.lib.boolToString installUnstable};
              osctl.test-shell = {
                enable = true;
                shells = 1;
              };
            NIX
          )
        end

        it 'installs vpsAdminOS to disk' do
          installer.succeeds('vpsadminos-install --root /mnt --flake /mnt/etc/vpsadminos#vpsadminos-installed --no-root-password', timeout: 1800)
          installer.succeeds('vpsadminos-enter --root /mnt -- true')
          installer.succeeds('test -d /mnt/boot/grub')
        end

        it 'boots the installed system from disk' do
          installer.succeeds('poweroff -f')
          installer.wait_for_shutdown

          installed.start
          installed.wait_for_boot

          installed.all_succeed(
            'test -e /etc/VPSADMINOS',
            'test -L /run/current-system',
            'test -d /boot/grub',
            'test "$(findmnt -n -o FSTYPE /)" = "ext4"',
            'command -v vpsadminos-rebuild',
            'test "$(uname -r)" = "${expectedKernelVersion}"'
          )
        end

        it 'initializes osctl pool storage' do
          installed.wait_for_zpool('tank', timeout: 20 * 60)
          installed.wait_for_service('pool-tank')
          installed.all_succeed(
            'test "$(zfs get -H -o value org.vpsadminos.osctl:active tank)" = "yes"',
            'test -s /tank/.migrations',
            'zfs list -H -o name tank/ct tank/conf tank/hook tank/log tank/repository tank/migration tank/trash',
            'test -d /tank/conf/pool',
            'test -d /tank/conf/user',
            'test -d /tank/conf/group',
            'test -d /tank/conf/ct',
            'test -d /tank/log/ct'
          )
        end

        it 'rebuilds the installed system' do
          append_nix_config(
            installed,
            '/etc/vpsadminos/configuration.nix',
            <<~'NIX'
              environment.etc."vpsadminos-install-test-marker".text = "ok\n";
            NIX
          )

          installed.succeeds('vpsadminos-rebuild switch', timeout: 1800)
          installed.succeeds('test "$(cat /etc/vpsadminos-install-test-marker)" = ok')
        end
      end
    '';
  }
)
