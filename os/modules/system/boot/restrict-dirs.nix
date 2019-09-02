{ data, ruby, substituteAll, writeText }:
substituteAll {
  src = ./restrict-dirs.rb;
  isExecutable = true;
  data = writeText "restrict-dirs.json" (builtins.toJSON data);
  inherit ruby;
}
