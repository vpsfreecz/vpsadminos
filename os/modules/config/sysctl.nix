{
  config,
  lib,
  pkgs,
  ...
}:
let
  managedFiles = lib.filterAttrs (
    _: file:
    file.enable
    && (file.target == "sysctl.conf" || builtins.match "sysctl\\.d/[^/]+\\.conf" file.target != null)
  ) config.environment.etc;
  managedInputs =
    lib.sort (a: b: if a.target == b.target then a.source < b.source else a.target < b.target)
      (
        lib.mapAttrsToList (_: file: {
          inherit (file) target;
          # Match the etc renderer: copy literal paths into the store by content.
          source = "${file.source}";
        }) managedFiles
      );
  inputIdentity = builtins.hashString "sha256" (builtins.toJSON managedInputs);
in
{
  runit.services.sysctl = {
    oneShot = true;
    onChange = "restart";
    runlevels = [
      "default"
      "rescue"
    ];
    includeHelpers = false;
    log.enable = true;
    # Keep check's presence independent of environment.etc while it is assembled.
    environment.SYSCTL_INPUT_IDENTITY = inputIdentity;
    restartTriggers = map (file: "${file.target}:${file.source}") managedInputs;
    run = ''
      # Enter once mode before setup so failures do not retry automatically.
      if ! ${pkgs.runit}/bin/sv once sysctl; then
        ${pkgs.coreutils}/bin/rm -f /run/service/sysctl/applied /run/service/sysctl/done
        echo "Unable to put sysctl service in once mode; prior status is not fresh success evidence" >&2
        exit 1
      fi

      state=/run/service/sysctl
      if ! ${pkgs.coreutils}/bin/mkdir -p "$state" ||
         ! ${pkgs.coreutils}/bin/rm -f "$state/applied" "$state/done"; then
        echo "Unable to clear sysctl application status; prior status is not fresh success evidence" >&2
        exit 1
      fi

      if ! ${pkgs.procps}/bin/sysctl -w --system; then
        echo "Unable to apply sysctl configuration" >&2
        exit 1
      fi

      temporary="$state/applied.$$"
      if ! printf '%s\n' "$SYSCTL_INPUT_IDENTITY" > "$temporary"; then
        echo "Unable to write sysctl application status" >&2
        exit 1
      fi
      if ! ${pkgs.coreutils}/bin/mv -f "$temporary" "$state/applied"; then
        ${pkgs.coreutils}/bin/rm -f "$temporary"
        echo "Unable to publish sysctl application status" >&2
        exit 1
      fi
    '';
    check = ''
      test "$(${pkgs.coreutils}/bin/cat /run/service/sysctl/applied 2>/dev/null)" = "$SYSCTL_INPUT_IDENTITY"
    '';
  };
}
