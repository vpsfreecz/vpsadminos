# os/livepatches/ebpf/available.nix
#
# Canonical registry of available eBPF livepatch programs.
# Only programs listed here are compiled and can be loaded.
# Each entry must have a corresponding .bpf.c file in programs/.

{
  lib,
  kernelVersion,
}:
with lib;

let
  allPrograms = [
    {
      name = "override_uname";
      description = "Override uname(2) syscall to report spoofed kernel identity";
      sinceKernel = "5.4";
      bpfPrograms = [
        "uname_fentry"
        "uname_fexit"
      ];
      enable = false;
    }
    {
      name = "lsm_example";
      description = "Demonstrate eBPF LSM hooks on task_prctl and sysctl";
      sinceKernel = "5.7";
      bpfPrograms = [
        "lsm_cred_prep"
        "lsm_task_prctl"
        "lsm_sysctl"
      ];
      # Requires per-target-kernel vmlinux.h for CO-RE LSM type compatibility;
      # enable after building with matching kernel BTF.
      enable = false;
    }
    {
      name = "ptrace_mm_guard";
      description = "Deny ptrace access to mm-less tasks without init-ns CAP_SYS_PTRACE";
      sinceKernel = "5.7";
      bpfPrograms = [ "ptrace_mm_guard" ];
      enable = true;
    }
  ];

  allProgramNames = map (p: p.name) allPrograms;

  programsByName = builtins.listToAttrs (
    map (p: {
      name = p.name;
      value = p;
    }) allPrograms
  );

  versionUpTo = kernelVer: untilKernel: builtins.compareVersions kernelVer untilKernel <= 0;

  validBpfName = name: builtins.isString name && name != "" && builtins.stringLength name <= 15;

  programHasValidBpfPrograms =
    program:
    program ? bpfPrograms
    && builtins.isList program.bpfPrograms
    && program.bpfPrograms != [ ]
    && all validBpfName program.bpfPrograms;

  programMatchesKernel =
    kernelVer: program:
    versionAtLeast kernelVer program.sinceKernel
    && (!(program ? untilKernel) || versionUpTo kernelVer program.untilKernel);

  programAvailableForKernel =
    kernelVer: name:
    hasAttr name programsByName && programMatchesKernel kernelVer programsByName.${name};

  programsForVersion = kernelVer: filter (programMatchesKernel kernelVer) allPrograms;

  enabledPrograms = kernelVer: filter (p: p.enable) (programsForVersion kernelVer);

  programNames = kernelVer: map (p: p.name) (enabledPrograms kernelVer);

  # Return an attrset suitable for the packages derivation's programs parameter
  programsAttrset =
    kernelVer:
    builtins.listToAttrs (
      map (p: {
        name = p.name;
        value = { };
      }) (enabledPrograms kernelVer)
    );
in
{
  inherit
    allPrograms
    allProgramNames
    programsByName
    programMatchesKernel
    programAvailableForKernel
    programHasValidBpfPrograms
    programsForVersion
    programNames
    programsAttrset
    validBpfName
    ;
  enabledPrograms = enabledPrograms kernelVersion;
  programNames' = programNames kernelVersion;
  programs' = programsAttrset kernelVersion;
}
