{ lib, bundlerApp }:

bundlerApp {
  pname = "osup";
  gemdir = ./.;
  exes = [ "osup" ];
  postBuild = ''
    mkdir -p $out/share/bash-completion/completions $out/etc
    ln -sf $out/share/bash-completion/completions $out/etc/bash_completion.d
    $out/bin/osup gen-completion bash > $out/share/bash-completion/completions/osup
  '';

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [ maintainers.sorki ];
    platforms   = platforms.unix;
  };
}
