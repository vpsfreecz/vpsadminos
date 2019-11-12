{ stdenv, buildPackages, fetchurl, perl, buildLinux, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

buildLinux (args // rec {
  version = "5.3.10";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/b66d4b75147733563e0d54d6fe2172fd37c2f7f9.tar.gz";
    sha256 = "sha256:07zm49il6wv1hvr9yrinnvpx9kkkz7mcffnhcc7ysk0n1mx1yrid";
  };
} // (args.argsOverride or {}))
