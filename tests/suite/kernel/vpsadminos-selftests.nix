import ../../make-test.nix (
  { pkgs }:
  {
    name = "kernel-vpsadminos-selftests";

    description = ''
      Run vpsAdminOS kernel selftests from tools/testing/selftests/vpsadminos
    '';

    tags = [ "ci" ];

    machine = (
      import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            selftests = pkgs.stdenv.mkDerivation {
              pname = "vpsadminos-kernel-selftests";
              version = config.boot.kernelVersion;
              src = config.boot.kernelPackage.src;

              nativeBuildInputs = [ pkgs.rsync ];

              dontConfigure = true;

              buildPhase = ''
                runHook preBuild
                make -C tools/testing/selftests/vpsadminos
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                make -C tools/testing/selftests/vpsadminos \
                  INSTALL_PATH=$out/bin install
                find $out/bin -maxdepth 1 \
                  -type f -name '*.sh' -exec chmod +x {} +
                patchShebangs $out/bin
                runHook postInstall
              '';
            };
          in
          {
            boot.qemu = {
              memory = lib.mkForce 4096;
              cpus = lib.mkForce 1;
              cpu = {
                cores = lib.mkForce 1;
                threads = lib.mkForce 1;
                sockets = lib.mkForce 1;
              };
            };

            boot.kernel.sysctl = {
              "kernel.bpf_container_tracing_enabled" = lib.mkForce 1;
              "kernel.unprivileged_bpf_disabled" = lib.mkForce 1;
              "kernel.kptr_restrict" = lib.mkForce 0;
            };

            environment.systemPackages = [
              pkgs.coreutils
              pkgs.gawk
              pkgs.util-linux
              selftests
            ];
          };
      }
    );

    testScript = ''
      selftests = "/run/current-system/sw/bin"
      tests = %w[
        tracing_ns_control_path.sh
        tracing_bpf_userns_control.sh
        kernfs_filter_reload_visibility.sh
        bpf_map_in_map_domain.sh
      ]
      helpers = %w[
        tracing_ns_smoke
        tracing_bpf_userns_smoke
        bpf_map_in_map_domain_smoke
      ]

      machine.start
      machine.wait_until_online
      machine.wait_for_osctl_pool('tank', timeout: 8 * 60)

      (tests + helpers).each do |test|
        machine.succeeds("test -x #{selftests}/#{test}")
      end

      tests.each do |test|
        machine.succeeds("cd #{selftests} && ./#{test}", timeout: 180)
      end
    '';
  }
)
