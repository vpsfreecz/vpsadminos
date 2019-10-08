{ stdenv, buildPackages, fetchurl, perl, buildLinux, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

buildLinux (args // rec {
  version = "5.3.5";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/a0d1573a6bebf649898cf8b80dc4394e5ab1af2d.tar.gz";
    sha256 = "1lvwvbfa2cg9ml2lv219wxg71xi8hwb45rfkqr7lyws7mldaf9vk";
  };
} // (args.argsOverride or {}))
