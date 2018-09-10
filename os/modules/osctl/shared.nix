{ config, lib, pkgs, utils, ... }:
with lib;
let
  # Get a submodule without any embedded metadata:
  _filter = x: filterAttrs (k: v: k != "_module") x;

  device = { lib, pkgs, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = "";
        example = "/dev/fuse";
        description = "Device name";
      };

      type = mkOption {
        type = types.enum [ "char" "block" ];
        example = "char";
        description = "Device type";
      };

      major = mkOption {
        type = types.str;
        example = "229";
        description = "Device major ID";
      };

      minor = mkOption {
        type = types.str;
        example = "10";
        description = "Device minor ID";
      };

      mode = mkOption {
        type = types.enum [ "r" "rw" "w" "m" "wm" "rm" "rwm" ];
        example = "rwm";
        description = ''
          Device access mode.

          <literal>r</literal> for read, <literal>w</literal> for write
          and <literal>m</literal> for mknod.
        '';
      };

      provide = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Determines whether the device should be provided to descendant groups,
          i.e. whether they should inherit it.
        '';
      };
    };
  };

  cgparam = { lib, pkgs, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        example = "memory.limit_in_bytes";
        description = "CGroup parameter name";
      };
      value = mkOption {
        type = types.str;
        example = "10G";
        apply = x: [ x ];
        description = "CGroup parameter value";
      };
      subsystem =  mkOption {
        type = types.str;
        default = "";
        example = "memory";
        description = ''
          CGroup subsystem name.

          If left empty, it is deduced from cgroup parameter name.
        '';
      };
    };
  };
in
{
  mkDevicesOption = mkOption {
    type = types.listOf (types.submodule device);
    default = [];
    example = [
      { name = "/dev/fuse";
        major = 10;
        minor = 229;
        mode = "rw";
      }
    ];
    apply = x: map _filter x;
    description = ''
      Devices allowed in this group

      See also https://vpsadminos.org/containers/devices/
    '';
  };

  mkCGParamsOption = mkOption {
    type = types.listOf (types.submodule cgparam);
    default = [];
    example = [
      { name = "memory.limit_in_bytes";
        value = "10G";
        subsystem = "memory";
      }
    ];

    apply = x: map _filter x;
    description = ''
      CGroup parameters

      See also https://vpsadminos.org/containers/resources/
    '';
  };

  buildCGroupParams = cgparams: map (p:
    if p.subsystem == "" then
      {
        inherit (p) name value;
        subsystem = elemAt (splitString "." p.name) 0;
      }
    else
      p
  ) cgparams;
}
