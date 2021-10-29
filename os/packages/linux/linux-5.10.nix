{ lib, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.76";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/ebabd3509ab49acc919f8f5e8f8b8071484ba7e2.tar.gz";
    sha256 = "0mjk1zq03bk25wp41xp5z1z9326acs22rm1jgf8vsrw244gka25j";
  };
} // (args.argsOverride or {}))
