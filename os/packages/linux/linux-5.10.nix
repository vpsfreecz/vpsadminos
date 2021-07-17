{ lib, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.50";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/2cc6a25308bdea38fc0b2bcdaefef08cbe87f5bc.tar.gz";
    sha256 = "0mj3bkidywpgparm8kv79clxav9cbmc67wgjd446yh9irhvcdsvq";
  };
} // (args.argsOverride or {}))
