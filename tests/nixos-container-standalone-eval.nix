# Copy ONLY vpsadminos.nix, as the documented guest update path instructs.
# Any accidental relative companion dependency must fail this evaluation.
let
  vpsadminos = builtins.getFlake (toString ../.);
  evaluate =
    channel:
    let
      standalone = builtins.toFile "vpsadminos-${channel}.nix" (
        builtins.readFile (../os/lib/nixos-container + "/${channel}/vpsadminos.nix")
      );
      nixpkgs =
        if channel == "stable" then vpsadminos.inputs.nixpkgs else vpsadminos.inputs.nixpkgsUnstable;
      evaluated = import (nixpkgs + "/nixos/lib/eval-config.nix") {
        system = builtins.currentSystem;
        modules = [
          (toString standalone)
          { system.stateVersion = nixpkgs.lib.trivial.release; }
        ];
      };
    in
    evaluated.config.system.build.toplevel.drvPath;
in
builtins.map evaluate [
  "stable"
  "unstable"
]
