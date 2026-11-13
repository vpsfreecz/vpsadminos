[
  {
    id = "shared-prerequisite";
    path = ./patches/shared-prerequisite.patch;
    fixIds = [
      "fix-a"
      "fix-b"
    ];
  }
  {
    id = "fix-b-change";
    path = ./patches/fix-b-change.patch;
    fixIds = [ "fix-b" ];
  }
]
