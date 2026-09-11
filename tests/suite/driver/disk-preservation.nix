import ../../make-test.nix (
  { pkgs }:
  let
    # vpsAdminOS provides by-id links for these AHCI disks, but no by-path links.
    tankDevice = "/dev/disk/by-id/ata-QEMU_HARDDISK_QM00005";
    scratchDevice = "/dev/disk/by-id/ata-QEMU_HARDDISK_QM00007";
    tank = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = { lib, ... }: {
        boot.qemu.memory = 2048;
        boot.zfs.pools.tank.layout = lib.mkForce [
          { devices = [ tankDevice ]; }
        ];
      };
    };
  in
  {
    name = "driver-disk-preservation";
    description = "Verify disk preservation and explicit resets on both VM drivers";
    tags = [ "ci" ];

    machines = {
      nixos = (import ../../machines/nixos/basic.nix pkgs) // {
        disks = [
          {
            device = "nixos-data.img";
            type = "file";
            size = "64M";
          }
          {
            device = "nixos-scratch.img";
            type = "file";
            size = "64M";
            preserve = false;
          }
        ];
      };
      vpsadminos = tank // {
        disks = tank.disks ++ [
          {
            device = "vpsadminos-scratch.img";
            type = "file";
            size = "64M";
            preserve = false;
          }
        ];
      };
    };

    testScript = ''
      describe 'disk preservation', order: :defined do
        it 'retains NixOS root and data while recreating its scratch disk' do
          nixos.start
          nixos.wait_for_boot
          nixos.all_succeed(
            "test -b /dev/disk/by-path/pci-0000:00:03.0-ata-2",
            "test -b /dev/disk/by-path/pci-0000:00:03.0-ata-3",
            "echo root-marker > /root/preservation-marker",
            "printf data-marker | dd of=/dev/disk/by-path/pci-0000:00:03.0-ata-2 conv=fsync",
            "printf scratch-marker | dd of=/dev/disk/by-path/pci-0000:00:03.0-ata-3 conv=fsync"
          )
          nixos.stop
          nixos.start
          nixos.wait_for_boot
          expect(nixos.succeeds("cat /root/preservation-marker")[1].strip).to eq('root-marker')
          expect(nixos.succeeds("head -c 11 /dev/disk/by-path/pci-0000:00:03.0-ata-2")[1]).to eq('data-marker')
          nixos.succeeds("cmp -n 14 /dev/disk/by-path/pci-0000:00:03.0-ata-3 /dev/zero")
          nixos.stop
        end

        it 'retains vpsAdminOS pool and container data while its temporary root is recreated' do
          vpsadminos.start
          vpsadminos.wait_for_boot
          vpsadminos.wait_until_succeeds("test -b ${tankDevice} && test -b ${scratchDevice}", timeout: 60)
          vpsadminos.wait_for_osctl_pool('tank')
          vpsadminos.all_succeed(
            "echo temporary-root > /root/preservation-marker",
            "echo pool-marker > /tank/preservation-marker",
            "printf scratch-marker | dd of=${scratchDevice} conv=fsync",
            "osctl ct new --distribution alpine preservation",
            "osctl ct start preservation",
            "osctl ct exec preservation sh -c 'echo container-marker > /root/preservation-marker'"
          )
          vpsadminos.stop
          vpsadminos.start
          vpsadminos.wait_for_osctl_pool('tank')
          vpsadminos.fails("test -e /root/preservation-marker")
          expect(vpsadminos.succeeds("cat /tank/preservation-marker")[1].strip).to eq('pool-marker')
          vpsadminos.succeeds("cmp -n 14 ${scratchDevice} /dev/zero")
          vpsadminos.succeeds("osctl ct start preservation")
          expect(vpsadminos.succeeds("osctl ct exec preservation cat /root/preservation-marker")[1].strip).to eq('container-marker')
          vpsadminos.stop
        end

        it 'resets all managed disks only when explicitly requested' do
          nixos.destroy_disks
          nixos.start
          nixos.wait_for_boot
          nixos.fails("test -e /root/preservation-marker")
          nixos.succeeds("cmp -n 11 /dev/disk/by-path/pci-0000:00:03.0-ata-2 /dev/zero")
          nixos.stop

          vpsadminos.destroy_disks
          vpsadminos.start
          vpsadminos.wait_for_osctl_pool('tank')
          vpsadminos.fails("test -e /tank/preservation-marker")
          vpsadminos.fails("osctl ct show preservation")
          vpsadminos.stop
        end
      end
    '';
  }
)
