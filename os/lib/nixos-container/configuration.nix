{ config, pkgs, lib, ...}: let

  cloneImports = [
      <nixpkgs/nixos/modules/profiles/minimal.nix>
      <nixpkgs/nixos/modules/virtualisation/container-config.nix>
      <nixpkgs/nixos/modules/installer/cd-dvd/channel.nix>
      ./build.nix
      ./networking.nix
  ];

  rules = [
    { match = ".*/nixpkgs/(.*)";
      apply = file: x: { path = file; str = "<nixpkgs/${x}>"; match = x; type = "nixpkgs"; };
    }
    { match = ".*/vpsadminos/os/lib/nixos-container/(.*)";
      apply = file: x: { path = file; str = "./${x}"; match = x; type = "local"; };
    }
  ];
  procImports = lib.concatMap (item:
    (lib.filter (x: x != null)
    (map ({ match, apply }:
      let
        i = builtins.match match (toString item);
      in
        if i != null then apply item (builtins.head i) else null
      ) rules))) cloneImports;


  clonedImports = lib.concatStrings (
    lib.intersperse "\n" (map (x: "          " + x.str) procImports));

  configClone = pkgs.writeText "configuration.nix"
    ''
    { config, pkgs, ... }:
    {
      imports = [
    ${clonedImports}
      ];

      environment.systemPackages = [
        pkgs.nvi
      ];

      services.openssh.enable = true;
      services.openssh.permitRootLogin = "yes";
      #users.extraUsers.root.openssh.authorizedKeys.keys =
      #  [ "..." ];

      time.timeZone = "Europe/Amsterdam";
      system.stateVersion = "18.09";
    }
    '';

  localCopies = lib.concatMapStrings ({ path, str, match, ... }:
    ''
      if ! [ -e /etc/nixos/${match} ]; then
        cp ${pkgs.writeText match (builtins.readFile path)} /etc/nixos/${match}
        chmod +w /etc/nixos/${match}
      fi
    '') (lib.filter (x: x.type == "local") procImports);

  in
  {
  imports = cloneImports;

  environment.systemPackages = [ pkgs.nvi ];
  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = "18.09";

  services.openssh.enable = lib.mkDefault true;
  services.openssh.permitRootLogin = lib.mkDefault "yes";

  boot.postBootCommands =
    ''
      # Copy configuration required to reproduce this build
      if ! [ -e /etc/nixos/configuration.nix ]; then
            cp ${configClone} /etc/nixos/configuration.nix
            chmod +w /etc/nixos/configuration.nix
      fi
      ${localCopies}
    '';
}
