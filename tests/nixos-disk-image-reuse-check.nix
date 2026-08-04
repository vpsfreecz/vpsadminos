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

  baseImage = makeImage {
    testName = "disk-image-reuse";
    machineName = "machine";
  };
  renamedTestImage = makeImage {
    testName = "disk-image-reuse-renamed";
    machineName = "machine";
  };
  renamedMachineImage = makeImage {
    testName = "disk-image-reuse";
    machineName = "renamed-machine";
  };
  changedImage = makeImage {
    testName = "disk-image-reuse";
    machineName = "machine";
    additionalSpace = "1G";
  };
in
assert pkgs.lib.assertMsg (baseImage == renamedTestImage) (
  "changing only the test name produced a different NixOS disk image"
);
assert pkgs.lib.assertMsg (baseImage == renamedMachineImage) (
  "changing only the machine name produced a different NixOS disk image"
);
assert pkgs.lib.assertMsg (baseImage != changedImage) (
  "different NixOS machine configurations produced the same disk image"
);
pkgs.runCommand "nixos-test-disk-image-reuse" { } ''
  touch $out
''
