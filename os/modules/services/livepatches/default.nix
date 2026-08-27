{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
with lib;

let
  cfg = config.services.live-patches;
  zfsBuiltinPkg = config.boot.zfsBuiltinPkg;
  patchesDir = ../../../livepatches;
  availablePatches = import (patchesDir + /available-patches.nix) {
    inherit lib;
    version = config.boot.kernelVersion;
  };
  release = availablePatches.release;
  patchVersion = availablePatches.patchVersion;
  isStructuredRelease = candidate: candidate != null && candidate ? paths;
  releasePathsFor = candidate: if isStructuredRelease candidate then attrValues candidate.paths else [ ];
  pathArtifactsFor =
    candidate: pathName:
    if isStructuredRelease candidate && candidate ? paths && hasAttr pathName candidate.paths
    then getAttr pathName candidate.paths
    else [ ];
  onlineArtifactsFor =
    candidate: if isStructuredRelease candidate then concatLists (releasePathsFor candidate) else [ ];
  checkpointArtifactFor =
    candidate:
    if isStructuredRelease candidate && candidate ? checkpoint then candidate.checkpoint else null;
  releaseArtifactsFor =
    candidate:
    let
      checkpointArtifact = checkpointArtifactFor candidate;
    in
    onlineArtifactsFor candidate ++ optional (checkpointArtifact != null) checkpointArtifact;
  bootstrapArtifactsFor =
    candidate:
    map (artifact: artifact.bootstrap) (filter (artifact: artifact ? bootstrap) (releaseArtifactsFor candidate));
  releaseContractFor =
    candidate:
    if isStructuredRelease candidate && candidate ? contract then candidate.contract else null;
  releasePatchVersionFor =
    candidate:
    if candidate != null && candidate ? patchVersion then candidate.patchVersion else patchVersion;
  patchNameFor = candidate: "${toString (releasePatchVersionFor candidate)}";
  artifactsFor = candidate: if isStructuredRelease candidate then releaseArtifactsFor candidate else [ legacyArtifact ];
  structuredRelease = isStructuredRelease release;
  multiAnchorRelease = structuredRelease && release ? onlineAnchors;
  releasePaths = releasePathsFor release;
  onlineArtifacts = onlineArtifactsFor release;
  checkpointArtifact = checkpointArtifactFor release;
  releaseArtifacts = releaseArtifactsFor release;
  bootstrapArtifacts = bootstrapArtifactsFor release;

  buildEnable = (patchVersion > 0) && cfg.enable;

  kernel = config.boot.kernelPackage;
  kpatch-build = pkgs.callPackage (import ../../../packages/kpatch-build/default.nix) { };

  patchName = patchNameFor release;
  installModDir = "lib/modules/${kernel.modDirVersion}/extra";
  legacyPatchModuleName = "livepatch_${toString patchVersion}";
  patchModuleName = legacyPatchModuleName;
  installModPath = "${installModDir}/${patchModuleName}.ko";
  transitionGuard = null;
  transitionBootstrap = null;
  guardModuleName = null;
  guardInstallModPath = null;
  bootstrapModuleName = null;
  bootstrapInstallModPath = null;
  legacyArtifact = {
    role = "legacy-checkpoint";
    moduleName = legacyPatchModuleName;
    buildPatches = availablePatches.patchList;
    targets = availablePatches.patchTargets;
    nonReplace = false;
    expectedSha256 = null;
  };
  artifacts = if structuredRelease then releaseArtifacts else [ legacyArtifact ];
  releaseContract = releaseContractFor release;

  roleFlagsFor =
    role:
    let
      isGuard = elem role [
        "bootstrap-guard"
        "checkpoint-guard"
        "reverse-guard"
      ];
    in
    {
      inherit isGuard;
      isCheckpointGuard = role == "checkpoint-guard";
      isReverseGuard = role == "reverse-guard";
      isFoundation = role == "foundation";
      isGenerationFinal = role == "generation-final";
      isCheckpoint = role == "checkpoint";
    };

  contractForRole =
    releaseContract: role:
    if releaseContract == null then null
    else if role == "bootstrap-guard" then releaseContract.guard or null
    else if role == "checkpoint-guard" then releaseContract.checkpointGuard or null
    else if role == "reverse-guard" then releaseContract.reverseGuard or null
    else if role == "foundation" then releaseContract.foundation or null
    else if role == "generation-final" then releaseContract.final or null
    else if role == "checkpoint" then releaseContract.checkpoint or null
    else null;

  requireFrozenMetadata =
    artifact: label: value:
    if value == null then
      throw "live-patches: ${artifact.moduleName} missing frozen ${label}"
    else
      value;

  contractFunctionCount =
    artifact: label: contract:
    toString (
      requireFrozenMetadata artifact "${label}.functionCount" (
        if contract == null then null else contract.functionCount or null
      )
    );

  contractInventoryLiteral =
    artifact: label: field: contract:
    let
      inventoryId =
        if contract == null then null else contract.inventoryId or null;
    in
    requireFrozenMetadata artifact "${label}.inventoryId.${field}" (
      if inventoryId == null then null else inventoryId.${field} or null
    );

  buildDefineLines =
    artifact:
    let
      defines = artifact.buildDefines or { };
      defineNames = sort builtins.lessThan (attrNames defines);
    in
    concatMapStringsSep "\n" (
      name: "#define ${name} ${defines.${name}}"
    ) defineNames;

  livepatchBuildHeader =
    artifact: selectedRelease:
    if !(isStructuredRelease selectedRelease) then ''
      #ifndef VPSADMINOS_LIVEPATCH_BUILD_H
      #define VPSADMINOS_LIVEPATCH_BUILD_H
      #define LIVEPATCH_ORIG_KERNEL_VERSION        "${kernel.modDirVersion}"
      #define LIVEPATCH_NAME                       "${patchNameFor selectedRelease}"
      #define LIVEPATCH_ARTIFACT_ROLE              "${artifact.role}"
      ${buildDefineLines artifact}
      #endif
    '' else
    let
      releaseContract = releaseContractFor selectedRelease;
      flags = roleFlagsFor artifact.role;
      selfContract =
        requireFrozenMetadata artifact "release.contract.self"
          (contractForRole releaseContract artifact.role);
      anchorContract =
        if flags.isCheckpointGuard then null
        else if flags.isReverseGuard
        then requireFrozenMetadata artifact "release.contract.checkpoint" (releaseContract.checkpoint or null)
        else if flags.isGuard || flags.isFoundation || flags.isGenerationFinal || flags.isCheckpoint
        then requireFrozenMetadata artifact "release.contract.anchor" (releaseContract.anchor or null)
        else null;
      guardContract =
        if flags.isFoundation || flags.isGenerationFinal || flags.isCheckpoint
        then requireFrozenMetadata artifact "release.contract.guard" (releaseContract.guard or null)
        else null;
      foundationContract =
        if flags.isGenerationFinal || flags.isCheckpoint
        then requireFrozenMetadata artifact "release.contract.foundation" (releaseContract.foundation or null)
        else null;
      finalContract =
        if flags.isCheckpoint
        then requireFrozenMetadata artifact "release.contract.final" (releaseContract.final or null)
        else null;
    in
    ''
      #ifndef VPSADMINOS_LIVEPATCH_BUILD_H
      #define VPSADMINOS_LIVEPATCH_BUILD_H
      #define LIVEPATCH_ORIG_KERNEL_VERSION        "${kernel.modDirVersion}"
      #define LIVEPATCH_NAME                       "${patchNameFor selectedRelease}"
      #define LIVEPATCH_ARTIFACT_ROLE              "${artifact.role}"
      ${buildDefineLines artifact}
      #ifdef __GENKSYMS__
      #define LIVEPATCH_IS_GUARD                   0
      #define LIVEPATCH_IS_CHECKPOINT_GUARD        0
      #define LIVEPATCH_IS_REVERSE_GUARD           0
      #define LIVEPATCH_IS_FOUNDATION              0
      #define LIVEPATCH_IS_GENERATION_FINAL        0
      #define LIVEPATCH_IS_CHECKPOINT              0
      #define LIVEPATCH_EXPECTED_FUNCTIONS         0
      #define LIVEPATCH_INVENTORY_ID_HI            0ULL
      #define LIVEPATCH_INVENTORY_ID_LO            0ULL
      #define LIVEPATCH_ANCHOR_FUNCTIONS           0
      #define LIVEPATCH_ANCHOR_INVENTORY_ID_HI     0ULL
      #define LIVEPATCH_ANCHOR_INVENTORY_ID_LO     0ULL
      #define LIVEPATCH_GUARD_FUNCTIONS            0
      #define LIVEPATCH_GUARD_INVENTORY_ID_HI      0ULL
      #define LIVEPATCH_GUARD_INVENTORY_ID_LO      0ULL
      #define LIVEPATCH_FOUNDATION_FUNCTIONS       0
      #define LIVEPATCH_FOUNDATION_INVENTORY_ID_HI 0ULL
      #define LIVEPATCH_FOUNDATION_INVENTORY_ID_LO 0ULL
      #define LIVEPATCH_FINAL_FUNCTIONS            0
      #define LIVEPATCH_FINAL_INVENTORY_ID_HI      0ULL
      #define LIVEPATCH_FINAL_INVENTORY_ID_LO      0ULL
      #else
      #define LIVEPATCH_IS_GUARD                   ${if flags.isGuard then "1" else "0"}
      #define LIVEPATCH_IS_CHECKPOINT_GUARD        ${if flags.isCheckpointGuard then "1" else "0"}
      #define LIVEPATCH_IS_REVERSE_GUARD           ${if flags.isReverseGuard then "1" else "0"}
      #define LIVEPATCH_IS_FOUNDATION              ${if flags.isFoundation then "1" else "0"}
      #define LIVEPATCH_IS_GENERATION_FINAL        ${if flags.isGenerationFinal then "1" else "0"}
      #define LIVEPATCH_IS_CHECKPOINT              ${if flags.isCheckpoint then "1" else "0"}
      #define LIVEPATCH_EXPECTED_FUNCTIONS         ${contractFunctionCount artifact "release.contract.self" selfContract}
      #define LIVEPATCH_INVENTORY_ID_HI            ${contractInventoryLiteral artifact "release.contract.self" "high" selfContract}
      #define LIVEPATCH_INVENTORY_ID_LO            ${contractInventoryLiteral artifact "release.contract.self" "low" selfContract}
      #define LIVEPATCH_ANCHOR_FUNCTIONS           ${if anchorContract == null then "0" else contractFunctionCount artifact "release.contract.anchor" anchorContract}
      #define LIVEPATCH_ANCHOR_INVENTORY_ID_HI     ${if anchorContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.anchor" "high" anchorContract}
      #define LIVEPATCH_ANCHOR_INVENTORY_ID_LO     ${if anchorContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.anchor" "low" anchorContract}
      #define LIVEPATCH_GUARD_FUNCTIONS            ${if guardContract == null then "0" else contractFunctionCount artifact "release.contract.guard" guardContract}
      #define LIVEPATCH_GUARD_INVENTORY_ID_HI      ${if guardContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.guard" "high" guardContract}
      #define LIVEPATCH_GUARD_INVENTORY_ID_LO      ${if guardContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.guard" "low" guardContract}
      #define LIVEPATCH_FOUNDATION_FUNCTIONS       ${if foundationContract == null then "0" else contractFunctionCount artifact "release.contract.foundation" foundationContract}
      #define LIVEPATCH_FOUNDATION_INVENTORY_ID_HI ${if foundationContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.foundation" "high" foundationContract}
      #define LIVEPATCH_FOUNDATION_INVENTORY_ID_LO ${if foundationContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.foundation" "low" foundationContract}
      #define LIVEPATCH_FINAL_FUNCTIONS            ${if finalContract == null then "0" else contractFunctionCount artifact "release.contract.final" finalContract}
      #define LIVEPATCH_FINAL_INVENTORY_ID_HI      ${if finalContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.final" "high" finalContract}
      #define LIVEPATCH_FINAL_INVENTORY_ID_LO      ${if finalContract == null then "0ULL" else contractInventoryLiteral artifact "release.contract.final" "low" finalContract}
      #endif
      #endif
    '';

  prepareKernelSource = ''
    export DEBUG=0
    export CCACHE_UMASK=007
    export CCACHE_DIR=/nix/var/cache/ccache
    export CACHEDIR=$(pwd)/tmp/cache
    export TEMPDIR=$(pwd)/tmp
    cp -r ${kpatch-build} kpatch-build
    kpb=$(pwd)/kpatch-build
    mkdir -p "$TEMPDIR" "$CACHEDIR"

    dirsBefore=""
    for candidate in *; do
      if [ -d "$candidate" ]; then
        dirsBefore="$dirsBefore $candidate "
      fi
    done
    tar xf ${kernel.src}
    sourceRoot=
    for candidate in *; do
      if [ -d "$candidate" ]; then
        case "$dirsBefore" in
          *\ $candidate\ *) ;;
          *)
            if [ -n "$sourceRoot" ]; then
              echo "unpacker produced multiple directories" >&2
              exit 1
            fi
            sourceRoot="$candidate"
            ;;
        esac
      fi
    done
    if [ -z "$sourceRoot" ]; then
      echo "unpacker produced no source directory" >&2
      exit 1
    fi

    mv "$sourceRoot" src
    export KERNEL_SRCDIR=$(pwd)/src
    cp -r ${kernel.dev}/. ./src/
    ln -snf ${kernel.configfile.outPath} ./src/.config
    cp ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/Module.symvers \
      ./src/Module.symvers
    cp ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/scripts/module.lds \
      ./src/scripts/module.lds
    patchShebangs src/scripts > /dev/null
    chmod u+w . -R
  ''
  + optionalString (zfsBuiltinPkg != null) ''
    cp -r ${zfsBuiltinPkg} ./zfsBuiltin
    chmod -R u+w ./zfsBuiltin
    pushd ./zfsBuiltin
    ./copy-builtin ../src
    popd
  '';

  buildLivePatchArtifact =
    { artifact, selectedRelease ? release, stdenv }:
    let
      moduleName = artifact.moduleName;
      installModPath = "${installModDir}/${moduleName}.ko";
      command =
        "$kpb/kpatch-build/kpatch-build -v ${kernel.dev}/vmlinux -s src "
        + "-n ${escapeShellArg moduleName} "
        + optionalString (artifact.nonReplace or false) "-R "
        + concatMapStrings (target: "-t ${escapeShellArg target} ") artifact.targets
        + concatMapStringsSep " " (name: "$src/${name}.patch") artifact.buildPatches;
    in
    stdenv.mkDerivation {
      name = "${moduleName}-${kernel.modDirVersion}";
      version = patchNameFor selectedRelease;
      src = patchesDir;

      hardeningDisable = [
        "bindnow"
        "format"
        "fortify"
        "stackprotector"
        "pic"
      ];
      # ELF tools do not recognize SHF_RELA_LIVEPATCH relocation sections.
      # Stripping can therefore renumber .symtab without updating the symbol
      # indices stored in those sections, corrupting the module at load time.
      dontStrip = true;
      depsBuildBuild = [ pkgs.stdenv.cc ];

      buildPhase = prepareKernelSource + ''
        cat > src/include/linux/vpsadminos-livepatch-build.h <<LIVEPATCH_HEADER_END
        ${livepatchBuildHeader artifact selectedRelease}
        LIVEPATCH_HEADER_END
        echo ${command}
        if ! ${command}; then
          cat "$CACHEDIR/build.log" || echo log not found at "$CACHEDIR/build.log"
          exit 1
        fi
      '';

      nativeBuildInputs = kernel.nativeBuildInputs;

      installPhase = ''
        mkdir -p "$out/${installModDir}"
        module_src=
        if [ -f "${moduleName}.ko" ]; then
          module_src="${moduleName}.ko"
        elif [ -f "tmp/cache/tmp/patch/${moduleName}.ko" ]; then
          module_src="tmp/cache/tmp/patch/${moduleName}.ko"
        else
          echo "live-patches: built module ${moduleName}.ko not found" >&2
          exit 1
        fi
        cp "$module_src" "$out/${installModPath}"
      '';
    };

  buildBootstrapArtifact =
    { bootstrap, selectedRelease ? release, stdenv }:
    let
      moduleName = bootstrap.moduleName;
      installModPath = "${installModDir}/${moduleName}.ko";
    in
    stdenv.mkDerivation {
      name = "${moduleName}-${kernel.modDirVersion}";
      version = patchNameFor selectedRelease;
      src = patchesDir;
      dontStrip = true;
      nativeBuildInputs = kernel.nativeBuildInputs;
      buildPhase = ''
        make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
          M="$PWD/${bootstrap.sourceDir}" modules
      '';
      installPhase = ''
        mkdir -p "$out/${installModDir}"
        cp ${bootstrap.sourceDir}/${moduleName}.ko "$out/${installModPath}"
      '';
    };

  builtArtifactsFor =
    selectedRelease:
    map (artifact: pkgs.callPackage buildLivePatchArtifact {
      inherit artifact selectedRelease;
    }) (artifactsFor selectedRelease);
  builtArtifactMapFor =
    selectedRelease:
    listToAttrs (
      map (artifact:
        nameValuePair artifact.moduleName (pkgs.callPackage buildLivePatchArtifact {
          inherit artifact selectedRelease;
        })
      ) (artifactsFor selectedRelease)
    );
  builtBootstrapsFor =
    selectedRelease:
    map (bootstrap: pkgs.callPackage buildBootstrapArtifact {
      inherit bootstrap selectedRelease;
    }) (bootstrapArtifactsFor selectedRelease);
  builtBootstrapMapFor =
    selectedRelease:
    listToAttrs (
      map (bootstrap:
        nameValuePair bootstrap.moduleName (pkgs.callPackage buildBootstrapArtifact {
          inherit bootstrap selectedRelease;
        })
      ) (bootstrapArtifactsFor selectedRelease)
    );
  patchesFor =
    selectedRelease:
    let
      artifactList = builtArtifactsFor selectedRelease;
      bootstrapList = builtBootstrapsFor selectedRelease;
      artifactMap = builtArtifactMapFor selectedRelease // builtBootstrapMapFor selectedRelease;
    in
    pkgs.symlinkJoin {
      name = "livepatches-${kernel.modDirVersion}-${patchNameFor selectedRelease}";
      paths = artifactList ++ bootstrapList;
      passthru = {
        artifacts = artifactMap;
        orderedArtifacts = artifactList;
        orderedBootstraps = bootstrapList;
      };
    };
  patches = patchesFor release;
  draftPatches =
    if structuredRelease && release ? drafts
    then mapAttrs (_: draft: patchesFor draft) release.drafts
    else { };

  moduleLoadGen =
    {
      moduleName,
      installModPath,
      recordApplied ? true,
    }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      if [ ! -d ${modDetectDir} ]; then
        echo live-patches: loading and applying ${moduleName}...
        if ! insmod ${installModPath}; then
          echo live-patches: loading and applying ${moduleName} FAILED
        fi
      fi
    ''
    + optionalString recordApplied ''
      if [ -f ${modDetectDir}/enabled ] && [ "$(cat ${modDetectDir}/enabled 2>/dev/null)" = "1" ]; then
        mkdir -p /run/vpsadminos/livepatches
        if [ ! -e /run/vpsadminos/livepatches/${moduleName}.applied-at ]; then
          date --utc +%Y-%m-%dT%H:%M:%SZ \
            > /run/vpsadminos/livepatches/${moduleName}.applied-at
        fi
      fi
    '';

  moduleWaitGen =
    {
      moduleName,
      timeoutSeconds ? 900,
    }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      retries=${toString (timeoutSeconds + 1)}
      while [ -d ${modDetectDir} ] && \
        [ "$(cat ${modDetectDir}/transition 2>/dev/null)" = "1" ] && \
        [ "$retries" -gt 0 ]; do
        if [ "$((retries % 30))" -eq 0 ]; then
          echo live-patches: waiting for ${moduleName} transition, "$retries" seconds remain
        fi
        retries=$((retries - 1))
        sleep 1
      done

      if [ ! -d ${modDetectDir} ] || \
        [ "$(cat ${modDetectDir}/enabled 2>/dev/null)" != "1" ] || \
        [ "$(cat ${modDetectDir}/transition 2>/dev/null)" != "0" ]; then
        echo live-patches: ${moduleName} transition FAILED
        exit 1
      fi
    '';

  transitionGuardEnableContent =
    optionalString (transitionGuard != null) ''
      # A disabled guard absorbed by a replacing patch cannot be re-enabled.
      # Wait out asynchronous livepatch cleanup and remove that stale module
      # before loading a fresh guard.
      if [ -d /sys/module/${guardModuleName} ] && \
        [ "$(cat /sys/kernel/livepatch/${guardModuleName}/enabled 2>/dev/null)" != "1" ]; then
        retries=151
        while [ -d /sys/module/${guardModuleName} ] && [ "$retries" -gt 0 ]; do
          rmmod ${guardModuleName} 2>/dev/null || true
          retries=$((retries - 1))
          if [ -d /sys/module/${guardModuleName} ]; then
            sleep 0.2
          fi
        done
        if [ -d /sys/module/${guardModuleName} ]; then
          echo live-patches: removing stale ${guardModuleName} FAILED
          exit 1
        fi
      fi
      ${optionalString (transitionBootstrap != null) ''
        transition_bootstrap_cleanup() {
          if [ -d /sys/module/${bootstrapModuleName} ]; then
            if ! rmmod ${bootstrapModuleName}; then
              echo live-patches: unloading ${bootstrapModuleName} FAILED
              return 1
            fi
          fi
          return 0
        }
        trap 'transition_bootstrap_cleanup || true' EXIT

        if [ ! -d /sys/module/${bootstrapModuleName} ]; then
          echo live-patches: loading ${bootstrapModuleName}...
          if ! insmod "$livepatch/${bootstrapInstallModPath}"; then
            echo live-patches: loading ${bootstrapModuleName} FAILED
            exit 1
          fi
        fi
      ''}
      ${moduleLoadGen {
        installModPath = "$livepatch/${guardInstallModPath}";
        moduleName = guardModuleName;
        recordApplied = false;
      }}
      ${optionalString (transitionBootstrap != null) ''
        if [ ! -d /sys/kernel/livepatch/${guardModuleName} ]; then
          echo live-patches: loading and applying ${guardModuleName} FAILED
          exit 1
        fi
      ''}
      if [ "$(cat /sys/kernel/livepatch/${guardModuleName}/enabled 2>/dev/null)" != "1" ]; then
        echo 1 > /sys/kernel/livepatch/${guardModuleName}/enabled 2>/dev/null || {
          echo live-patches: enabling ${guardModuleName} FAILED
          exit 1
        }
      fi
      ${optionalString (transitionBootstrap != null) ''
        if [ "$(cat /sys/kernel/livepatch/${guardModuleName}/transition 2>/dev/null)" = "1" ]; then
          if ! echo 1 > \
            /sys/module/${bootstrapModuleName}/parameters/${transitionBootstrap.kickParameter}; then
            echo live-patches: ${bootstrapModuleName} idle-task bootstrap FAILED
            exit 1
          fi
        fi
      ''}
      ${moduleWaitGen { moduleName = guardModuleName; }}
    '';

  moduleUnloadGen =
    {
      moduleName,
      timeoutSeconds ? 90,
    }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      if [ -d ${modDetectDir} ] && [ -f ${modDetectDir}/enabled ]; then
        echo -en live-patches: disabling ${moduleName}..
        if ! echo 0 > ${modDetectDir}/enabled 2>/dev/null; then
          echo -e "\nlive-patches: disabling ${moduleName}... FAILED"
          exit 1
        fi
        retries=${toString (timeoutSeconds + 1)}
        while [ -d ${modDetectDir} ] && [ $retries -gt 0 ]; do
          if [ "$(( $retries % 5 ))" -eq 0 ]; then
            echo -en " $retries "
          fi
          transition=$(cat ${modDetectDir}/transition 2>/dev/null)
          if [ "$transition" -eq 1 ] 2>/dev/null; then
            echo -en .
          else
            echo -en ?
          fi
          retries=$(( $retries - 1 ))
          sleep 1
        done
        echo
      fi
      retries=13
      if [ -d /sys/module/${moduleName} ]; then
        echo -en live-patches: unloading ${moduleName}..
        while [ -d /sys/module/${moduleName} ] && [ $retries -gt 0 ]; do
          if [ "$(( $retries % 3 ))" -eq 0 ]; then
            echo -en " $retries "
          fi
          echo -en .
          retries=$(( $retries - 1 ))
          if ! rmmod ${moduleName} 2>/dev/null; then
            sleep 0.2
          fi
          if [ "$retries" -eq 0 ]; then
            echo -en "\nlive-patches: unloading ${moduleName}... FAILED"
          fi
        done
        echo
      fi
      if [ -d /sys/module/${moduleName} ]; then
        echo live-patches: unloading ${moduleName}... FAILED
        exit 1
      fi
      rm -f /run/vpsadminos/livepatches/${moduleName}.applied-at
    '';

  moduleListGen =
    { moduleName }:
    let
      modDetectDir = "/sys/kernel/livepatch/${moduleName}";
    in
    ''
      s="["
      if [ -d /sys/module/${moduleName} ]; then
        s="$s loaded";
        if [ -f ${modDetectDir}/enabled ] && \
           [ "$(cat ${modDetectDir}/enabled 2>/dev/null)" == "1" ]; then
          s="$s enabled"
        fi
        if [ "$(cat ${modDetectDir}/transition 2>/dev/null)" == "1" ]; then
          s="$s transition"
        fi
      else
        s="$s unloaded"
      fi
      printf "%-27s%s\n" "$s" " ] ${moduleName}"
    '';

  moduleStatusGen =
    { moduleName }:
    moduleListGen { inherit moduleName; }
    + foldl (x: y: "${x}\n${y}") "\n" (
      map (
        patch:
        let
          pVer = availablePatches.getPatchVersion patch;
        in
        "printf '%29s %s\n' 'contains:' '${patch.name}"
        + optionalString (pVer > 1) "(v${toString pVer})"
        + "'"
      ) availablePatches.filteredPatches
    );

  moduleLoadContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
    mkdir -p /lib/modules
    ln -snf /run/current-system/kernel-modules/lib/modules/${kernel.modDirVersion} /lib/modules/${kernel.modDirVersion}.${patchName}
  ''
  + optionalString (transitionGuard != null) ''
    if [ ! -d /sys/kernel/livepatch/${patchModuleName} ]; then
      ${transitionGuardEnableContent}
    fi
  ''
  + moduleLoadGen {
    installModPath = "$livepatch/${installModPath}";
    moduleName = patchModuleName;
    recordApplied = transitionGuard == null;
  }
  + optionalString (transitionGuard != null) ''
    ${moduleWaitGen { moduleName = patchModuleName; }}
    mkdir -p /run/vpsadminos/livepatches
    if [ ! -e /run/vpsadminos/livepatches/${patchModuleName}.applied-at ]; then
      date --utc +%Y-%m-%dT%H:%M:%SZ \
        > /run/vpsadminos/livepatches/${patchModuleName}.applied-at
    fi
    retries=151
    while [ -d /sys/module/${guardModuleName} ] && [ "$retries" -gt 0 ]; do
      rmmod ${guardModuleName} 2>/dev/null || true
      retries=$((retries - 1))
      if [ -d /sys/module/${guardModuleName} ]; then
        sleep 0.2
      fi
    done
    if [ -d /sys/module/${guardModuleName} ]; then
      echo live-patches: unloading absorbed ${guardModuleName} FAILED
      exit 1
    fi
    rm -f /run/vpsadminos/livepatches/${guardModuleName}.applied-at
  ''
  + "";

  moduleUnloadContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
    # Patches built with build-kpatch
  ''
  + optionalString (transitionGuard != null) ''
    # Keep the corrected transition functions above the cumulative patch for
    # its entire reverse transition.  The minimal guard is removed last.
    if [ -d /sys/kernel/livepatch/${patchModuleName} ] && \
      [ "$(cat /sys/kernel/livepatch/${patchModuleName}/enabled 2>/dev/null)" = "1" ]; then
      ${transitionGuardEnableContent}
    fi
  ''
  + moduleUnloadGen {
    moduleName = patchModuleName;
    timeoutSeconds = if transitionGuard == null then 90 else 900;
  }
  + optionalString (transitionGuard != null) (moduleUnloadGen {
    moduleName = guardModuleName;
    timeoutSeconds = 900;
  })
  + "\n";

  moduleListContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  ''
  + optionalString (transitionGuard != null) (moduleListGen {
    moduleName = guardModuleName;
  })
  + moduleListGen { moduleName = patchModuleName; }
  + "\n";

  moduleStatusContent = ''
    livepatch=$(cat /etc/livepatch-store-path)
  ''
  + optionalString (transitionGuard != null) (moduleListGen {
    moduleName = guardModuleName;
  })
  + moduleStatusGen { moduleName = patchModuleName; }
  + "\n";

  artifactInstallPath = artifact:
    "${installModDir}/${artifact.moduleName}.ko";

  declaredArtifactIntegrityGen = artifact:
    let
      expectedSha256 = artifact.expectedSha256 or null;
      installPath = artifactInstallPath artifact;
    in
    if expectedSha256 == null then ''
      echo "live-patches: ${artifact.moduleName} has no frozen SHA-256" >&2
      exit 1
    '' else ''
      artifact_file="$livepatch/${installPath}"
      if [ ! -f "$artifact_file" ]; then
        echo "live-patches: missing ${artifact.moduleName} artifact" >&2
        exit 1
      fi
      artifact_sha=$(${pkgs.coreutils}/bin/sha256sum "$artifact_file")
      artifact_sha=''${artifact_sha%% *}
      if [ "$artifact_sha" != ${escapeShellArg expectedSha256} ]; then
        echo "live-patches: ${artifact.moduleName} SHA-256 mismatch" >&2
        exit 1
      fi
      artifact_vermagic=$(${pkgs.kmod}/bin/modinfo -F vermagic "$artifact_file")
      case "$artifact_vermagic" in
        ${kernel.modDirVersion}\ *) ;;
        *)
          echo "live-patches: ${artifact.moduleName} vermagic mismatch" >&2
          exit 1
          ;;
      esac
    '';

  declaredBootstrapIntegrityGen = bootstrap:
    let
      expectedSha256 = bootstrap.expectedSha256 or null;
      installPath = "${installModDir}/${bootstrap.moduleName}.ko";
    in
    if expectedSha256 == null then ''
      echo "live-patches: ${bootstrap.moduleName} has no frozen SHA-256" >&2
      exit 1
    '' else ''
      bootstrap_file="$livepatch/${installPath}"
      if [ ! -f "$bootstrap_file" ]; then
        echo "live-patches: missing ${bootstrap.moduleName} artifact" >&2
        exit 1
      fi
      bootstrap_sha=$(${pkgs.coreutils}/bin/sha256sum "$bootstrap_file")
      bootstrap_sha=''${bootstrap_sha%% *}
      if [ "$bootstrap_sha" != ${escapeShellArg expectedSha256} ]; then
        echo "live-patches: ${bootstrap.moduleName} SHA-256 mismatch" >&2
        exit 1
      fi
      bootstrap_vermagic=$(${pkgs.kmod}/bin/modinfo -F vermagic "$bootstrap_file")
      case "$bootstrap_vermagic" in
        ${kernel.modDirVersion}\ *) ;;
        *)
          echo "live-patches: ${bootstrap.moduleName} vermagic mismatch" >&2
          exit 1
          ;;
      esac
    '';

  exactArtifactWaitGen = artifact:
    let
      moduleName = artifact.moduleName;
      detectDir = "/sys/kernel/livepatch/${moduleName}";
    in ''
      transition_deadline=$((SECONDS + 900))
      transition_checkpoint=$((SECONDS + 15))
      while [ -d ${detectDir} ] && \
        [ "$(cat ${detectDir}/transition 2>/dev/null)" = 1 ]; do
        if [ "$SECONDS" -ge "$transition_checkpoint" ]; then
          printf 'live-patches: %s transition elapsed=%ss enabled=%s transition=%s\n' \
            ${escapeShellArg moduleName} "$((900 - (transition_deadline - SECONDS)))" \
            "$(cat ${detectDir}/enabled 2>/dev/null || echo missing)" \
            "$(cat ${detectDir}/transition 2>/dev/null || echo missing)"
          if [ -r /sys/module/${moduleName}/parameters/transition_progress ]; then
            head -c 4096 /sys/module/${moduleName}/parameters/transition_progress
            printf '\n'
          fi
          transition_checkpoint=$((SECONDS + 15))
        fi
        if [ "$SECONDS" -ge "$transition_deadline" ]; then
          echo "live-patches: ${moduleName} transition exceeded 900 seconds" >&2
          exit 1
        fi
        sleep 1
      done
      if [ ! -d ${detectDir} ] || \
        [ "$(cat ${detectDir}/enabled 2>/dev/null)" != 1 ] || \
        [ "$(cat ${detectDir}/transition 2>/dev/null)" != 0 ]; then
        echo "live-patches: ${moduleName} did not reach enabled complete state" >&2
        exit 1
      fi
      if [ "$(cat ${detectDir}/replace 2>/dev/null)" != \
        ${if artifact.nonReplace or false then "0" else "1"} ]; then
        echo "live-patches: ${moduleName} replacement role mismatch" >&2
        exit 1
      fi
    '';

  exactArtifactLoadGen = artifact: ''
    if [ -d /sys/module/${artifact.moduleName} ] && \
      [ ! -d /sys/kernel/livepatch/${artifact.moduleName} ]; then
      echo "live-patches: stale ${artifact.moduleName} module is loaded" >&2
      exit 1
    fi
    if [ ! -d /sys/kernel/livepatch/${artifact.moduleName} ]; then
      echo "live-patches: loading ${artifact.role} ${artifact.moduleName}"
      if ! insmod "$livepatch/${artifactInstallPath artifact}"; then
        echo "live-patches: insertion of ${artifact.moduleName} failed" >&2
        exit 1
      fi
    fi
    ${exactArtifactWaitGen artifact}
  '';

  structuredListGen = artifact: ''
    printf '%-24s %-20s enabled=%s transition=%s replace=%s\n' \
      ${escapeShellArg artifact.moduleName} ${escapeShellArg artifact.role} \
      "$(cat /sys/kernel/livepatch/${artifact.moduleName}/enabled 2>/dev/null || echo absent)" \
      "$(cat /sys/kernel/livepatch/${artifact.moduleName}/transition 2>/dev/null || echo absent)" \
      "$(cat /sys/kernel/livepatch/${artifact.moduleName}/replace 2>/dev/null || echo absent)"
  '';

  expectedPatchInventory = moduleNames: concatStringsSep "\n" (sort builtins.lessThan moduleNames);

  activePatchInventoryGen = ''
    active_patches=$(find /sys/kernel/livepatch -mindepth 1 -maxdepth 1 \
      -type d -printf '%f\n' 2>/dev/null | sort)
  '';

  onlineAnchors =
    if multiAnchorRelease then attrValues release.onlineAnchors else [ ];
  onlineArtifactsForAnchor = anchor: pathArtifactsFor release anchor.path;
  onlineFirstArtifact =
    anchor:
    let
      artifacts = onlineArtifactsForAnchor anchor;
    in
    if artifacts == [ ] then null else elemAt artifacts 0;
  onlineSecondArtifact =
    anchor:
    let
      artifacts = onlineArtifactsForAnchor anchor;
    in
    if length artifacts > 1 then elemAt artifacts 1 else null;
  onlineRemainingArtifacts =
    anchor:
    let
      artifacts = onlineArtifactsForAnchor anchor;
    in
    if length artifacts > 2 then sublist 2 (length artifacts - 2) artifacts else [ ];
  onlineBootstrapForAnchor =
    anchor:
    let
      firstArtifact = onlineFirstArtifact anchor;
    in
    if firstArtifact != null && firstArtifact ? bootstrap then firstArtifact.bootstrap else null;
  onlineFinalArtifact =
    anchor:
    let
      artifacts = onlineArtifactsForAnchor anchor;
    in
    if artifacts == [ ] then null else last artifacts;
  onlineActiveIdentity =
    anchor:
    if anchor ? activeIdentity then anchor.activeIdentity else anchor.publishedIdentity or null;
  onlineActiveInventoryNames =
    anchor:
    if anchor ? activeInventory then anchor.activeInventory else optional (anchor ? moduleName) anchor.moduleName;
  onlineExpectedInventoryNames =
    anchor:
    if anchor ? expectedInventory
    then anchor.expectedInventory
    else throw "live-patches: online anchor ${anchor.path} missing expectedInventory";
  onlineActiveArtifacts = anchor: anchor.activeArtifacts or [ ];
  onlineActiveInventory = anchor: expectedPatchInventory (onlineActiveInventoryNames anchor);
  onlineExpectedInventory = anchor: expectedPatchInventory (onlineExpectedInventoryNames anchor);
  onlineFinalIdentity =
    anchor:
    let
      finalArtifact = onlineFinalArtifact anchor;
    in
    if finalArtifact == null
    then throw "live-patches: online anchor ${anchor.path} has no final artifact"
    else finalArtifact.publishedIdentity or null;
  onlineCommonPreflightContent = ''
    ${noActiveTransitionGen}
    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" != 1 ]; then
      echo "live-patches: kdump is unavailable" >&2
      exit 1
    fi
    cpu_count=$(getconf _NPROCESSORS_ONLN)
    thread_count=$(find /proc -mindepth 3 -maxdepth 3 -type d \
      -path '/proc/[0-9]*/task/[0-9]*' 2>/dev/null | wc -l)
    mem_available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    if [ "$cpu_count" -gt 128 ] || [ "$thread_count" -gt 100000 ] || \
      [ "$mem_available" -lt 2097152 ]; then
      echo "live-patches: host is outside the qualified resource envelope" >&2
      exit 1
    fi
    cpu_vendor=$(awk -F ': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)
    case "$cpu_vendor" in GenuineIntel|AuthenticAMD) ;; *)
      echo "live-patches: unsupported CPU vendor $cpu_vendor" >&2
      exit 1
    esac
  '';
  activeAnchorArtifactCheckGen =
    artifact:
    let
      moduleDir = "/sys/kernel/livepatch/${artifact.moduleName}";
    in
    ''
      if [ ! -d ${moduleDir} ]; then
        echo "live-patches: required active anchor artifact ${artifact.moduleName} is absent" >&2
        exit 1
      fi
      if [ "$(cat ${moduleDir}/enabled 2>/dev/null)" != 1 ] || \
        [ "$(cat ${moduleDir}/transition 2>/dev/null)" != 0 ]; then
        echo "live-patches: active anchor artifact ${artifact.moduleName} is not mechanically complete" >&2
        exit 1
      fi
      ${optionalString (artifact ? replace) ''
        if [ "$(cat ${moduleDir}/replace 2>/dev/null)" != ${if artifact.replace then "1" else "0"} ]; then
          echo "live-patches: active anchor artifact ${artifact.moduleName} replacement role mismatch" >&2
          exit 1
        fi
      ''}
      ${optionalString (artifact ? replacementCount) ''
        anchor_functions=$(find ${moduleDir} -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
        if [ "$anchor_functions" -ne ${toString artifact.replacementCount} ]; then
          echo "live-patches: active anchor artifact ${artifact.moduleName} replacement inventory mismatch" >&2
          exit 1
        fi
      ''}
      ${optionalString (artifact ? moduleFile && artifact ? moduleSha256) ''
        anchor_sha=$(${pkgs.coreutils}/bin/sha256sum ${escapeShellArg artifact.moduleFile})
        anchor_sha=''${anchor_sha%% *}
        if [ "$anchor_sha" != ${escapeShellArg artifact.moduleSha256} ]; then
          echo "live-patches: active anchor artifact ${artifact.moduleName} SHA-256 mismatch" >&2
          exit 1
        fi
      ''}
      ${optionalString (artifact ? moduleFile && artifact ? moduleBuildId) ''
        anchor_build_id=$(${pkgs.binutils}/bin/readelf -n ${escapeShellArg artifact.moduleFile} | \
          sed -n 's/^[[:space:]]*Build ID: //p' | head -n 1)
        if [ "$anchor_build_id" != ${escapeShellArg artifact.moduleBuildId} ]; then
          echo "live-patches: active anchor artifact ${artifact.moduleName} build ID mismatch" >&2
          exit 1
        fi
      ''}
    '';
  onlineCompleteCheckContentFor =
    anchor:
    let
      artifacts = onlineArtifactsForAnchor anchor;
      bootstrap = onlineBootstrapForAnchor anchor;
      finalArtifact = onlineFinalArtifact anchor;
    in
    ''
      ${activePatchInventoryGen}
      if [ "$active_patches" != ${escapeShellArg (onlineExpectedInventory anchor)} ]; then
        echo "live-patches: unexpected livepatch inventory: $active_patches" >&2
        exit 1
      fi
      ${optionalString (bootstrap != null) ''
        if [ -d /sys/module/${bootstrap.moduleName} ]; then
          echo "live-patches: stale bootstrap helper is loaded" >&2
          exit 1
        fi
      ''}
      ${concatMapStrings activeAnchorArtifactCheckGen (onlineActiveArtifacts anchor)}
      ${concatMapStrings exactArtifactWaitGen artifacts}
      if [ "$(uname -r)" != ${escapeShellArg (onlineFinalIdentity anchor)} ]; then
        echo "live-patches: final release identity is not active" >&2
        exit 1
      fi
      if [ "$(cat /sys/module/${finalArtifact.moduleName}/parameters/generation_active 2>/dev/null)" != 1 ] || \
        [ "$(cat /sys/module/${finalArtifact.moduleName}/parameters/generation_complete 2>/dev/null)" != 1 ]; then
        echo "live-patches: coverage generation is incomplete" >&2
        exit 1
      fi
    '';
  onlinePreflightContentFor =
    anchor:
    let
      bootstrap = onlineBootstrapForAnchor anchor;
    in
    ''
      if [ "$(uname -r)" != ${escapeShellArg (onlineActiveIdentity anchor)} ]; then
        echo "live-patches: exact anchor identity is not active" >&2
        exit 1
      fi
      ${optionalString (anchor ? isolationMarker) ''
        if [ ! -e ${escapeShellArg anchor.isolationMarker} ]; then
          echo "live-patches: remediation isolation marker is absent" >&2
          exit 1
        fi
      ''}
      ${optionalString (anchor ? allowedBootBzImageSha256 && anchor ? allowedSystemMapSha256) (
        bootIdentityCheckGen anchor
      )}
      ${activePatchInventoryGen}
      if [ "$active_patches" != ${escapeShellArg (onlineActiveInventory anchor)} ]; then
        echo "live-patches: unexpected livepatch inventory: $active_patches" >&2
        exit 1
      fi
      ${optionalString (bootstrap != null) ''
        if [ -d /sys/module/${bootstrap.moduleName} ]; then
          echo "live-patches: stale bootstrap helper is loaded" >&2
          exit 1
        fi
      ''}
      ${concatMapStrings activeAnchorArtifactCheckGen (onlineActiveArtifacts anchor)}
      ${onlineCommonPreflightContent}
      ${concatMapStrings declaredArtifactIntegrityGen (onlineArtifactsForAnchor anchor)}
      ${optionalString (bootstrap != null) (
        declaredBootstrapIntegrityGen bootstrap
      )}
    '';
  onlineLoadContentFor =
    anchor:
    let
      firstArtifact = onlineFirstArtifact anchor;
      secondArtifact = onlineSecondArtifact anchor;
      remainingArtifacts = onlineRemainingArtifacts anchor;
      bootstrap = onlineBootstrapForAnchor anchor;
      finalArtifact = onlineFinalArtifact anchor;
    in
    ''
      livepatch=$(cat /etc/livepatch-store-path)
      ${onlinePreflightContentFor anchor}
      ${moduleAliasContent}
      ${optionalString (bootstrap != null) ''
        echo "live-patches: loading exceptional bootstrap helper"
        if ! insmod "$livepatch/${installModDir}/${bootstrap.moduleName}.ko"; then
          echo "live-patches: bootstrap helper insertion failed" >&2
          exit 1
        fi
      ''}
      ${optionalString (firstArtifact != null) (
        if bootstrap != null then ''
          echo "live-patches: loading ${firstArtifact.role} ${firstArtifact.moduleName}"
          if ! insmod "$livepatch/${artifactInstallPath firstArtifact}"; then
            echo "live-patches: insertion of ${firstArtifact.moduleName} failed" >&2
            exit 1
          fi
          if [ "$(cat /sys/kernel/livepatch/${firstArtifact.moduleName}/transition 2>/dev/null)" = 1 ]; then
            echo 1 > /sys/module/${bootstrap.moduleName}/parameters/${bootstrap.kickParameter}
          fi
          ${exactArtifactWaitGen firstArtifact}
        '' else ''
          ${exactArtifactLoadGen firstArtifact}
        ''
      )}
      ${optionalString (secondArtifact != null) (
        if bootstrap != null then ''
          ${exactArtifactLoadGen secondArtifact}
          ${moduleRemovalGen bootstrap.moduleName}
        '' else ""
      )}
      ${optionalString (bootstrap != null && secondArtifact == null) (
        moduleRemovalGen bootstrap.moduleName
      )}
      ${concatMapStrings exactArtifactLoadGen remainingArtifacts}
      ${onlineCompleteCheckContentFor anchor}
      mkdir -p /run/vpsadminos/livepatches
      date --utc +%Y-%m-%dT%H:%M:%SZ > \
        /run/vpsadminos/livepatches/${finalArtifact.moduleName}.applied-at
    '';

  noActiveTransitionGen = ''
    for transition_file in /sys/kernel/livepatch/*/transition; do
      [ -e "$transition_file" ] || continue
      if [ "$(cat "$transition_file")" = 1 ]; then
        echo "live-patches: another livepatch transition is active" >&2
        exit 1
      fi
    done
  '';

  moduleAliasContent = ''
    mkdir -p /lib/modules
    ln -snf /run/current-system/kernel-modules/lib/modules/${kernel.modDirVersion} \
      /lib/modules/${kernel.modDirVersion}.${patchName}
  '';

  moduleRemovalGen = moduleName: ''
    retries=151
    while [ -d /sys/module/${moduleName} ] && [ "$retries" -gt 0 ]; do
      rmmod ${moduleName} 2>/dev/null || true
      retries=$((retries - 1))
      if [ -d /sys/module/${moduleName} ]; then
        sleep 0.2
      fi
    done
    if [ -d /sys/module/${moduleName} ]; then
      echo "live-patches: unloading ${moduleName} FAILED" >&2
      exit 1
    fi
  '';

  bootIdentityCheckGen = anchor: ''
    boot_kernel=$(readlink -f /run/booted-system/kernel)
    boot_sha=$(${pkgs.coreutils}/bin/sha256sum "$boot_kernel")
    boot_sha=''${boot_sha%% *}
    case "$boot_sha" in
      ${concatStringsSep "|" anchor.allowedBootBzImageSha256}) ;;
      *)
        echo "live-patches: boot bzImage is outside the qualified anchor" >&2
        exit 1
        ;;
    esac
    boot_map="$(dirname "$boot_kernel")/System.map"
    map_sha=$(${pkgs.coreutils}/bin/sha256sum "$boot_map")
    map_sha=''${map_sha%% *}
    case "$map_sha" in
      ${concatStringsSep "|" anchor.allowedSystemMapSha256}) ;;
      *)
        echo "live-patches: System.map is outside the qualified anchor" >&2
        exit 1
        ;;
    esac
  '';

  correctiveAnchor =
    if structuredRelease && release ? anchors then release.anchors.v6Remediation or null else null;
  correctiveArtifacts =
    if correctiveAnchor != null then pathArtifactsFor release correctiveAnchor.path else [ ];
  correctiveGuard = if correctiveArtifacts == [ ] then null else elemAt correctiveArtifacts 0;
  correctiveFoundation = if length correctiveArtifacts < 2 then null else elemAt correctiveArtifacts 1;
  correctiveFinal = if length correctiveArtifacts < 3 then null else elemAt correctiveArtifacts 2;
  correctiveExpectedInventory =
    if correctiveArtifacts == [ ]
    then ""
    else expectedPatchInventory (map (artifact: artifact.moduleName) correctiveArtifacts);
  correctiveBootstrap =
    if correctiveGuard != null && correctiveGuard ? bootstrap
    then correctiveGuard.bootstrap
    else null;
  hasCorrectivePath =
    structuredRelease
    && correctiveAnchor != null
    && correctiveGuard != null
    && correctiveFoundation != null
    && correctiveFinal != null
    && correctiveBootstrap != null;
  checkpointBootAnchor =
    if structuredRelease && release ? anchors then release.anchors.cleanBoot or null else null;
  checkpointBootArtifacts =
    if checkpointBootAnchor != null then pathArtifactsFor release checkpointBootAnchor.path else [ ];
  checkpointGuard =
    if checkpointBootArtifacts == [ ] then null else elemAt checkpointBootArtifacts 0;
  checkpointBootstrap =
    if checkpointGuard != null && checkpointGuard ? bootstrap
    then checkpointGuard.bootstrap
    else null;
  checkpointCompleteAnchor =
    if structuredRelease && release ? anchors then release.anchors.checkpointComplete or null else null;
  reverseValidationArtifacts =
    if checkpointCompleteAnchor != null then pathArtifactsFor release checkpointCompleteAnchor.path else [ ];
  reverseValidationGuard =
    if reverseValidationArtifacts == [ ] then null else elemAt reverseValidationArtifacts 0;
  reverseValidationBootstrap =
    if reverseValidationGuard != null && reverseValidationGuard ? bootstrap
    then reverseValidationGuard.bootstrap
    else null;
  hasCheckpointPath =
    structuredRelease
    && checkpointArtifact != null
    && checkpointBootAnchor != null
    && checkpointGuard != null
    && checkpointBootstrap != null
    && checkpointCompleteAnchor != null;
  hasReverseValidationPath =
    hasCheckpointPath
    && reverseValidationGuard != null
    && reverseValidationBootstrap != null;
  checkpointExpectedInventory =
    if checkpointArtifact == null then "" else checkpointArtifact.moduleName;

  correctiveCompleteCheckContent = optionalString hasCorrectivePath ''
    ${activePatchInventoryGen}
    if [ "$active_patches" != ${escapeShellArg correctiveExpectedInventory} ]; then
      echo "live-patches: unexpected livepatch inventory: $active_patches" >&2
      exit 1
    fi
    if [ -d /sys/module/${correctiveBootstrap.moduleName} ]; then
      echo "live-patches: stale bootstrap helper is loaded" >&2
      exit 1
    fi
    ${exactArtifactWaitGen correctiveGuard}
    ${exactArtifactWaitGen correctiveFoundation}
    ${exactArtifactWaitGen correctiveFinal}
    if [ "$(uname -r)" != ${escapeShellArg correctiveFinal.publishedIdentity} ]; then
      echo "live-patches: final release identity is not active" >&2
      exit 1
    fi
    if [ "$(cat /sys/module/${correctiveFinal.moduleName}/parameters/generation_active 2>/dev/null)" != 1 ] || \
      [ "$(cat /sys/module/${correctiveFinal.moduleName}/parameters/generation_complete 2>/dev/null)" != 1 ]; then
      echo "live-patches: corrective coverage generation is incomplete" >&2
      exit 1
    fi
  '';

  checkpointCompleteCheckContent = optionalString hasCheckpointPath ''
    ${activePatchInventoryGen}
    if [ "$active_patches" != ${escapeShellArg checkpointExpectedInventory} ]; then
      echo "live-patches: unexpected livepatch inventory: $active_patches" >&2
      exit 1
    fi
    if [ -d /sys/module/${checkpointBootstrap.moduleName} ]; then
      echo "live-patches: stale checkpoint bootstrap helper is loaded" >&2
      exit 1
    fi
    if [ -d /sys/module/${checkpointGuard.moduleName} ]; then
      echo "live-patches: stale checkpoint guard module is loaded" >&2
      exit 1
    fi
    ${exactArtifactWaitGen checkpointArtifact}
    if [ "$(uname -r)" != ${escapeShellArg checkpointCompleteAnchor.publishedIdentity} ]; then
      echo "live-patches: checkpoint release identity is not active" >&2
      exit 1
    fi
    if [ "$(cat /sys/module/${checkpointArtifact.moduleName}/parameters/generation_active 2>/dev/null)" != 1 ] || \
      [ "$(cat /sys/module/${checkpointArtifact.moduleName}/parameters/generation_complete 2>/dev/null)" != 1 ]; then
      echo "live-patches: checkpoint coverage generation is incomplete" >&2
      exit 1
    fi
  '';

  correctivePreflightContent = optionalString hasCorrectivePath ''
    if [ "$(uname -r)" != ${escapeShellArg correctiveAnchor.publishedIdentity} ]; then
      echo "live-patches: exact v6 remediation identity is not active" >&2
      exit 1
    fi
    if [ ! -e ${escapeShellArg correctiveAnchor.isolationMarker} ]; then
      echo "live-patches: v6 workload-isolation marker is absent" >&2
      exit 1
    fi

    ${bootIdentityCheckGen correctiveAnchor}

    ${activePatchInventoryGen}
    if [ "$active_patches" != ${escapeShellArg correctiveAnchor.moduleName} ]; then
      echo "live-patches: unexpected livepatch inventory: $active_patches" >&2
      exit 1
    fi
    anchor_dir=/sys/kernel/livepatch/${correctiveAnchor.moduleName}
    if [ "$(cat "$anchor_dir/enabled" 2>/dev/null)" != 1 ] || \
      [ "$(cat "$anchor_dir/transition" 2>/dev/null)" != 0 ] || \
      [ "$(cat "$anchor_dir/replace" 2>/dev/null)" != \
        ${if correctiveAnchor.replace then "1" else "0"} ]; then
      echo "live-patches: v6 anchor is not mechanically complete" >&2
      exit 1
    fi
    anchor_functions=$(find "$anchor_dir" -mindepth 2 -maxdepth 2 \
      -type d 2>/dev/null | wc -l)
    if [ "$anchor_functions" -ne ${toString correctiveAnchor.replacementCount} ]; then
      echo "live-patches: v6 replacement inventory mismatch" >&2
      exit 1
    fi
    anchor_sha=$(${pkgs.coreutils}/bin/sha256sum \
      ${escapeShellArg correctiveAnchor.moduleFile})
    anchor_sha=''${anchor_sha%% *}
    if [ "$anchor_sha" != ${escapeShellArg correctiveAnchor.moduleSha256} ]; then
      echo "live-patches: v6 module SHA-256 mismatch" >&2
      exit 1
    fi
    anchor_build_id=$(${pkgs.binutils}/bin/readelf -n \
      ${escapeShellArg correctiveAnchor.moduleFile} | \
      sed -n 's/^[[:space:]]*Build ID: //p' | head -n 1)
    if [ "$anchor_build_id" != ${escapeShellArg correctiveAnchor.moduleBuildId} ]; then
      echo "live-patches: v6 module build ID mismatch" >&2
      exit 1
    fi
    if [ -d /sys/module/${correctiveBootstrap.moduleName} ]; then
      echo "live-patches: stale bootstrap helper is loaded" >&2
      exit 1
    fi
    ${noActiveTransitionGen}
    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" != 1 ]; then
      echo "live-patches: kdump is unavailable" >&2
      exit 1
    fi
    cpu_count=$(getconf _NPROCESSORS_ONLN)
    thread_count=$(find /proc -mindepth 3 -maxdepth 3 -type d \
      -path '/proc/[0-9]*/task/[0-9]*' 2>/dev/null | wc -l)
    mem_available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    if [ "$cpu_count" -gt 128 ] || [ "$thread_count" -gt 100000 ] || \
      [ "$mem_available" -lt 2097152 ]; then
      echo "live-patches: host is outside the qualified resource envelope" >&2
      exit 1
    fi
    cpu_vendor=$(awk -F ': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)
    case "$cpu_vendor" in GenuineIntel|AuthenticAMD) ;; *)
      echo "live-patches: unsupported CPU vendor $cpu_vendor" >&2
      exit 1
    esac

    ${concatMapStrings declaredArtifactIntegrityGen correctiveArtifacts}
    ${optionalString (correctiveBootstrap != null) (
      declaredBootstrapIntegrityGen correctiveBootstrap
    )}
  '';

  checkpointPreflightContent = optionalString hasCheckpointPath ''
    if [ "$(uname -r)" != ${escapeShellArg checkpointBootAnchor.publishedIdentity} ]; then
      echo "live-patches: clean boot identity is not active" >&2
      exit 1
    fi

    ${bootIdentityCheckGen checkpointBootAnchor}

    ${activePatchInventoryGen}
    if [ -n "$active_patches" ]; then
      echo "live-patches: clean checkpoint path requires an empty livepatch stack" >&2
      exit 1
    fi
    if [ -d /sys/module/${checkpointBootstrap.moduleName} ]; then
      echo "live-patches: stale checkpoint bootstrap helper is loaded" >&2
      exit 1
    fi
    if [ -d /sys/module/${checkpointGuard.moduleName} ]; then
      echo "live-patches: stale checkpoint guard module is loaded" >&2
      exit 1
    fi
    ${noActiveTransitionGen}
    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" != 1 ]; then
      echo "live-patches: kdump is unavailable" >&2
      exit 1
    fi

    ${declaredArtifactIntegrityGen checkpointGuard}
    ${declaredArtifactIntegrityGen checkpointArtifact}
    ${optionalString (checkpointBootstrap != null) (
      declaredBootstrapIntegrityGen checkpointBootstrap
    )}
  '';

  correctiveLoadContent = optionalString hasCorrectivePath ''
    livepatch=$(cat /etc/livepatch-store-path)
    if [ "$(uname -r)" = ${escapeShellArg correctiveFinal.publishedIdentity} ]; then
      ${correctiveCompleteCheckContent}
      exit 0
    fi

    ${correctivePreflightContent}
    ${moduleAliasContent}

    echo "live-patches: loading exceptional bootstrap helper"
    if ! insmod "$livepatch/${installModDir}/${correctiveBootstrap.moduleName}.ko"; then
      echo "live-patches: bootstrap helper insertion failed" >&2
      exit 1
    fi
    echo "live-patches: loading bootstrap guard ${correctiveGuard.moduleName}"
    if ! insmod "$livepatch/${artifactInstallPath correctiveGuard}"; then
      echo "live-patches: bootstrap guard insertion failed" >&2
      exit 1
    fi
    if [ "$(cat /sys/kernel/livepatch/${correctiveGuard.moduleName}/transition 2>/dev/null)" = 1 ]; then
      echo 1 > /sys/module/${correctiveBootstrap.moduleName}/parameters/${correctiveBootstrap.kickParameter}
    fi
    ${exactArtifactWaitGen correctiveGuard}
    ${exactArtifactLoadGen correctiveFoundation}
    ${moduleRemovalGen correctiveBootstrap.moduleName}
    ${exactArtifactLoadGen correctiveFinal}
    ${correctiveCompleteCheckContent}
    mkdir -p /run/vpsadminos/livepatches
    date --utc +%Y-%m-%dT%H:%M:%SZ > \
      /run/vpsadminos/livepatches/${correctiveFinal.moduleName}.applied-at
  '';

  checkpointLoadContent = optionalString hasCheckpointPath ''
    livepatch=$(cat /etc/livepatch-store-path)
    if [ "$(uname -r)" = ${escapeShellArg checkpointCompleteAnchor.publishedIdentity} ]; then
      ${checkpointCompleteCheckContent}
      exit 0
    fi

    ${checkpointPreflightContent}
    ${moduleAliasContent}

    echo "live-patches: loading exceptional checkpoint bootstrap helper"
    if ! insmod "$livepatch/${installModDir}/${checkpointBootstrap.moduleName}.ko"; then
      echo "live-patches: checkpoint bootstrap helper insertion failed" >&2
      exit 1
    fi
    echo "live-patches: loading checkpoint guard ${checkpointGuard.moduleName}"
    if ! insmod "$livepatch/${artifactInstallPath checkpointGuard}"; then
      echo "live-patches: checkpoint guard insertion failed" >&2
      exit 1
    fi
    if [ "$(cat /sys/kernel/livepatch/${checkpointGuard.moduleName}/transition 2>/dev/null)" = 1 ]; then
      echo 1 > /sys/module/${checkpointBootstrap.moduleName}/parameters/${checkpointBootstrap.kickParameter}
    fi
    ${exactArtifactWaitGen checkpointGuard}
    ${exactArtifactLoadGen checkpointArtifact}
    ${moduleRemovalGen checkpointBootstrap.moduleName}
    ${moduleRemovalGen checkpointGuard.moduleName}
    ${checkpointCompleteCheckContent}
    mkdir -p /run/vpsadminos/livepatches
    date --utc +%Y-%m-%dT%H:%M:%SZ > \
      /run/vpsadminos/livepatches/${checkpointArtifact.moduleName}.applied-at
  '';

  reverseValidationContent = optionalString hasReverseValidationPath ''
    livepatch=$(cat /etc/livepatch-store-path)
    ${checkpointCompleteCheckContent}
    ${noActiveTransitionGen}
    ${declaredArtifactIntegrityGen reverseValidationGuard}
    ${optionalString (reverseValidationBootstrap != null) (
      declaredBootstrapIntegrityGen reverseValidationBootstrap
    )}
    ${moduleAliasContent}

    echo "live-patches: loading exceptional reverse-validation bootstrap helper"
    if ! insmod "$livepatch/${installModDir}/${reverseValidationBootstrap.moduleName}.ko"; then
      echo "live-patches: reverse-validation bootstrap helper insertion failed" >&2
      exit 1
    fi
    echo "live-patches: loading reverse-validation guard ${reverseValidationGuard.moduleName}"
    if ! insmod "$livepatch/${artifactInstallPath reverseValidationGuard}"; then
      echo "live-patches: reverse-validation guard insertion failed" >&2
      exit 1
    fi
    if [ "$(cat /sys/kernel/livepatch/${reverseValidationGuard.moduleName}/transition 2>/dev/null)" = 1 ]; then
      echo 1 > /sys/module/${reverseValidationBootstrap.moduleName}/parameters/${reverseValidationBootstrap.kickParameter}
    fi
    ${exactArtifactWaitGen reverseValidationGuard}
    ${moduleUnloadGen {
      moduleName = checkpointArtifact.moduleName;
      timeoutSeconds = 900;
    }}
    ${moduleUnloadGen {
      moduleName = reverseValidationGuard.moduleName;
      timeoutSeconds = 900;
    }}
    ${moduleRemovalGen reverseValidationBootstrap.moduleName}
    ${activePatchInventoryGen}
    if [ -n "$active_patches" ]; then
      echo "live-patches: reverse validation did not return to a clean base" >&2
      exit 1
    fi
    if [ "$(uname -r)" != ${escapeShellArg checkpointBootAnchor.publishedIdentity} ]; then
      echo "live-patches: reverse validation did not restore the base identity" >&2
      exit 1
    fi
  '';

  multiAnchorStructuredLoadContent = optionalString multiAnchorRelease ''
    ${activePatchInventoryGen}
    current_release="$(uname -r)"
    if [ "$active_patches" = ${escapeShellArg checkpointExpectedInventory} ]; then
      ${checkpointCompleteCheckContent}
      exit 0
    fi
    ${concatMapStrings (anchor: ''
      if [ "$current_release" = ${escapeShellArg (onlineFinalIdentity anchor)} ] && \
        [ "$active_patches" = ${escapeShellArg (onlineExpectedInventory anchor)} ]; then
        ${onlineCompleteCheckContentFor anchor}
        exit 0
      fi
    '') onlineAnchors}
    if [ -z "$active_patches" ]; then
      if [ "$current_release" = ${escapeShellArg checkpointBootAnchor.publishedIdentity} ]; then
        ${checkpointLoadContent}
        exit 0
      fi
      echo "live-patches: no authorized structured path for release $current_release" >&2
      exit 1
    fi
    ${concatMapStrings (anchor: ''
      if [ "$current_release" = ${escapeShellArg (onlineActiveIdentity anchor)} ] && \
        [ "$active_patches" = ${escapeShellArg (onlineActiveInventory anchor)} ]; then
        ${onlineLoadContentFor anchor}
        exit 0
      fi
    '') onlineAnchors}
    echo "live-patches: unexpected structured livepatch inventory: $active_patches for release $current_release" >&2
    exit 1
  '';

  structuredLoadContent = optionalString structuredRelease (
    if multiAnchorRelease then
      multiAnchorStructuredLoadContent
    else
      ''
        ${activePatchInventoryGen}
        current_release="$(uname -r)"
        case "$active_patches" in
          ${escapeShellArg checkpointExpectedInventory})
            ${checkpointCompleteCheckContent}
            ;;
          ${escapeShellArg correctiveExpectedInventory})
            ${correctiveCompleteCheckContent}
            ;;
          "")
            if [ "$current_release" = ${escapeShellArg checkpointBootAnchor.publishedIdentity} ]; then
              ${checkpointLoadContent}
            else
              echo "live-patches: no authorized structured path for release $current_release" >&2
              exit 1
            fi
            ;;
          ${escapeShellArg correctiveAnchor.moduleName})
            if [ "$current_release" = ${escapeShellArg correctiveAnchor.publishedIdentity} ]; then
              ${correctiveLoadContent}
            else
              echo "live-patches: remediation anchor identity mismatch for release $current_release" >&2
              exit 1
            fi
            ;;
          livepatch_5)
            echo "live-patches: exact active v5 is intentionally excluded from this corrective-only v7 release; keep the host on v5 and use the later cumulative release path" >&2
            exit 1
            ;;
          *)
            echo "live-patches: unexpected structured livepatch inventory: $active_patches" >&2
            exit 1
            ;;
        esac
      ''
  );

  structuredListContent = optionalString structuredRelease (
    if multiAnchorRelease
    then
      concatMapStrings structuredListGen (concatLists (attrValues release.paths))
      + structuredListGen checkpointArtifact
    else
      concatMapStrings structuredListGen correctiveArtifacts
      + concatMapStrings structuredListGen checkpointBootArtifacts
      + concatMapStrings structuredListGen reverseValidationArtifacts
      + structuredListGen checkpointArtifact
  );

  live-patches-util = pkgs.writeScriptBin "live-patches" (
    optionalString (!buildEnable) ''
      echo Live Patching not enabled in machine config or no patches available
      exit 0
    ''
    + optionalString (buildEnable && structuredRelease) ''
      case "$1" in
      load)
        ${structuredLoadContent}
        ;;
      load-corrective-v6)
        ${optionalString hasCorrectivePath correctiveLoadContent}
        ${optionalString (!hasCorrectivePath) ''
          echo "live-patches: this release has no corrective-v6 path" >&2
          exit 1
        ''}
        ;;
      load-checkpoint)
        ${checkpointLoadContent}
        ;;
      reverse-validation)
        ${reverseValidationContent}
        ;;
      unload)
        echo "live-patches: production livepatch unloading is forbidden; reboot instead" >&2
        exit 1
        ;;
      list|status)
        ${structuredListContent}
        ;;
      *)
        echo "usage: $0 load|load-corrective-v6|load-checkpoint|reverse-validation|list|status" >&2
        exit 2
        ;;
      esac
    ''
    + optionalString (buildEnable && !structuredRelease) ''
      case "$1" in
      load)
        ${moduleLoadContent}
        ;;
      unload)
        echo "live-patches: production livepatch unloading is forbidden; reboot instead" >&2
        exit 1
        ;;
      list)
        ${moduleListContent}
        ;;
      status)
        ${moduleStatusContent}
        ;;
      *)
        echo "usage: $0 load|list|status" >&2
        exit 2
        ;;
      esac
    ''
  );
