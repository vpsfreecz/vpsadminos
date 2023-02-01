{ ruby, substituteAll }:
substituteAll {
  name = "vdevlog";
  src = ./vdevlog.rb;
  isExecutable = true;
  dir = "bin";
  inherit ruby;
}
