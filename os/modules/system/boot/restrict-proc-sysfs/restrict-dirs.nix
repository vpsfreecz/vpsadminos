{ ruby, substituteAll, writeText }:
substituteAll {
  src = ./restrict-dirs.rb;
  isExecutable = true;
  inherit ruby;
}
