{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.0-rc3";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/95e5ed1d05c2eecb02af75af6c57e1cd61bba6ae.tar.gz";
    sha256 = "sha256:0iv7a0sqvsaxnsfm1wsr7cby2avv9qib8aarjx4ladsb03r7vpi2";
  };
} // (args.argsOverride or {}))