in
{
  options = {
    services.live-patches.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When enabled, live-patches utility is added to system path along with compiled live patch kernel modules.
        Note, patches are automatically loaded only upon machine boot, live-patches
        util has to be called manually to load them when deploying onto a running machine.
      '';
    };
  };
  config = mkMerge [
    {
      environment.etc."livepatch-store-path".text =
        "" + (optionalString (buildEnable) (toString patches));
      environment.systemPackages = [ live-patches-util ];
      runit.services.live-patches = {
        run =
          (optionalString (
            buildEnable && (!structuredRelease || release.autoLoad or false)
          ) "live-patches load && ")
          + "sleep inf";
        # Active livepatches are forward-only kernel state. Service stop,
        # package replacement, and shutdown must never initiate a transition.
        finish = "";
        log.enable = true;
        log.sendTo = "127.0.0.1";
        runlevels = [ "default" ];
        onChange = "ignore";
      };
      boot.postBootCommands = mkAfter (
        optionalString (structuredRelease && checkpointBootAnchor != null) ''
          if ! live-patches load-checkpoint; then
            echo "live-patches: early-boot checkpoint activation failed; keeping workload gate closed" > /dev/kmsg
            exec sleep inf
          fi
        ''
      );
    }

    (mkIf buildEnable {
      system.build.livePatches = patches;
      system.build.livePatchDrafts = draftPatches;
      environment.etc."vpsadminos/livepatch-monitor.json".text = builtins.toJSON {
        kernelVersion = config.boot.kernelVersion;
        inherit patchVersion;
        authorization =
          if multiAnchorRelease then "multi-anchor"
          else if structuredRelease then "corrective-only"
          else "legacy";
        autoLoad = if structuredRelease then release.autoLoad or false else true;
        artifacts = map (artifact: {
          inherit (artifact) moduleName role;
          replace = !(artifact.nonReplace or false);
          expectedSha256 = artifact.expectedSha256 or null;
        }) artifacts;
        paths =
          if structuredRelease
          then mapAttrs (_: path: map (artifact: artifact.moduleName) path) release.paths
          else { };
        onlineAnchors =
          if multiAnchorRelease
          then mapAttrs (_: anchor: {
            inherit (anchor) class path;
            activeIdentity = onlineActiveIdentity anchor;
            activeInventory = onlineActiveInventoryNames anchor;
            expectedInventory = onlineExpectedInventoryNames anchor;
          }) release.onlineAnchors
          else { };
        checkpoint =
          if checkpointArtifact == null then null else checkpointArtifact.moduleName;
        patches = map (patch: {
          inherit (patch) name;
          version = availablePatches.getPatchVersion patch;
        }) availablePatches.filteredPatches;
      };
    })
  ];
}
