{ python3, replaceVarsWith }:
replaceVarsWith {
  name = "sysinfo-to-json";
  src = ./sysinfo-to-json.py;
  dir = "bin";
  isExecutable = true;
  replacements = {
    inherit python3;
  };
}
