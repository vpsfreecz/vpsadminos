{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.7.14";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/4e55598d1bf6f6e55eabebad7c7e1bfa5ab8336a.tar.gz";
    sha256 = "sha256:03yibl3xh04wn0i0nfxk9g9avmmb4c128b4iw2vz213kwnw8dm9x";
  };
} // (args.argsOverride or {}))
