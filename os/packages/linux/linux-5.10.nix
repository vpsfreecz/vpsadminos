{ lib, callPackage, buildPackages, fetchurl, perl, buildLinux, elfutils, modDirVersionArg ? null, ... } @ args:

with lib;

callPackage ./generic.nix (args // rec {
  version = "5.10.52";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/e62edaffe0fda80cfad5efc8067d6def064ec707.tar.gz";
    sha256 = "1si68c2xy9i6pakdj1mcpmnfdpfw6fnr7qj2f4kip0cwd2l12l3z";
  };
} // (args.argsOverride or {}))
