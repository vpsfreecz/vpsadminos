{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.20";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/2a86bc36a5f719017811f82150586208d38fe863.tar.gz";
    sha256 = "081mp0wlv4pqljk2sx4i97wb3nisj9hbsbbz7p94ixd8nbqqydl7";
  };
} // (args.argsOverride or {}))
