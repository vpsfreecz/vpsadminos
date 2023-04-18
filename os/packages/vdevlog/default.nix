{ ruby, runCommand, substituteAll, asciidoctor }:
let
  vdevlog = substituteAll {
    name = "vdevlog";
    src = ./vdevlog.rb;
    isExecutable = true;
    inherit ruby;
  };
in runCommand "vdevlog" {} ''
  mkdir -p $out/bin
  ln -s ${vdevlog} $out/bin/vdevlog

  mkdir -p $out/share/man/man8
  ${asciidoctor}/bin/asciidoctor \
    -b manpage \
    -D $out/share/man/man8 \
    ${./vdevlog.8.adoc}
''
