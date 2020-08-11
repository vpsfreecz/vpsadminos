{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.7.14";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/0ef1cf29f5aa4acdc3760cccf269baf0742e735d.tar.gz";
    sha256 = "sha256:1z6qw3sgnppnajlbxlhv5m8lb1g158z4pzd9qnpgd8dkdy0hp221";
  };
} // (args.argsOverride or {}))
