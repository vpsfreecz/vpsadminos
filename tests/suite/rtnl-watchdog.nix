import ../make-test.nix (
  { pkgs }:
  {
    name = "rtnl-watchdog";
    description = "RTNL request responsiveness and guarded oomd actions";
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
          policyRuby = pkgs.osctl-oomd.basicEnv.ruby;
          policyTest = pkgs.writeShellScriptBin "rtnl-watchdog-policy-test" ''
            export GEM_HOME=${pkgs.osctl-oomd.basicEnv}/${policyRuby.gemPath}
            export GEM_PATH="$GEM_HOME"
            exec ${policyRuby}/bin/ruby /etc/rtnl-watchdog-test/policy.rb "$@"
          '';
        in
        {
          system.vpsadminos.enableUnstable = lib.mkForce false;
          boot.kernelVersion = lib.mkForce "6.12.117";
          boot.enableUnifiedCgroupHierarchy = lib.mkForce true;
          boot.extraModulePackages = [ fixture ];
          osctl.rtnlWatchdog.enable = true;
          osctl.oomd.enable = false;
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
            pkgs.osctl-oomd
            pkgs.python3
            pkgs.util-linux
            pkgs.kmod
            policyTest
          ];
          environment.etc."rtnl-watchdog-test".source = ./rtnl-watchdog;
          environment.etc."rtnl-watchdog-test-busybox".source = "${pkgs.pkgsStatic.busybox}/bin/busybox";
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
