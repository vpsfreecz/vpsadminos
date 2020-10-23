{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.9.0";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/snajpa/linux/archive/520d7936ecf7522fe04f7d585b345ff45b5f3a4a.tar.gz";
    sha256 = "sha256:033nvpg36zjiqy9d3da0ifp7yx5mm0sf6la382565y8l1110v5a7";
  };
} // (args.argsOverride or {}))
