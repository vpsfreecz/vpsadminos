# Copy ONLY vpsadminos.nix, as the documented guest update path instructs.
# Any accidental relative companion dependency must fail this evaluation.
let
  vpsadminos = builtins.getFlake (toString ../.);
  fixtures = import ./fixtures/nixos-container-releases.nix { inherit vpsadminos; };
  evaluate =
    file: nixpkgs:
    let
      standalone = builtins.toFile "vpsadminos-standalone.nix" (builtins.readFile file);
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
{
  "25.11" = evaluate ../os/lib/nixos-container/stable/vpsadminos-25.11.nix fixtures."25.11";
  "26.05" = evaluate ../os/lib/nixos-container/stable/vpsadminos-26.05.nix fixtures."26.05";
  "26.11" = evaluate ../os/lib/nixos-container/stable/vpsadminos-26.11.nix fixtures."26.11";
  stable = evaluate ../os/lib/nixos-container/stable/vpsadminos.nix fixtures."26.05";
  unstable = evaluate ../os/lib/nixos-container/unstable/vpsadminos.nix fixtures.unstable;
}
