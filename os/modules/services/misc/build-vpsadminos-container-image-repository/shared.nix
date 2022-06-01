{ config, pkgs, lib }:
with lib;
let
  cfg = config.services.build-vpsadminos-container-image-repository;

  machineOs = repoCfg: import ../../../../. {
    importedPkgs = pkgs;
    modules = repoCfg.osModules;
  };

  machineConfig = repoCfg: os: {
    qemu = toString pkgs.qemu_kvm;
    memory = repoCfg.osVm.memory;
    cpus = repoCfg.osVm.cpus;
    cpu = repoCfg.osVm.cpu;
    disks = repoCfg.osVm.disks;
    shared_filesystems = {
      "buildScripts" = repoCfg.buildScripts;
      "cacheDir" = repoCfg.cacheDirectory;
      "logDir" = repoCfg.logDirectory;
      "repoDir" = repoCfg.repositoryDirectory;
    };
    squashfs = os.config.system.build.squashfs;
    kernel = "${os.config.system.build.kernel}/bzImage";
    initrd = "${os.config.system.build.initialRamdisk}/initrd";
    toplevel = os.config.system.build.toplevel;
    kernelParams = os.config.boot.kernelParams ++ [ "quiet" "panic=-1" ];
  };

  machineJsonConfig = repoCfg: builtins.toJSON (machineConfig repoCfg (machineOs repoCfg));

  machineConfigFile = repoCfg:
    pkgs.writeText "machine-config.json" (machineJsonConfig repoCfg);

  stateDir = repoName: "/var/lib/build-vpsadminos-repository/${repoName}";

  osvmScript = repoName: repoCfg: pkgs.writeText "build-vpsadminos-repository-${repoName}.rb" ''
    require 'fileutils'
    require 'json'

    cfg = JSON.parse(File.read('${machineConfigFile repoCfg}'), symbolize_names: true)

    stateDir = '${stateDir repoName}'
    FileUtils.mkdir_p(stateDir)

    machine = OsVm::Machine.new("builder-${repoName}", cfg, stateDir, stateDir)

    begin
      machine.start
      machine.wait_for_boot

      cfg[:shared_filesystems].each_key do |fs_name|
        mountpoint = "/mnt/#{fs_name}"

        machine.all_succeed(
          "mkdir -p \"#{mountpoint}\"",
          "mount -t virtiofs #{fs_name} \"#{mountpoint}\"",
        )
      end

      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online

      cmd = [
        'build-image-repository-${repoName}',
      ] + ARGV.map { |v| "\"#{v}\"" }
      machine.succeeds(cmd.join(' '), timeout: 12*60*60)

      machine.stop
      machine.wait_for_shutdown
    ensure
      machine.kill
      machine.finalize
      machine.cleanup
    end
  '';

  enabledRepos = repos: filterAttrs (repoName: repoCfg: repoCfg.enable) repos;

  enabledTimers = repos: filterAttrs (repoName: repoCfg: repoCfg.enable && repoCfg.systemd.timer.enable) repos;

  buildScript = repoName: repoCfg:
    pkgs.writeScriptBin "build-vpsadminos-repository-${repoName}" ''
      #!${pkgs.bash}/bin/bash

      mkdir -p ${repoCfg.cacheDirectory} \
               ${repoCfg.logDirectory} \
               ${repoCfg.repositoryDirectory}

      ${pkgs.osvm}/bin/osvm script ${osvmScript repoName repoCfg} "$@"
      buildRc=$?

      ${repoCfg.postRunCommands}
      exit $buildRc
    '';

  buildService = repoName: repoCfg:
    nameValuePair "build-vpsadminos-container-image-repository-${repoName}" {
      description = "Build vpsAdminOS container image repository ${repoName}";
      postStop = ''
        rm -f "${stateDir repoName}/*.sock"
      '';
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${buildScript repoName repoCfg}/bin/build-vpsadminos-repository-${repoName}";
        StartTimeoutSec = "12h";
      };
    };

  buildTimer = repoName: repoCfg:
    nameValuePair "build-vpsadminos-container-image-repository-${repoName}" {
      description = "Build vpsAdminOS container image repository ${repoName}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = repoCfg.systemd.timer.onCalendar;
      };
    };
in {
  createSystemPackages = repos: flatten (mapAttrsToList buildScript (enabledRepos repos));

  createSystemdServices = repos: mapAttrs' buildService (enabledRepos repos);

  createSystemdTimers = repos: mapAttrs' buildTimer (enabledTimers repos);
}
