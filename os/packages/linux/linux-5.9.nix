{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.9.0";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/snajpa/linux/archive/33a663077f314a6bd3f4147c833e5037a96dcb42.tar.gz";
    sha256 = "1kq2mg819xff6idvjrnms2nzkrwar83bp0qyyrhw6r5spxw1mb00";
  };
} // (args.argsOverride or {}))
