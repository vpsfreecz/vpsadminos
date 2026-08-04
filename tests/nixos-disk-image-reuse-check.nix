{
  nixpkgs,
  system,
  testFramework,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

  makeImage =
    {
      testName,
      machineName,
      additionalSpace ? "512M",
    }:
    let
      test =
        import ./make-test.nix
          (
            { ... }:
            {
              name = testName;
              description = "Check NixOS disk image reuse";
              machines.${machineName} = {
                spin = "nixos";
                inherit additionalSpace;
                config.system.stateVersion = "26.05";
              };
              testScript = "";
            }
          )
          {
            pkgs = nixpkgs.outPath;
            inherit system testFramework;
          };
    in
    test.config.machines.${machineName}.diskImage;

  firstImage = makeImage {
    testName = "disk-image-reuse-first";
    machineName = "first";
  };
  renamedImage = makeImage {
    testName = "disk-image-reuse-renamed";
    machineName = "renamed";
  };
  changedImage = makeImage {
    testName = "disk-image-reuse-first";
    machineName = "first";
    additionalSpace = "1G";
  };
in
assert pkgs.lib.assertMsg (firstImage == renamedImage) (
  "identical NixOS machine configurations produced different disk images"
);
assert pkgs.lib.assertMsg (firstImage != changedImage) (
  "different NixOS machine configurations produced the same disk image"
);
pkgs.runCommand "nixos-test-disk-image-reuse" { } ''
  touch $out
''
