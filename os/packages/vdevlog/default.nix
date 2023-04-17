{ ruby, runCommand, substituteAll, ronn }:
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

  publish_date=2023-04-17
  mkdir -p $out/share/man/man8
  ${ronn}/bin/ronn \
    --roff \
    --pipe \
    --date $publish_date \
    ${./vdevlog.8.ronn} > $out/share/man/man8/vdevlog.8
''
