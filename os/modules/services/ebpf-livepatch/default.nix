{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.services.ebpf-livepatch;
  kernel = config.boot.kernelPackage;
  kernelVersion = config.boot.kernelVersion;

  ebpfDir = ../../../livepatches/ebpf;
  available = import (ebpfDir + /available.nix) {
    inherit lib kernelVersion;
  };

  programsEnabled = available.programs';

  requestedProgramNames = attrNames cfg.programs;
  knownRequestedProgramNames = filter (
    name: hasAttr name available.programsByName
  ) requestedProgramNames;
  unknownProgramNames = filter (name: !(hasAttr name available.programsByName)) requestedProgramNames;
  unavailableProgramNames = filter (
    name:
    hasAttr name available.programsByName && !(available.programAvailableForKernel kernelVersion name)
  ) requestedProgramNames;
  invalidProgramBpfNames = filter (
    name:
    hasAttr name available.programsByName
    && !(available.programHasValidBpfPrograms available.programsByName.${name})
  ) requestedProgramNames;
  invalidProgramLinkFields = filter (
    name:
    hasAttr name available.programsByName
    && !(available.programHasValidLinkFields available.programsByName.${name})
  ) requestedProgramNames;

  programKernelRange =
    program:
    "kernel >= ${program.sinceKernel} (inclusive)"
    + optionalString (program ? untilKernel) " and <= ${program.untilKernel} (inclusive)";

  unavailableProgramDescription =
    name: "${name} (${programKernelRange available.programsByName.${name}})";

  selectedPrograms = builtins.listToAttrs (
    map (name: {
      inherit name;
      value = {
        linkFields = available.programLinkFields available.programsByName.${name};
      };
    }) knownRequestedProgramNames
  );

  ebpfPkg = pkgs.callPackage ../../../packages/ebpf-livepatch {
    inherit kernel;
    inherit (pkgs) libbpf elfutils zlib;
    bpftool = pkgs.bpftools;
    programs = selectedPrograms;
  };

  serviceName = "ebpf-livepatch";
  stateDir = "/run/${serviceName}";
  pinRoot = "/sys/fs/bpf/vpsadminos/${serviceName}";
  generationsDir = "${pinRoot}/generations";
  preservePinsMarker = "${stateDir}/preserve-pins-on-finish";

  activatePinnedGeneration = pkgs.writeShellScript "ebpf-livepatch-activate-generation" ''
    set -eu

    state_dir=${stateDir}
    generations_dir=${generationsDir}
    loader=${ebpfPkg.loader}/bin/ebpf-loader

    ${pkgs.coreutils}/bin/mkdir -p "$state_dir" "$generations_dir"

    (
      ${pkgs.util-linux}/bin/flock -x 9

      generation="$(${pkgs.coreutils}/bin/date +%s%N)-$$"
      new_dir="$generations_dir/$generation"
      ${pkgs.coreutils}/bin/mkdir "$new_dir"

      if "$loader" pin all "$new_dir"; then
        echo "$generation" > "$state_dir/current-generation"
      else
        status=$?
        ${pkgs.coreutils}/bin/rm -rf "$new_dir"
        exit "$status"
      fi

      # Remove only links that have a same-named replacement. Pins with no
      # replacement keep protecting the running kernel until service stop/reboot.
      for new_pin in "$new_dir"/*; do
        [ -e "$new_pin" ] || continue
        pin_name="$(${pkgs.coreutils}/bin/basename "$new_pin")"

        for dir in "$generations_dir"/*; do
          [ -d "$dir" ] || continue
          [ "$dir" = "$new_dir" ] && continue

          if [ -e "$dir/$pin_name" ] && ! ${pkgs.coreutils}/bin/rm -f "$dir/$pin_name"; then
            echo "ebpf-livepatch: unable to remove stale pin $dir/$pin_name" >&2
          fi
        done
      done

      for dir in "$generations_dir"/*; do
        [ -d "$dir" ] || continue
        [ "$dir" = "$new_dir" ] && continue
        ${pkgs.coreutils}/bin/rmdir "$dir" 2>/dev/null || true
      done
    ) 9>"$state_dir/lock"
  '';

  removePinnedGenerations = pkgs.writeShellScript "ebpf-livepatch-remove-generations" ''
    set -eu

    state_dir=${stateDir}
    generations_dir=${generationsDir}

    ${pkgs.coreutils}/bin/mkdir -p "$state_dir"

    (
      ${pkgs.util-linux}/bin/flock -x 9
      ${pkgs.coreutils}/bin/rm -rf "$generations_dir"
      ${pkgs.coreutils}/bin/rm -f "$state_dir/current-generation"
    ) 9>"$state_dir/lock"
  '';

  reloadPinnedGeneration = pkgs.writeShellScript "ebpf-livepatch-reload" ''
    set -eu

    state_dir=${stateDir}
    marker=${preservePinsMarker}

    if ! ${activatePinnedGeneration}; then
      echo "ebpf-livepatch: unable to activate pinned generation; keeping current programs" >&2
      exit 0
    fi

    pid_file="/service/${serviceName}/supervise/pid"
    [ -r "$pid_file" ] || exit 0

    pid="$(${pkgs.coreutils}/bin/cat "$pid_file" 2>/dev/null || true)"
    case "$pid" in
      "" | *[!0-9]*)
        exit 0
        ;;
    esac

    [ -r "/proc/$pid/cmdline" ] || exit 0

    cmdline="$(${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$pid/cmdline")"
    case "$cmdline" in
      *"ebpf-loader run "*)
        ${pkgs.coreutils}/bin/touch "$marker"
        if kill -TERM "$pid" 2>/dev/null; then
          echo "ebpf-livepatch: stopped legacy run-mode loader after pinning"
        else
          ${pkgs.coreutils}/bin/rm -f "$marker"
        fi
        ;;
    esac
  '';

  programMetadata = map (
    name:
    let
      program = available.programsByName.${name};
    in
    {
      inherit name;
      description = program.description;
      sinceKernel = program.sinceKernel;
      untilKernel = program.untilKernel or null;
      bpfPrograms = program.bpfPrograms;
    }
  ) (filter (name: hasAttr name available.programsByName) requestedProgramNames);
in
{
  options = {
    services.ebpf-livepatch = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable eBPF-based live patching of kernel behavior at runtime.

          Loads BPF programs that can override syscalls, block operations
          via LSM hooks, or otherwise modify kernel behavior without rebooting.

          Only programs listed in os/livepatches/ebpf/available.nix are
          compiled and loaded. This is a proof-of-concept for vpsAdminOS.
        '';
      };

      programs = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = { };
          }
        );
        default = programsEnabled;
        description = ''
          eBPF programs to load, keyed by program name.

          Defaults to the complete list from available.nix filtered
          by kernel version requirements. In the program registry, sinceKernel
          is an inclusive lower bound and untilKernel is an inclusive upper
          bound when set. Programs can be selected only when the current
          boot.kernelVersion is within those bounds.
        '';
      };

      autoLoad = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically load eBPF programs via runit service at boot.
          When disabled, the ebpf-livepatch-loader binary is still
          available in the system path for manual use.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = unknownProgramNames == [ ];
          message =
            "services.ebpf-livepatch.programs contains unknown eBPF livepatch program(s): "
            + concatStringsSep ", " unknownProgramNames
            + ". Known programs: "
            + concatStringsSep ", " available.allProgramNames;
        }
        {
          assertion = unavailableProgramNames == [ ];
          message =
            "services.ebpf-livepatch.programs contains eBPF livepatch program(s) "
            + "not available for kernel ${kernelVersion}: "
            + concatStringsSep ", " (map unavailableProgramDescription unavailableProgramNames);
        }
        {
          assertion = invalidProgramBpfNames == [ ];
          message =
            "services.ebpf-livepatch.programs contains eBPF livepatch program(s) "
            + "with invalid BPF program names: "
            + concatStringsSep ", " invalidProgramBpfNames
            + ". BPF program names must be non-empty, at most 15 characters, "
            + "and contain only ASCII letters, digits, '_', or '.'.";
        }
        {
          assertion = invalidProgramLinkFields == [ ];
          message =
            "services.ebpf-livepatch.programs contains eBPF livepatch program(s) "
            + "with invalid BPF skeleton link field names: "
            + concatStringsSep ", " invalidProgramLinkFields
            + ". Link field names must be valid C identifiers.";
        }
      ];

      environment.etc."vpsadminos/ebpf-livepatch-monitor.json".text = builtins.toJSON {
        bpftool = "${pkgs.bpftools}/bin/bpftool";
        inherit kernelVersion;
        programs = programMetadata;
      };

      environment.systemPackages = [ ebpfPkg.loader ];
    }

    (mkIf cfg.autoLoad {
      runit.services.ebpf-livepatch = {
        path = [
          pkgs.coreutils
          pkgs.util-linux
        ];
        run = ''
          echo "ebpf-livepatch: activating pinned generation..."
          ${activatePinnedGeneration}
          exec ${pkgs.coreutils}/bin/sleep inf
        '';
        control.usr1 = ''
          exec ${reloadPinnedGeneration}
        '';
        finish = ''
          if [ -e ${preservePinsMarker} ]; then
            rm -f ${preservePinsMarker}
            echo "ebpf-livepatch: preserving pinned programs for handoff"
          else
            ${removePinnedGenerations}
            echo "ebpf-livepatch: programs detached"
          fi
        '';
        runlevels = [ "default" ];
        onChange = "reload";
        reloadMethod = "1";
      };
    })
  ]);
}
