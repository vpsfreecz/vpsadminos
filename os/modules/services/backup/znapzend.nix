{ config, lib, pkgs, ... }:

with lib;
with types;

let

  # A type for a string of the form number{b|k|M|G}
  mbufferSizeType = str // {
    check = x: str.check x && builtins.isList (builtins.match "^[0-9]+[bkMG]$" x);
    description = "string of the form number{b|k|M|G}";
  };

  enabledFeatures = concatLists (mapAttrsToList (name: enabled: optional enabled name) cfg.features);

  # Type for a string that must contain certain other strings (the list parameter).
  # Note that these would need regex escaping.
  stringContainingStrings = list: let
    matching = s: map (str: builtins.match ".*${str}.*" s) list;
  in str // {
    check = x: str.check x && all isList (matching x);
    description = "string containing all of the characters ${concatStringsSep ", " list}";
  };

  timestampType = stringContainingStrings [ "%Y" "%m" "%d" "%H" "%M" "%S" ];

  ### Generating the configuration from here

  cfg = config.services.znapzend;

  onOff = b: if b then "on" else "off";
  nullOff = b: if b == null then "off" else toString b;
  stripSlashes = replaceStrings [ "/" ] [ "." ];

  attrsToFile = config: concatStringsSep "\n" (builtins.attrValues (
    mapAttrs (n: v: "${n}=${v}") config));

  mkDestAttrs = dst: with dst;
    mapAttrs' (n: v: nameValuePair "dst_${label}${n}" v) ({
      "" = optionalString (host != null) "${host}:" + dataset;
      _plan = plan;
    } // optionalAttrs (presend != null) {
      _precmd = presend;
    } // optionalAttrs (postsend != null) {
      _pstcmd = postsend;
    });

  mkSrcAttrs = srcCfg: with srcCfg; {
    enabled = onOff enable;
    mbuffer = with mbuffer; if enable then "${pkgs.mbuffer}/bin/mbuffer"
        + optionalString (port != null) ":${toString port}" else "off";
    mbuffer_size = mbuffer.size;
    post_znap_cmd = nullOff postsnap;
    pre_znap_cmd = nullOff presnap;
    recursive = onOff recursive;
    src = dataset;
    src_plan = plan;
    tsformat = timestampFormat;
    zend_delay = toString sendDelay;
  } // fold (a: b: a // b) {} (
    map mkDestAttrs (builtins.attrValues destinations)
  );

  files = mapAttrs' (n: srcCfg: let
    fileText = attrsToFile (mkSrcAttrs srcCfg);
  in {
    name = srcCfg.dataset;
    value = pkgs.writeText (stripSlashes srcCfg.dataset) fileText;
  }) cfg.zetup;

  paths = with pkgs; [ config.boot.zfsUserPackage mbuffer openssh ];

  systemPath = concatMapStringsSep ":" (v: "${v}/bin") paths;

  execCommand =
    let
      args = concatStringsSep " " [
        "--logto=${cfg.logTo}"
        "--loglevel=${cfg.logLevel}"
        (optionalString cfg.noDestroy "--nodestroy")
        (optionalString cfg.autoCreation "--autoCreation")
        (optionalString (enabledFeatures != [])
          "--features=${concatStringsSep "," enabledFeatures}")
        ];
    in "${pkgs.znapzend}/bin/znapzend ${args}";

in
{
  imports = [
    <nixpkgs/nixos/modules/services/backup/znapzend.nix>
  ];

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.znapzend ];

    runit.services.znapzend = {
      run = ''
        export PATH="${systemPath}:$PATH"

        ${optionalString cfg.pure ''
          echo Resetting znapzend zetups
          ${pkgs.znapzend}/bin/znapzendzetup list \
            | grep -oP '(?<=\*\*\* backup plan: ).*(?= \*\*\*)' \
            | xargs -I{} ${pkgs.znapzend}/bin/znapzendzetup delete "{}"
        '' + concatStringsSep "\n" (mapAttrsToList (dataset: config: ''
          echo Importing znapzend zetup ${config} for dataset ${dataset}
          ${pkgs.znapzend}/bin/znapzendzetup import --write ${dataset} ${config} &
        '') files) + ''
          wait
        ''}

        exec ${execCommand}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}
