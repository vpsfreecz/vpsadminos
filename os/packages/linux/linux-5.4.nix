{ stdenv, buildPackages, fetchurl, perl, buildLinux, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

buildLinux (args // rec {
  version = "5.4.28";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/d809a0d2003e1f244b3f04baff3cc7cc987e1c9f.tar.gz";
    sha256 = "sha256:0bh031frm7vikxxyfgc8c3d91hz1v83din7cdj8q2i0c9ydpk9p1";
  };
} // (args.argsOverride or {}))
