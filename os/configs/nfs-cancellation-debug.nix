{
  config,
  lib,
  pkgs,
  ...
}:
let
  kernels = import ../packages/linux/packages.nix { inherit config lib pkgs; };
  debugConfig = with lib.kernel; {
    KASAN = lib.mkForce yes;
    KASAN_GENERIC = lib.mkForce yes;
    KASAN_INLINE = lib.mkForce yes;
    PROVE_LOCKING = lib.mkForce yes;
    DEBUG_ATOMIC_SLEEP = lib.mkForce yes;
    DEBUG_OBJECTS = lib.mkForce yes;
    DEBUG_OBJECTS_TIMERS = lib.mkForce yes;
    DEBUG_KOBJECT_RELEASE = lib.mkForce yes;
    FAULT_INJECTION = lib.mkForce yes;
    FAULT_INJECTION_DEBUG_FS = lib.mkForce yes;
    FUNCTION_ERROR_INJECTION = lib.mkForce yes;
    FAIL_FUNCTION = lib.mkForce yes;
  };
  configure = kernel: kernel.override { structuredExtraConfig = debugConfig; };
in
{
  # Diagnostic build of the selected source, shared by CI and the VM tests.
  boot.kernelForBuiltinsConfig = lib.mkForce (
    configure (kernels.genKernelPackage config.boot.kernelVersion)
  );
  boot.kernelPackage = lib.mkForce (
    configure (
      if config.boot.zfsBuiltin then
        kernels.genKernelPackageWithZfsBuiltin {
          kernelVersion = config.boot.kernelVersion;
          zfsBuiltinPkg = config.boot.zfsBuiltinPkg;
        }
      else
        kernels.genKernelPackage config.boot.kernelVersion
    )
  );
  boot.qemu.memory = lib.mkOverride 0 8192;
  services.live-patches.enable = lib.mkForce false;
  boot.kernelParams = [
    "panic_on_warn=1"
    "kasan.fault=panic"
  ];
}
