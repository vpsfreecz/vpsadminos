{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.53";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/d8955a1bec7d0a5ebbfaa0c0f2442023b9c9dadc.tar.gz";
    sha256 = "00bh4s3y6ra63s2h20inbms5mz0gyq7abpb060sb3vh3yz7rcav7";
  };
} // (args.argsOverride or {}))
