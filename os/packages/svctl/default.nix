{ lib, bundlerApp }:

bundlerApp {
  pname = "svctl";
  gemdir = ./.;
  exes = [ "svctl" ];
  postBuild = ''
    mkdir -p $out/share/bash-completion/completions $out/etc
    ln -sf $out/share/bash-completion/completions $out/etc/bash_completion.d
    $out/bin/svctl gen-completion bash > $out/share/bash-completion/completions/svctl
  '';

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}
