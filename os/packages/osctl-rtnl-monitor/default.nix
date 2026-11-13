{
  lib,
  stdenv,
  linux,
  kernel ? linux,
  clang,
  bpftools,
  pkg-config,
  libbpf,
  json_c,
  elfutils,
  zlib,
  ruby,
  makeWrapper,
}:

stdenv.mkDerivation {
  pname = "osctl-rtnl-monitor";
  version = "1";
  src = lib.cleanSourceWith {
    src = ../../../rtnl-monitor;
    # Local native checks must not supply prebuilt objects to the Nix build.
    filter = path: _type: builtins.baseNameOf path != "build";
  };

  nativeBuildInputs = [
    clang
    bpftools
    pkg-config
    makeWrapper
  ];
  buildInputs = [
    libbpf
    json_c
    elfutils
    zlib
  ];
  makeFlags = [
    "CC=${stdenv.cc.targetPrefix}cc"
    "CLANG=${clang}/bin/clang"
    "BPFTOOL=${bpftools}/bin/bpftool"
    "VMLINUX_BTF=${kernel.dev}/vmlinux"
    "PREFIX=$(out)"
  ];
  enableParallelBuilding = true;
  hardeningDisable = [ "zerocallusedregs" ];
  # Preserve the BPF object's BTF and CO-RE relocation information.
  dontStrip = true;

  postInstall = ''
    wrapProgram $out/bin/osctl-rtnl-monitor \
      --add-flags "--bpf-object $out/lib/osctl-rtnl-monitor/monitor.bpf.o"

    mkdir -p $out/lib/osctl-rtnl-monitor/ruby/{osctl,libosctl}
    cp ${../../../osctl/lib/osctl/client.rb} $out/lib/osctl-rtnl-monitor/ruby/osctl/client.rb
    cp ${../../../libosctl/lib/libosctl/cgroup.rb} $out/lib/osctl-rtnl-monitor/ruby/libosctl/cgroup.rb
    cp root_manifest.rb $out/lib/osctl-rtnl-monitor/root_manifest.rb
    makeWrapper ${ruby}/bin/ruby $out/bin/osctl-rtnl-monitor-roots \
      --unset GEM_HOME --unset GEM_PATH --unset RUBYOPT --unset RUBYLIB \
      --add-flags "-I$out/lib/osctl-rtnl-monitor/ruby $out/lib/osctl-rtnl-monitor/root_manifest.rb"
  '';

  passthru = { inherit kernel; };
  meta = {
    description = "Diagnostic monitor for pending global RTNL acquisition calls";
    license = [
      lib.licenses.gpl2Only
      lib.licenses.mit
    ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "osctl-rtnl-monitor";
  };
}
