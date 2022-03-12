# Extend bundlerApp with generated bash completion
{ bundlerApp, lib, runCommand }:
{ pname, bashCompletion ? true, ... } @ args:
let
  app = bundlerApp (removeAttrs args [ "bashCompletion" ]);
in runCommand pname {} ''
  mkdir $out
  ln -s ${app}/bin $out/bin

  mkdir $out/share
  ln -s ${app}/share/man $out/share/man

  ${lib.optionalString bashCompletion ''
  mkdir -p $out/share/bash-completion/completions $out/etc
  ln -sf $out/share/bash-completion/completions $out/etc/bash_completion.d
  ${app}/bin/${pname} gen-completion bash > $out/share/bash-completion/completions/${pname}
  ''}
''
