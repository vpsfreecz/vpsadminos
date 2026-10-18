import ../../make-test.nix (
  { pkgs }:
  let
    guestConfig =
      zfsBuiltin:
      { config, pkgs, ... }:
      {
        boot.zfsBuiltin = zfsBuiltin;
        environment.systemPackages = with pkgs; [
          kmod
          coreutils
          findutils
          gnugrep
        ];
        environment.etc = {
          "zfs-boot-mode-module-package".text =
            let
              package =
                if config.boot.zfsBuiltin then config.boot.kernelPackage else config.boot.kernelPackages.zfs;
            in
            "${package}\n";
          "zfs-boot-mode-kernel-release".text = "${config.boot.kernelPackage.modDirVersion}\n";
        };
      };
  in
  {
    name = "zfs-boot-modes";
    description = "Default-kernel ZFS boot and data operations with builtin and external modules";
    tags = [ "ci" ];

    # Keep normal kernel selection in both configurations. Metadata parity is
    # checked separately; these guests exercise the resulting boot artifacts.
    machines = {
      builtin_zfs = import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config = guestConfig true;
      };
      external_zfs = import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config = guestConfig false;
      };
    };

    testScript = ''
      describe 'default-kernel ZFS packaging' do
        { builtin: builtin_zfs, external: external_zfs }.each do |mode, host|
          it "boots and preserves data through ZFS operations with the #{mode} ZFS package" do
            host.start
            host.wait_for_osctl_pool('tank')
            host.succeeds('test -d /sys/module/zfs/parameters')
            # The retained default kernel supplies loadable in-tree ZFS.
            # Check configured resolver provenance; this does not identify the
            # bytes of the already-loaded module.
            host.succeeds("grep -q '^zfs ' /proc/modules")
            _, provenance = host.succeeds(<<~'SH')
              set -eu
              package=$(cat /etc/zfs-boot-mode-module-package)
              release=$(cat /etc/zfs-boot-mode-kernel-release)
              test "$(uname -r)" = "$release"
              test "$(readlink -f -- "$package")" = "$package"
              module_dir="$package/lib/modules/$release"
              test -d "$module_dir"
              printf 'Expected module package: %s\nKernel release: %s\n' "$package" "$release"

              tmp=$(mktemp -d)
              trap 'rm -rf -- "$tmp"' EXIT
              find "$module_dir" -name 'zfs.ko*' -print > "$tmp/candidates"
              test "$(wc -l < "$tmp/candidates")" -eq 1
              IFS= read -r candidate < "$tmp/candidates"
              module=$(readlink -f -- "$candidate")
              case "$module" in
                "$package"/*) ;;
                *) printf 'Module escapes expected package: %s\n' "$module" >&2; exit 1 ;;
              esac
              test -f "$module"
              case "$(basename -- "$candidate")" in
                zfs.ko|zfs.ko.xz) ;;
                *) printf 'Unsupported module format: %s\n' "$candidate" >&2; exit 1 ;;
              esac
              selected=$(modinfo -b /run/booted-system/kernel-modules -k "$release" -n zfs)
              selected=$(readlink -f -- "$selected")
              printf 'Expected module: %s\nmodinfo module: %s\n' "$module" "$selected"
              test "$selected" = "$module"
              printf 'Configured module provider resolution matches selected output\n'
            SH
            puts "#{mode} ZFS provenance:\n#{provenance}"

            host.all_succeed(
              'zfs create tank/boot-mode-source',
              'printf zfs-boot-mode-payload > /tank/boot-mode-source/payload',
              'zfs snapshot tank/boot-mode-source@saved',
              'zfs clone tank/boot-mode-source@saved tank/boot-mode-clone',
              'cmp /tank/boot-mode-source/payload /tank/boot-mode-clone/payload',
              'printf changed > /tank/boot-mode-source/payload',
              'zfs rollback tank/boot-mode-source@saved',
              'zfs send tank/boot-mode-source@saved | zfs receive tank/boot-mode-received',
              'cmp /tank/boot-mode-source/payload /tank/boot-mode-received/payload',
            )
            %w[source clone received].each do |copy|
              expect(host.succeeds("cat /tank/boot-mode-#{copy}/payload")[1]).to eq('zfs-boot-mode-payload')
            end
            host.all_succeed(
              'zfs destroy tank/boot-mode-clone',
              'zfs destroy -r tank/boot-mode-received',
              'zfs destroy -r tank/boot-mode-source',
            )
            puts "#{mode} ZFS payload operations and cleanup completed"
            host.stop
          end
        end
      end
    '';
  }
)
