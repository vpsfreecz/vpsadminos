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
      # Kernel-visible BPF object names reported by bpftool.
      bpfPrograms = [
        "uname_fentry"
        "uname_fexit"
      ];
      linkFields = [
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
      linkFields = [
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
      untilKernel = "6.12.88";
      bpfPrograms = [ "ptrace_mm_guard" ];
      linkFields = [ "ptrace_mm_guard" ];
      enable = true;
    }
    {
      name = "cifs_spnego_guard";
      description = "Deny userspace-created cifs.spnego keys outside CIFS private upcalls";
      sinceKernel = "5.7";
      bpfPrograms = [ "cifs_spnego" ];
      linkFields = [ "cifs_spnego" ];
      enable = true;
    }
    {
      name = "nft_cve23111_guard";
      description = "Deny risky nf_tables verdict-map delete batches from user namespaces";
      sinceKernel = "6.12.33";
      untilKernel = "6.12.69";
      bpfPrograms = [ "nft23111_guard" ];
      linkFields = [ "nft23111_guard" ];
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

  # BPF_OBJ_NAME_LEN is 16 including the trailing NUL. The kernel accepts
  # only isalnum(), '_' and '.' in bpf_obj_name_cpy().
  validBpfName =
    name:
    builtins.isString name
    && name != ""
    && builtins.stringLength name <= 15
    && builtins.match "[A-Za-z0-9_.]+" name != null;

  validLinkField =
    name: builtins.isString name && name != "" && builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;

  programLinkFields = program: program.linkFields or program.bpfPrograms;

  programHasValidBpfPrograms =
    program:
    program ? bpfPrograms
    && builtins.isList program.bpfPrograms
    && program.bpfPrograms != [ ]
    && all validBpfName program.bpfPrograms;

  programHasValidLinkFields =
    program:
    programHasValidBpfPrograms program
    && builtins.isList (programLinkFields program)
    && programLinkFields program != [ ]
    && all validLinkField (programLinkFields program);

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
    programHasValidLinkFields
    programLinkFields
    programsForVersion
    programNames
    programsAttrset
    validLinkField
    validBpfName
    ;
  enabledPrograms = enabledPrograms kernelVersion;
  programNames' = programNames kernelVersion;
  programs' = programsAttrset kernelVersion;
}
