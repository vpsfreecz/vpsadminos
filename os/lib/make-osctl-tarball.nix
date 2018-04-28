{ stdenv
, writeText
, rootFs
, metadata
, ctconf
, userconf
, groupconf

, # The file name of the resulting tarball
  fileName ? "nixos-system-${stdenv.system}.osctl"


}:

let
  metaYml = writeText "metadata.yml" (builtins.toJSON metadata);
  ctYml = writeText "container.yml" (builtins.toJSON ctconf);
  userYml = writeText "user.yml" (builtins.toJSON userconf);
  groupYml = writeText "group.yml" (builtins.toJSON groupconf);
in

stdenv.mkDerivation {
  name = "osctl-tarball";
  builder = ./make-osctl-tarball.sh;

  inherit fileName rootFs metaYml ctYml userYml groupYml;
}
