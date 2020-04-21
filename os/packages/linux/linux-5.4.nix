{ stdenv, buildPackages, fetchurl, perl, buildLinux, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

buildLinux (args // rec {
  version = "5.4.34";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/e0e6d41cbbc49c68ec295f2faecef0432d82be0c.tar.gz";
    sha256 = "sha256:1iz4adskrpvs9k3dwaj7vfmn0z8z0ixb7zrrqrvdy0lv1jragf0s";
  };
} // (args.argsOverride or {}))
