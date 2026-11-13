{
  binutils,
  coreutils,
  findutils,
  gnugrep,
  kmod,
  lib,
  python3,
  stdenv,
  writeText,
}:

{
  batch,
  kpatchBuild,
  targetBuild,
}:

let
  inherit (lib)
    concatMapStrings
    concatStringsSep
    escapeShellArg
    optionalString
    ;

  python = python3.withPackages (packages: [ packages.pyelftools ]);

  mkFileInput = name: path: builtins.path { inherit name path; };
  patchInputs = map (
    patch:
    patch
    // {
      input = mkFileInput "vpsadminos-livepatch-payload-${toString patch.order}.patch" patch.path;
    }
  ) batch.build.patches;
  patchCopies = concatMapStrings (patch: ''
    cp ${escapeShellArg (toString patch.input)} patches/${toString patch.order}.patch
  '') patchInputs;
  patchArguments = concatStringsSep " " (
    map (patch: "patches/${toString patch.order}.patch") patchInputs
  );
  frameworkInput = mkFileInput "vpsadminos-livepatch-release-level.patch" batch.build.framework.path;
  inspectorInput = mkFileInput "vpsadminos-livepatch-inspect.py" ./inspect.py;
  moduleSymversInput = targetBuild.identity.moduleSymvers;
  moduleLdsInput = "${targetBuild.dev}/lib/modules/${targetBuild.modDirVersion}/build/scripts/module.lds";
  frameworkPatch = "patches/${toString batch.build.framework.order}.patch";
  generatedHeaderFile = writeText "${batch.moduleName}-vpsadminos-livepatch-build.h" (
    batch.build.generatedHeader
  );
  targetArguments = concatStringsSep " " (
    map (target: "-t ${escapeShellArg target}") batch.build.targets
  );

  expectedInspection = {
    callbacks = batch.build.expected.callbacks;
    framework = {
      inherit (batch.unameLevel)
        frameworkPatchSha256
        generatedHeaderSha256
        guardErrno
        ;
      guardReturnCount = 1;
      carrier = {
        object = batch.unameLevel.callbackCarrier.object;
        present = true;
      };
      replacementFunctions = [ ];
    };
    functions = map (function: {
      inherit (function) object symbol sympos;
    }) batch.build.expected.functions;
    imports = batch.build.expected.imports;
    moduleName = batch.moduleName;
    relocations = batch.build.expected.relocations;
    signature = batch.kernelTarget.signature;
    states = batch.build.expected.states;
    stateSection = batch.build.expected.stateSection;
    vermagic = batch.kernelTarget.vermagic;
  };
  expectedInspectionFile = writeText "${batch.moduleName}-expected-inspection.json" (
    builtins.toJSON expectedInspection
  );
  manifestFile = writeText "${batch.moduleName}-manifest.json" (builtins.toJSON batch.manifest);

  legacySkippedObjects = [
    "kernel/trace/ring_buffer.o"
    "net/bpf/test_run.o"
    "net/core/filter.o"
    "kernel/bpf/helpers.o"
    "drivers/net/ethernet/chelsio/cxgb4/t4_hw.o"
  ];
  skippedObjectArguments = concatMapStrings (
    object: " --forbidden-skipped-object ${escapeShellArg object}"
  ) legacySkippedObjects;

  toolchainPrefix = optionalString (
    (targetBuild.toolchain or null) != null
  ) "PATH=\"${targetBuild.toolchain}/bin:$PATH\" ";
in

assert batch.mode == "additive";
assert builtins.elem "--non-replace" batch.producer.flags;
assert batch.producer.kpatchBuild == toString kpatchBuild;
assert batch.kernelTarget.identity == targetBuild.identity;
assert batch.kernelTarget.kernelVersion == targetBuild.modDirVersion;
assert batch.kernelTarget.vermagic == targetBuild.vermagic;
assert batch.kernelTarget.signature == targetBuild.signature;
assert batch.manifest.kernelTarget == batch.kernelTarget;
assert batch.unameLevel.frameworkPatchSha256 == batch.build.framework.sha256;
assert
  batch.unameLevel.generatedHeaderSha256 == builtins.hashString "sha256" batch.build.generatedHeader;

