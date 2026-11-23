name:
let
  owned = ./owned + "/${name}/${name}.bpf.c";
in
if builtins.pathExists owned then owned else ./programs + "/${name}.bpf.c"
