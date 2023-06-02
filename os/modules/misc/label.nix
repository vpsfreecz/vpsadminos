{ config, lib, ... }:

with lib;

let
  cfg = config.system.vpsadminos;
in

{

  options.system = {

    vpsadminos.label = mkOption {
      type = types.strMatching "[a-zA-Z0-9:_\\.-]*";
      description = lib.mdDoc ''
        vpsAdminOS version name to be used in the names of generated
        outputs and boot labels.

        If you ever wanted to influence the labels in your GRUB menu,
        this is the option for you.

        It can only contain letters, numbers and the following symbols:
        `:`, `_`, `.` and `-`.

        The default is {option}`system.vpsadminos.tags` separated by
        "-" + "-" + {env}`VPSADMINOS_LABEL_VERSION` environment
        variable (defaults to the value of
        {option}`system.vpsadminos.version`).

        Can be overridden by setting {env}`VPSADMINOS_LABEL`.

        Useful for not loosing track of configurations built from different
        vpsadminos branches/revisions, e.g.:

        ```
        #!/bin/sh
        today=`date +%Y%m%d`
        branch=`(cd nixpkgs ; git branch 2>/dev/null | sed -n '/^\* / { s|^\* ||; p; }')`
        revision=`(cd nixpkgs ; git rev-parse HEAD)`
        export VPSADMINOS_LABEL_VERSION="$today.$branch-''${revision:0:7}"
        vpsadminos-rebuild switch
        ```
      '';
    };

    vpsadminos.tags = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "with-xen" ];
      description = lib.mdDoc ''
        Strings to prefix to the default
        {option}`system.vpsadminos.label`.

        Useful for not loosing track of configurations built with
        different options, e.g.:

        ```
        {
          system.vpsadminos.tags = [ "with-xen" ];
          virtualisation.xen.enable = true;
        }
        ```
      '';
    };

  };

  config = {
    # This is set here rather than up there so that changing it would
    # not rebuild the manual
    system.vpsadminos.label = mkDefault (maybeEnv "VPSADMINOS_LABEL"
                                             (concatStringsSep "-" ((sort (x: y: x < y) cfg.tags)
                                              ++ [ (maybeEnv "VPSADMINOS_LABEL_VERSION" cfg.version) ])));
  };

}
