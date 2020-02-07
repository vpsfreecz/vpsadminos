{ stdenv, buildPackages, fetchurl, perl, buildLinux, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

buildLinux (args // rec {
  version = "5.4.18";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/dc9d0e67e7d9f17ee77cb2c1fb9ad850780b65be.tar.gz";
    sha256 = "sha256:19zq4if0xy1kx3yza06hilaa3fyq018dqgiplr7l4pb7jh9a168f";
  };
} // (args.argsOverride or {}))
