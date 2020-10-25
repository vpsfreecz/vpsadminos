{ stdenv, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

callPackage ./generic.nix (args // rec {
  version = "5.9.1";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/snajpa/linux/archive/47bcf717f6ce41ba823e9846463a8b75e8ae3a57.tar.gz";
    sha256 = "sha256:19mjwfx0xacza0xdnwrm0g2ghh0n97fjxr4p39p51g38rhlvqddh";
  };
} // (args.argsOverride or {}))
