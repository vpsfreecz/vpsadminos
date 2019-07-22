{ lib }:
{
  # Extract command from systemd's ExecStart, i.e. remove known prefixes
  extractExecCommand = cmd:
    let
      prefixes = [ "@" "-" ":" "+" "!!" "!" ];
      prefix = lib.findFirst (s: lib.hasPrefix s cmd) null prefixes;
      withoutPrefix = if prefix == null then cmd else (lib.removePrefix prefix cmd);
    in withoutPrefix;
}
