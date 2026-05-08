{
  pkgs,
  lib,
  stdenv,
  kernel,
  bpftool ? pkgs.bpftools,
  libbpf ? pkgs.libbpf,
  elfutils ? pkgs.elfutils,
  zlib ? pkgs.zlib,
  programs ? {
    override_uname = {};
    lsm_example = {};
  },
}:

let
  inherit (pkgs) llvm;

  progNames = builtins.attrNames programs;

  # Generate vmlinux.h from kernel BTF
  vmlinux_h = stdenv.mkDerivation {
    name = "ebpf-vmlinux-h-${kernel.modDirVersion}";
    nativeBuildInputs = [ bpftool ];
    buildCommand = ''
      mkdir -p $out/include
      bpftool btf dump file ${kernel.dev}/vmlinux format c > $out/include/vmlinux.h
    '';
  };

  # Compile a single BPF program to .bpf.o
  compileBpf =
    name:
    stdenv.mkDerivation {
      name = "ebpf-${name}-bpf-o-${kernel.modDirVersion}";
      src = ../../../os/ebpf/programs;

      nativeBuildInputs = [ llvm ];

      buildPhase = ''
        mkdir -p out

        clang -g -O2 -target bpf \
          -D__TARGET_ARCH_x86 \
          -I${vmlinux_h}/include \
          -I${libbpf}/include \
          -I${kernel.dev}/include \
          -I${kernel.dev}/arch/x86/include \
          -I${kernel.dev}/arch/x86/include/generated \
          -I${kernel.dev}/arch/x86/include/generated/uapi \
          -I${kernel.dev}/arch/x86/include/uapi \
          -I${kernel.dev}/include/uapi \
          -c ${name}.bpf.c \
          -o out/${name}.bpf.o
      '';

      installPhase = ''
        mkdir -p $out
        cp out/${name}.bpf.o $out/
      '';
    };

  # Generate skeleton header from .bpf.o
  genSkel =
    name: bpfObj:
    stdenv.mkDerivation {
      name = "ebpf-${name}-skel-${kernel.modDirVersion}";
      nativeBuildInputs = [ bpftool ];
      buildCommand = ''
        mkdir -p $out
        bpftool gen skeleton ${bpfObj}/${name}.bpf.o > $out/${name}.skel.h
      '';
    };

  bpfObjs = lib.genAttrs progNames compileBpf;
  skelHeaders = lib.mapAttrs genSkel bpfObjs;

  # Build the loader binary
  loader = stdenv.mkDerivation {
    name = "ebpf-livepatch-loader-${kernel.modDirVersion}";
    src = ./.;

    buildInputs = [ libbpf elfutils zlib ];

    buildPhase =
      let
        skelIncludes = lib.concatMapStrings (name: ''
          cp ${skelHeaders.${name}}/${name}.skel.h .
        '') progNames;
      in
      ''
        runHook preBuild

        # Copy skeleton headers
        ${skelIncludes}

        # Compile the loader
        gcc -g -O2 -Wall \
          -I${libbpf}/include \
          -c loader.c \
          -o loader.o

        gcc loader.o \
          -L${libbpf}/lib \
          -lbpf -lelf -lz \
          -o ebpf-loader

        runHook postBuild
      '';

    installPhase = ''
      mkdir -p $out/bin $out/bpf
      cp ebpf-loader $out/bin/
    ''
    + lib.concatMapStrings (name: ''
      cp ${bpfObjs.${name}}/${name}.bpf.o $out/bpf/
    '') progNames
    + '';

    meta.description = "eBPF livepatch loader for vpsAdminOS";
  };

in
{
  inherit vmlinux_h bpfObjs loader;
}
