{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.7.14";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/e80eeee9bb7d190d5fe294a60613679acd7e6d0e.tar.gz";
    sha256 = "sha256:0bs8d2ab3k0bgx7iar5prrw4b4v9g7dbg39briblwlfl8yxclrjl";
  };
} // (args.argsOverride or {}))
