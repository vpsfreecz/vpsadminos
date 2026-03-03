{
  lib,
  clangStdenv,
  buildGoModule,
  fetchFromGitHub,
  libbpf,
  libelf,
  libsystemtap,
  libz,
}:

# BPF programs must be compiled with Clang.
buildGoModule.override { stdenv = clangStdenv; } (finalAttrs: {
  pname = "prometheus-ebpf-exporter";
  version = "2.5.1-vpsadminos";

  src = fetchFromGitHub {
    owner = "vpsfreecz";
    repo = "ebpf_exporter";
    rev = "3206f569951f23dcb584ff9f0d29313de7ac5cc3";
    hash = "sha256-eePhBTPfRrZh2c/idDWRJQxVkAlL13IRZdSPNzLzRjg=";
  };

  vendorHash = "sha256-jzZgR7c63AFUyj0A8FxOm/1FBngcXhmWXTclwohaz48=";

  postPatch = ''
    substituteInPlace examples/Makefile \
      --replace-fail "-Wall -Werror" ""
  '';

  buildInputs = [
    libbpf
    libelf
    libsystemtap
    libz
  ];

  CGO_LDFLAGS = "-l bpf";

  hardeningDisable = [ "zerocallusedregs" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/prometheus/common/version.Version=${finalAttrs.version}"
    "-X github.com/prometheus/common/version.Revision=${finalAttrs.src.rev}"
    "-X github.com/prometheus/common/version.Branch=vpsadminos"
    "-X github.com/prometheus/common/version.BuildUser=nix@vpsadminos"
    "-X github.com/prometheus/common/version.BuildDate=unknown"
  ];

  postBuild = ''
    BUILD_LIBBPF=0 make examples
  '';

  postInstall = ''
    mkdir -p $out/examples
    mv examples/*.o examples/*.yaml $out/examples
  '';

  # Upstream checks fail in sandbox on cgroup access.
  doCheck = false;

  meta = {
    description = "Prometheus exporter for custom eBPF metrics";
    mainProgram = "ebpf_exporter";
    homepage = "https://github.com/vpsfreecz/ebpf_exporter";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = lib.platforms.linux;
  };
})
