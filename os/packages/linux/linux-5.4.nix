{ stdenv, buildPackages, fetchurl, perl, buildLinux, modDirVersionArg ? null, ... } @ args:

with stdenv.lib;

buildLinux (args // rec {
  version = "5.4.10";

  # modDirVersion needs to be x.y.z, will automatically add .0 if needed
  modDirVersion = if (modDirVersionArg == null) then concatStrings (intersperse "." (take 3 (splitString "." "${version}.0"))) else modDirVersionArg;

  # branchVersion needs to be x.y
  extraMeta.branch = concatStrings (intersperse "." (take 2 (splitString "." version)));

  src = fetchurl {
    url = "https://github.com/vpsfreecz/linux/archive/45d78589746267121634d29e5a11ed077ea4076e.tar.gz";
    sha256 = "sha256:1wj4i35nzlfm55bwxcrx7mbbxlch2jvdh17jsmrhrlnrsvwq1kml";
  };
} // (args.argsOverride or {}))
