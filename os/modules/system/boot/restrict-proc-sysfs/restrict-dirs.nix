{ ruby, replaceVarsWith, writeText }:
replaceVarsWith {
  src = ./restrict-dirs.rb;
  isExecutable = true;
  replacements = {
    inherit ruby;
  };
}
