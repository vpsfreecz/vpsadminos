{ lib, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.93";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/5b4d755822c636c4cd51a0fd9d795feb4844c140.tar.gz";
    sha256 = "0c2zxxf6m3p6nn26daxckp3rjambs29j9va8fhps8ll5pr6fnd1p";
  };
} // (args.argsOverride or {}))
