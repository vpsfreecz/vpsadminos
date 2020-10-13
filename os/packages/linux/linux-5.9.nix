{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.9.0";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/snajpa/linux/archive/a1a7c93dad895998a2249ea4ab6d6ef01be45b38.tar.gz";
    sha256 = "055zijwgimydcvfgarskp12x6y5s6wiq8f158djrby74k7nj30fj";
  };
} // (args.argsOverride or {}))