stdenv.mkDerivation {
  pname = batch.moduleName;
  version = toString batch.payloadRevision;

  dontUnpack = true;
  dontStrip = true;
  strictDeps = true;

  hardeningDisable = [
    "bindnow"
    "format"
    "fortify"
    "pic"
    "stackprotector"
  ];

  depsBuildBuild = [ stdenv.cc ];
  nativeBuildInputs = (targetBuild.nativeBuildInputs or [ ]) ++ [
    binutils
    coreutils
    findutils
    gnugrep
    kmod
    python
  ];

  buildPhase = ''
    runHook preBuild

    require_file() {
      if [ ! -f "$1" ]; then
        echo "required livepatch build file is missing: $1" >&2
        exit 1
      fi
    }

    require_dir() {
      if [ ! -d "$1" ]; then
        echo "required livepatch build directory is missing: $1" >&2
        exit 1
      fi
    }

    export DEBUG=1
    export CCACHE_UMASK=007
    export CCACHE_DIR=/nix/var/cache/ccache
    export CACHEDIR="$PWD/tmp/cache"
    export TEMPDIR="$CACHEDIR/tmp"

    require_file ${escapeShellArg (toString targetBuild.source)}
    require_dir ${escapeShellArg (toString targetBuild.dev)}
    require_file ${escapeShellArg (toString targetBuild.configFile)}
    require_file ${escapeShellArg targetBuild.vmlinux}
    require_file ${escapeShellArg moduleSymversInput}
    require_file ${escapeShellArg moduleLdsInput}
    require_dir ${escapeShellArg (toString kpatchBuild)}

    mkdir -p "$CACHEDIR" "$TEMPDIR" patches
    ${patchCopies}
    cp ${escapeShellArg (toString frameworkInput)} ${frameworkPatch}

    cp -r ${kpatchBuild} kpatch-build
    chmod -R u+w kpatch-build
    kpb="$PWD/kpatch-build"

    dirs_before=""
    for entry in *; do
      if [ -d "$entry" ]; then
        dirs_before="$dirs_before $entry "
      fi
    done

    tar xf ${targetBuild.source}
    source_root=""
    for entry in *; do
      if [ -d "$entry" ]; then
        case "$dirs_before" in
          *\ "$entry"\ *) ;;
          *)
            if [ -n "$source_root" ]; then
              echo "kernel source archive produced multiple directories" >&2
              exit 1
            fi
            source_root="$entry"
            ;;
        esac
      fi
    done
    if [ -z "$source_root" ]; then
      echo "kernel source archive produced no directory" >&2
      exit 1
    fi

    mv "$source_root" src
    export KERNEL_SRCDIR="$PWD/src"
    chmod -R u+w src
    cp -r ${targetBuild.dev}/. src/
    cp ${escapeShellArg moduleSymversInput} src/Module.symvers
    cp ${escapeShellArg moduleLdsInput} src/scripts/module.lds
    chmod -R u+w src
    ln -snf ${targetBuild.configFile} src/.config
    patchShebangs src/scripts > /dev/null
  ''
  + optionalString ((targetBuild.zfsBuiltinPkg or null) != null) ''
    cp -r ${targetBuild.zfsBuiltinPkg} zfsBuiltin
    chmod -R u+w zfsBuiltin
    ( cd zfsBuiltin && ./copy-builtin ../src )
  ''
  + ''
    cp ${generatedHeaderFile} src/include/linux/vpsadminos-livepatch-build.h

    chmod -R u+w .

    require_file "$KERNEL_SRCDIR/.config"
    require_file "$KERNEL_SRCDIR/Makefile"
    require_file "$KERNEL_SRCDIR/Module.symvers"
    require_file "$KERNEL_SRCDIR/scripts/module.lds"
    require_file "$KERNEL_SRCDIR/include/linux/vpsadminos-livepatch-build.h"
    require_file ${escapeShellArg targetBuild.vmlinux}
    if grep -q '^CONFIG_DEBUG_INFO_BTF=y$' "$KERNEL_SRCDIR/.config"; then
      require_file "$KERNEL_SRCDIR/scripts/link-vmlinux.sh"
    fi
    if ! cmp -s ${escapeShellArg moduleSymversInput} "$KERNEL_SRCDIR/Module.symvers"; then
      echo "prepared Module.symvers differs from the configured target" >&2
      exit 1
    fi
    if ! cmp -s ${escapeShellArg moduleLdsInput} "$KERNEL_SRCDIR/scripts/module.lds"; then
      echo "prepared scripts/module.lds differs from the configured target" >&2
      exit 1
    fi
    if ! grep -Eq '^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+vmlinux([[:space:]]|$)' "$KERNEL_SRCDIR/Module.symvers"; then
      echo "configured Module.symvers has no vmlinux symbol records" >&2
      exit 1
    fi
    for required in \
      "$kpb/kpatch-build/kpatch-build" \
      "$kpb/kpatch-build/kpatch-cc" \
      "$kpb/kpatch-build/create-diff-object" \
      "$kpb/kpatch-build/create-klp-module" \
      "$kpb/kmod/patch/Makefile" \
      "$kpb/kmod/patch/kpatch.lds.S" \
      "$kpb/kmod/patch/patch-hook.c" \
      "$kpb/kmod/patch/kpatch-patch-hook.c" \
      "$kpb/kmod/patch/livepatch-patch-hook.c" \
      "$kpb/kmod/patch/kpatch-patch.h" \
      "$kpb/kmod/patch/kpatch-macros.h" \
      "$kpb/kmod/patch/kpatch-syscall.h"; do
      require_file "$required"
    done
    for patch in ${patchArguments} ${frameworkPatch}; do
      require_file "$patch"
    done

    echo kpatch-build --non-replace -v ${targetBuild.vmlinux} -s src -n ${batch.moduleName} ${targetArguments} ${patchArguments} ${frameworkPatch}
    if ! ${toolchainPrefix}"$kpb/kpatch-build/kpatch-build" \
      --non-replace \
      -v ${targetBuild.vmlinux} \
      -s src \
      -n ${batch.moduleName} \
      ${targetArguments} \
      ${patchArguments} \
      ${frameworkPatch}; then
      echo "kpatch-build failed" >&2
      cat "$CACHEDIR/build.log" 2>/dev/null || true
      exit 1
    fi

    test -f ${batch.moduleName}.ko
    test -f "$TEMPDIR/changed_objs"

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    ${python}/bin/python ${inspectorInput} \
      --module ${batch.moduleName}.ko \
      --expected ${expectedInspectionFile} \
      --inspection inspection.json \
      --closure closure.json \
      --build-flag=--non-replace \
      --changed-objects "$TEMPDIR/changed_objs" \
      --framework-source ${frameworkPatch} \
      --generated-header src/include/linux/vpsadminos-livepatch-build.h \
      --framework-carrier-object ${escapeShellArg batch.unameLevel.callbackCarrier.object}${skippedObjectArguments}

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install_dir="$out/lib/modules/${targetBuild.modDirVersion}/extra"
    evidence_dir="$out/share/vpsadminos-livepatch"
    mkdir -p "$install_dir" "$evidence_dir" "$out/livepatch-evidence/diff-objects"

    cp ${batch.moduleName}.ko "$install_dir/${batch.moduleName}.ko"
    cp ${manifestFile} "$evidence_dir/manifest.json"
    cp inspection.json "$evidence_dir/inspection.json"
    cp closure.json "$evidence_dir/closure.json"
    cp ${expectedInspectionFile} "$evidence_dir/expected-inspection.json"
    cp ${frameworkPatch} "$evidence_dir/framework.patch"
    cp src/include/linux/vpsadminos-livepatch-build.h "$evidence_dir/generated-header.h"

    cp "$CACHEDIR/build.log" "$out/livepatch-evidence/build.log"
    cp "$TEMPDIR/changed_objs" "$out/livepatch-evidence/changed-objects.txt"
    ( cd "$CACHEDIR" && find . -maxdepth 4 -print | sort ) \
      > "$out/livepatch-evidence/cachedir-tree.txt"
    ( cd "$TEMPDIR" && find . -maxdepth 4 -print | sort ) \
      > "$out/livepatch-evidence/tempdir-tree.txt"
    ( cd "$TEMPDIR" && find output -type f -name '*.o' -print | sort | while read -r object; do
      cp --parents "$object" "$out/livepatch-evidence/diff-objects/"
    done )

    runHook postInstall
  '';

  passthru = {
    inherit batch;
    kernelTarget = batch.kernelTarget;
    manifest = batch.manifest;
    targetIdentity = targetBuild.identity;
  };
}
