import ../../make-test.nix (
  { pkgs }:
  let
    fakeOsvmPackage = pkgs.writeShellScriptBin "osvm" ''
      set -eu

      [ "$1" = "script" ] || {
        echo "unsupported osvm command: $*" >&2
        exit 1
      }

      script="$2"
      shift 2

      json_config="$(${pkgs.gnused}/bin/sed -n "s/.*MachineConfig.load_file('\\([^']*\\)').*/\\1/p" "$script")"

      [ -n "$json_config" ] || {
        echo "unable to find machine config in $script" >&2
        exit 1
      }

      toplevel="$(${pkgs.ruby}/bin/ruby -rjson -e '
        cfg = JSON.parse(File.read(ARGV[0]))
        puts(cfg.fetch("toplevel"))
      ' "$json_config")"

      while IFS=$'\t' read -r fs_name fs_path; do
        mountpoint="/mnt/$fs_name"
        ${pkgs.coreutils}/bin/mkdir -p /mnt
        ${pkgs.coreutils}/bin/rm -rf "$mountpoint"
        ${pkgs.coreutils}/bin/ln -s "$fs_path" "$mountpoint"
      done < <(
        ${pkgs.ruby}/bin/ruby -rjson -e '
          cfg = JSON.parse(File.read(ARGV[0]))
          cfg.fetch("sharedFileSystems").each do |name, path|
            puts("#{name}\t#{path}")
          end
        ' "$json_config"
      )

      exec "$toplevel/sw/bin/build-image-repository-test" "$@"
    '';

    fakeOsctlImagePackage = pkgs.writeShellScriptBin "osctl-image" ''
      set -eu

      build_scripts=
      vpsadminos_dir=
      build_dataset=
      output_dir=

      while [ $# -gt 0 ]; do
        case "$1" in
          --build-scripts)
            build_scripts="$2"
            shift 2
            ;;
          --vpsadminos-dir)
            vpsadminos_dir="$2"
            shift 2
            ;;
          deploy)
            shift
            break
            ;;
          *)
            echo "unexpected argument before deploy: $1" >&2
            exit 1
            ;;
        esac
      done

      [ "$build_scripts" = "/mnt/buildScripts" ] || {
        echo "unexpected build scripts dir: $build_scripts" >&2
        exit 1
      }

      [ "$vpsadminos_dir" = "/mnt/vpsadminos" ] || {
        echo "unexpected vpsadminos dir: $vpsadminos_dir" >&2
        exit 1
      }

      [ -d "$vpsadminos_dir/os" ] || {
        echo "missing vpsadminos checkout at $vpsadminos_dir" >&2
        exit 1
      }

      [ -x "$build_scripts/bin/runner" ] || {
        echo "invalid build scripts dir: $build_scripts" >&2
        exit 1
      }

      while [ $# -gt 0 ]; do
        case "$1" in
          --build-dataset)
            build_dataset="$2"
            shift 2
            ;;
          --output-dir)
            output_dir="$2"
            shift 2
            ;;
          --rebuild|--keep-failed|--skip-tests)
            shift
            ;;
          --tag)
            shift 2
            ;;
          *)
            break
            ;;
        esac
      done

      [ $# -eq 2 ] || {
        echo "expected image name and repository path, got: $*" >&2
        exit 1
      }

      image="$1"
      repo="$2"

      mkdir -p "$repo"

      cat <<EOF > "$repo/osctl-image.args"
      build_scripts=$build_scripts
      vpsadminos_dir=$vpsadminos_dir
      build_dataset=$build_dataset
      output_dir=$output_dir
      image=$image
      EOF

      touch "$repo/osctl-image.ok"
    '';

    fakeOsctlRepoPackage = pkgs.writeShellScriptBin "osctl-repo" ''
      set -eu

      [ "$1" = "local" ] || {
        echo "unsupported repository command: $*" >&2
        exit 1
      }

      shift

      case "$1" in
        init)
          touch .osctl-repo.init
          ;;
        default)
          printf '%s\n' "$*" >> .osctl-repo.default
          ;;
        *)
          echo "unsupported local repository command: $*" >&2
          exit 1
          ;;
      esac
    '';
  in
  {
    name = "osctl-image-repository-build-service";

    description = ''
      Test build-vpsadminos-container-image-repository passes the vpsAdminOS
      checkout to nested image repository builds
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { lib, ... }:
        {
          boot.qemu.memory = lib.mkOverride 0 (8 * 1024);

          services.build-vpsadminos-container-image-repository.test = {
            enable = true;
            osvmPackage = fakeOsvmPackage;

            osVm = {
              memory = lib.mkForce 2048;
              network.hostForward = lib.mkForce null;
              disks = lib.mkForce [
                {
                  device = "sda.img";
                  type = "file";
                  size = "8G";
                  create = true;
                }
              ];
            };

            osModules = [
              (
                { lib, ... }:
                {
                  boot.kernelParams = [ "root=/dev/vda" ];
                  boot.initrd.kernelModules = [
                    "virtio"
                    "virtio_pci"
                    "virtio_net"
                    "virtio_rng"
                    "virtio_blk"
                    "virtio_console"
                  ];
                  boot.enableUnifiedCgroupHierarchy = true;

                  networking.hostName = lib.mkDefault "vpsadminos";
                  networking.static.enable = lib.mkDefault true;
                  networking.lxcbr.enable = lib.mkDefault true;
                  networking.firewall.conntrack.enable = lib.mkDefault true;
                  networking.nameservers = lib.mkDefault [ "10.0.2.3" ];

                  osctl.test-shell.enable = true;

                  tty.autologin.enable = lib.mkDefault true;
                  services.haveged.enable = lib.mkDefault true;
                  os.channel-registration.enable = lib.mkDefault false;
                  services.openssh.enable = true;

                  boot.zfs.pools.tank = {
                    layout = [
                      { devices = [ "sda" ]; }
                    ];
                    importAttempts = lib.mkDefault 3;
                    doCreate = true;
                    install = true;
                    properties."feature@block_cloning" = "disabled";
                    datasets = {
                      "image-repository/build-dataset" = { };
                    };
                  };

                  services.osctl.image-repository.test = {
                    path = "/mnt/repoDir";
                    cacheDir = "/mnt/cacheDir";
                    buildScriptDir = "/mnt/buildScripts";
                    vpsadminosDir = "/mnt/vpsadminos";
                    buildDataset = "tank/image-repository/build-dataset";
                    logDir = "/mnt/logDir";
                    osctlImagePackage = fakeOsctlImagePackage;
                    osctlRepoPackage = fakeOsctlRepoPackage;
                    defaultVendor = "vpsadminos";
                    vendors.vpsadminos.defaultVariant = "minimal";
                    images = {
                      nixos = {
                        unstable = { };
                      };
                    };

                    garbageCollection = [ ];
                    postBuild = "";
                  };
                }
              )
            ];
          };
        };
    };

    testScript = ''
      machine.wait_for_osctl_pool("tank")

      repo_dir = "/var/lib/vpsadminos-container-image-repository/test/repository"

      machine.succeeds("command -v build-vpsadminos-repository-test")
      machine.succeeds("build-vpsadminos-repository-test", timeout: 5 * 60)

      machine.all_succeed(
        "test -f #{repo_dir}/osctl-image.ok",
        "test -f #{repo_dir}/osctl-image.args",
        "test -f #{repo_dir}/.osctl-repo.init",
        "test -f #{repo_dir}/.osctl-repo.default"
      )

      args = machine.succeeds("cat #{repo_dir}/osctl-image.args")[1]

      expect(args).to include("build_scripts=/mnt/buildScripts")
      expect(args).to include("vpsadminos_dir=/mnt/vpsadminos")
      expect(args).to include("build_dataset=tank/image-repository/build-dataset")
      expect(args).to include("image=nixos-unstable")

      defaults = machine.succeeds("cat #{repo_dir}/.osctl-repo.default")[1]

      expect(defaults).to include("default vpsadminos minimal")
      expect(defaults).to include("default vpsadminos")
    '';
  }
)
