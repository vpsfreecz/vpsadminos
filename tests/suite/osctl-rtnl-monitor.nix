import ../make-test.nix (
  { pkgs }:
  {
    name = "osctl-rtnl-monitor";
    description = "Bounded RTNL waiter diagnostics on a disposable kernel";
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
            pname = "rtnl-monitor-test-fixture";
            version = kernel.modDirVersion;
            src = ./osctl-rtnl-monitor;
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
          # The fixture module is reachable only from this test definition.
          # The real service smoke stops both services before isolated cases.
          osctl.rtnlMonitor.enable = true;
          environment.systemPackages = [
            config.osctl.rtnlMonitor.package
            pkgs.python3
            pkgs.bpftools
            pkgs.iproute2
            pkgs.kmod
          ];
          environment.etc."rtnl-monitor-test-bpf-object".text =
            "${config.osctl.rtnlMonitor.package}/lib/osctl-rtnl-monitor/monitor.bpf.o";
          environment.etc."rtnl-monitor-test.py".source = ./osctl-rtnl-monitor/fixture.py;
          environment.etc."rtnl-monitor-service-smoke.py".source = ./osctl-rtnl-monitor/service_smoke.py;
          environment.etc."rtnl-monitor-smoke-init".source = ./osctl-rtnl-monitor/smoke-init.sh;
          environment.etc."rtnl-monitor-smoke-busybox".source = "${pkgs.pkgsStatic.busybox}/bin/busybox";
          boot.qemu.memory = 2048;
          boot.qemu.cpus = 2;
          boot.qemu.cpu.cores = 2;
          boot.qemu.cpu.threads = 1;
          boot.qemu.cpu.sockets = 1;
        };
    };

    testScript = builtins.readFile ./osctl-rtnl-monitor/test.rb;
  }
)
