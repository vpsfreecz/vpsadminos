{ lib, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.76";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/00950bc2d38ff01c03e4bef7b37e595e2b11da7f.tar.gz";
    sha256 = "0cw57ffcaphyk6y1x9ypsbg924k91h1fp2q6ph5xzzi26x7hnh7a";
  };
} // (args.argsOverride or {}))
