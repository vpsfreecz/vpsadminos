# os/livepatches/ebpf/available.nix
#
# Canonical registry of available eBPF livepatch programs.
# Only programs listed here are compiled and can be loaded.
# Deployable range programs own their record and source under owned/.
# Example sources remain in programs/.

{
  lib,
  kernelVersion,
  programs ? null,
}:
with lib;

let
  defaultPrograms = [
    {
      name = "override_uname";
      description = "Override uname(2) syscall to report spoofed kernel identity";
      kernelRanges = [
        { sinceKernel = "5.4"; }
      ];
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
      kernelRanges = [
        { sinceKernel = "5.7"; }
      ];
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
  ]
  ++ builtins.attrValues ownedPrograms;

  ownedPrograms =
    (import ../owned-records.nix { inherit lib; }) ./owned "[A-Za-z0-9][A-Za-z0-9_.-]*"
      (
        name: dir: files:
        let
          program = (import dir) // {
            inherit name;
          };
        in
        assert lib.assertMsg (
          (files."${name}.bpf.c" or null) == "regular"
        ) "Missing owned eBPF source ${name}.bpf.c";
        assert lib.assertMsg (
          programHasValidKernelRanges program && programHasValidLinkFields program
        ) "Invalid owned eBPF program ${name}";
        program
      );

  allPrograms = if programs == null then defaultPrograms else programs;

  allProgramNames = map (p: p.name) allPrograms;

  programsByName = builtins.listToAttrs (
    map (p: {
      name = p.name;
      value = p;
    }) allPrograms
  );

  versionBefore = kernelVer: untilKernel: builtins.compareVersions kernelVer untilKernel < 0;

  validKernelVersion =
    version: builtins.isString version && builtins.match "[0-9]+(\\.[0-9]+)*" version != null;

  kernelRangeIsValid =
    range:
    builtins.isAttrs range
    && all (
      name:
      elem name [
        "sinceKernel"
        "untilKernel"
      ]
    ) (attrNames range)
    && range ? sinceKernel
    && validKernelVersion range.sinceKernel
    && (
      !(range ? untilKernel)
      || (
        validKernelVersion range.untilKernel
        && builtins.compareVersions range.untilKernel range.sinceKernel > 0
      )
    );

  kernelRangesDoNotOverlap =
    ranges:
    all (
      pair:
      pair.fst ? untilKernel && builtins.compareVersions pair.fst.untilKernel pair.snd.sinceKernel <= 0
    ) (zipLists ranges (drop 1 ranges));

  programHasValidKernelRanges =
    program:
    program ? kernelRanges
    && builtins.isList program.kernelRanges
    && program.kernelRanges != [ ]
    && all kernelRangeIsValid program.kernelRanges
    && kernelRangesDoNotOverlap program.kernelRanges;

  kernelRangeMatches =
    kernelVer: range:
    versionAtLeast kernelVer range.sinceKernel
    && (!(range ? untilKernel) || versionBefore kernelVer range.untilKernel);

  programKernelRangeForVersion =
    kernelVer: program:
    if programHasValidKernelRanges program then
      findFirst (kernelRangeMatches kernelVer) null program.kernelRanges
    else
      null;

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

  programMatchesKernel = kernelVer: program: programKernelRangeForVersion kernelVer program != null;

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
    ownedPrograms
    allProgramNames
    programsByName
    programMatchesKernel
    programAvailableForKernel
    programHasValidBpfPrograms
    programHasValidKernelRanges
    programHasValidLinkFields
    programKernelRangeForVersion
    programLinkFields
    programsForVersion
    programNames
    programsAttrset
    validLinkField
    validBpfName
    kernelRangeIsValid
    kernelRangeMatches
    ;
  enabledPrograms = enabledPrograms kernelVersion;
  programNames' = programNames kernelVersion;
  programs' = programsAttrset kernelVersion;
}
