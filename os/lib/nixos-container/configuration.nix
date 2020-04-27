{ config, pkgs, lib, ...}:
let
  nixpkgsBase = toString <nixpkgs>;

  osBase = toString ../../..;

  nixpkgsImports = [
    "nixos/modules/profiles/minimal.nix"
    "nixos/modules/virtualisation/container-config.nix"
    "nixos/modules/installer/cd-dvd/channel.nix"
  ];

  osImports = [
    "os/lib/nixos-container/build.nix"
    "os/lib/nixos-container/networking.nix"
  ];

  clonedImports =
    (map (v: "<nixpkgs/${v}>") nixpkgsImports)
    ++
    (map (v: "./${baseNameOf v}") osImports);

  clonedImportsString =
    lib.concatMapStringsSep "\n" (x: "    " + x) clonedImports;

  useImports =
    (map (v: "${nixpkgsBase}/${v}") nixpkgsImports)
    ++
    (map (v: "${osBase}/${v}") osImports);

  configClone = pkgs.writeText "configuration.nix"
    ''
    { config, pkgs, ... }:
    {
      imports = [
    ${clonedImportsString}
      ];

      environment.systemPackages = with pkgs; [
        vim
      ];

      services.openssh.enable = true;
      services.openssh.permitRootLogin = "yes";
      #users.extraUsers.root.openssh.authorizedKeys.keys =
      #  [ "..." ];

      systemd.extraConfig = '''
        DefaultTimeoutStartSec=900s
      ''';

      time.timeZone = "Europe/Amsterdam";

      documentation.enable = true;
      documentation.nixos.enable = true;

      system.stateVersion = "${lib.trivial.release}";
    }
    '';

  localCopies = lib.concatMapStrings (path:
    let
      name = baseNameOf path;
      src = pkgs.copyPathToStore "${osBase}/${path}";
    in ''
      if ! [ -e /etc/nixos/${name} ]; then
        cp ${src} /etc/nixos/${name}
        chmod +w /etc/nixos/${name}
      fi
    '') osImports;

  in {
    imports = useImports;

    environment.systemPackages = with pkgs; [ vim ];
    time.timeZone = "Europe/Amsterdam";
    system.stateVersion = lib.trivial.release;

    services.openssh.enable = lib.mkDefault true;
    services.openssh.permitRootLogin = lib.mkDefault "yes";

    systemd.extraConfig = ''
      DefaultTimeoutStartSec=900s
    '';

    documentation.enable = true;
    documentation.nixos.enable = true;

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
