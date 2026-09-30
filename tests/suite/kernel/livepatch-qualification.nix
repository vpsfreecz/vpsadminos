import ../../make-template.nix (
  {
    vendor,
    profile,
    predecessor,
    iteration ? null,
  }:
  let
    id =
      "${vendor}-${profile}-${predecessor}"
      + (if iteration == null then "" else "-${toString iteration}");
    shapes = {
      fresh = {
        cpus = 4;
        memory = 8192;
        tasks = 128;
        ageSeconds = 0;
      };
      retention = shapes.fresh;
      scale-aged = {
        cpus = 128;
        memory = 16384;
        tasks = 100000;
        ageSeconds = 14400;
      };
      low-memory = {
        cpus = 8;
        memory = 4096;
        tasks = 16384;
        ageSeconds = 0;
      };
      representative = {
        cpus = 8;
        memory = 8192;
        tasks = 16384;
        ageSeconds = 0;
      };
    };
  in
  assert builtins.elem predecessor [
    "v5"
    "v6"
  ];
  assert
    (
      vendor == "amd"
      && builtins.elem profile [
        "scale-aged"
        "low-memory"
        "fresh"
        "retention"
      ]
    )
    || (
      vendor == "intel"
      && builtins.elem profile [
        "representative"
        "retention"
      ]
    );
  assert
    if profile == "fresh" then
      builtins.elem iteration (builtins.genList (i: i + 1) 10)
    else
      iteration == null;
  {
    instance = id;
    test =
      { pkgs }:
      import ./livepatch-6.12.95-common.nix {
        inherit pkgs;
        qualification = shapes.${profile} // {
          inherit id vendor predecessor;
          tag =
            if vendor == "intel" && profile == "retention" then
              "livepatch-intel"
            else if
              builtins.elem profile [
                "fresh"
                "retention"
              ]
            then
              "livepatch-qualification-amd-fresh"
            else
              "livepatch-qualification-${id}";
          transitionSeconds =
            if
              builtins.elem profile [
                "fresh"
                "retention"
              ]
            then
              900
            else
              1800;
          failureRetention = profile == "retention";
        };
      };
  }
)
