# Shared by kernel debug configuration, suite registration and test scripts.
let
  selected = name: builtins.getEnv name == "1";
  selectorsFor =
    enabledName: onlyName:
    let
      enabled = selected enabledName;
      only = selected onlyName;
    in
    {
      inherit enabled only;
      requested = enabled || only;
    };
in
rec {
  log = selectorsFor "VPSADMINOS_ENABLE_CRED_GUARD_TEST" "VPSADMINOS_ONLY_CRED_GUARD_TEST";
  panic = selectorsFor "VPSADMINOS_ENABLE_CRED_GUARD_PANIC_TEST" "VPSADMINOS_ONLY_CRED_GUARD_PANIC_TEST";

  requested = log.requested || panic.requested;
  only = log.only || panic.only;
}
