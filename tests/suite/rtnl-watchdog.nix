import ../make-test.nix (
  { pkgs }:
  {
    name = "rtnl-watchdog";
    description = "RTNL request responsiveness";
    tags = [ "ci" ];

    machine = import ../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          kernel = config.boot.kernelPackage;
          fixture = kernel.stdenv.mkDerivation {
            pname = "rtnl-watchdog-test-fixture";
            version = kernel.modDirVersion;
            src = ./rtnl-watchdog;
            nativeBuildInputs = kernel.moduleBuildDependencies ++ [ pkgs.gnumake ];
            hardeningDisable = [ "pic" ];
            dontStrip = true;
            buildPhase = ''
              runHook preBuild
              make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M="$PWD" modules
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm444 rtnl_fixture.ko \
                "$out/lib/modules/${kernel.modDirVersion}/extra/rtnl_fixture.ko"
              runHook postInstall
            '';
          };
        in
        {
          system.vpsadminos.enableUnstable = lib.mkForce false;
          boot.kernelVersion = lib.mkForce "6.12.117";
          boot.enableUnifiedCgroupHierarchy = lib.mkForce true;
          boot.extraModulePackages = [ fixture ];
          osctl.rtnlWatchdog.enable = true;
          services.prometheus.exporters.node = {
            enable = true;
            listenAddress = "127.0.0.1";
            enabledCollectors = [ "textfile" ];
            extraFlags = [
              "--collector.disable-defaults"
              "--collector.textfile.directory=/run/metrics"
            ];
          };
          environment.systemPackages = [
            config.osctl.rtnlWatchdog.package
            pkgs.python3
            pkgs.util-linux
            pkgs.kmod
          ];
          environment.etc."rtnl-watchdog-test".source = ./rtnl-watchdog;
          boot.qemu.memory = 2048;
          boot.qemu.cpus = 2;
          boot.qemu.cpu.cores = 2;
          boot.qemu.cpu.threads = 1;
          boot.qemu.cpu.sockets = 1;
        };
    };

    testScript = builtins.readFile ./rtnl-watchdog/test.rb;
  }
)
