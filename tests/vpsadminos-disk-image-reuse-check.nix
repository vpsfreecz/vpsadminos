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
      changed ? false,
    }:
    let
      test =
        import ./make-test.nix
          (
            { ... }:
            {
              name = testName;
              description = "Check vpsAdminOS disk image reuse";
              machines.${machineName} = {
                spin = "vpsadminos";
                config = {
                  system.stateVersion = "26.05";
                }
                // pkgs.lib.optionalAttrs changed {
                  environment.etc."disk-image-reuse-marker".text = "changed";
                };
              };
              testScript = "";
            }
          )
          {
            pkgs = nixpkgs.outPath;
            inherit system testFramework;
          };
    in
    test.config.machines.${machineName}.squashfs;

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
    changed = true;
  };
in
assert pkgs.lib.assertMsg (baseImage == renamedTestImage) (
  "changing only the test name produced a different vpsAdminOS disk image"
);
assert pkgs.lib.assertMsg (baseImage == renamedMachineImage) (
  "changing only the machine name produced a different vpsAdminOS disk image"
);
assert pkgs.lib.assertMsg (baseImage != changedImage) (
  "different vpsAdminOS machine configurations produced the same disk image"
);
pkgs.runCommand "vpsadminos-test-disk-image-reuse" { } ''
  touch $out
''
