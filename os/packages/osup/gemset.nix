{
  fiddle = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1as92bp6pgkab73kj3mh5d1idjr9wykczz7r9i1pkn82wq4xks3r";
      type = "gem";
    };
    version = "1.1.6";
  };
  gli = {
    dependencies = ["ostruct"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1c2x5wh3d3mz8vg5bs7c5is0zvc56j6a2b4biv5z1w5hi1n8s3jq";
      type = "gem";
    };
    version = "2.22.2";
  };
  json = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "01lbdaizhkxmrw4y8j3wpvsryvnvzmg0pfs56c52laq2jgdfmq1l";
      type = "gem";
    };
    version = "2.10.2";
  };
  libosctl = {
    dependencies = ["fiddle" "logger" "rainbow" "require_all" "syslog"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0hxn3fl0jp0pdgv2qjm86yrnms62zfms9skkswi6sacnqbp8623m";
      type = "gem";
    };
    version = "24.11.0.build20250315145546";
  };
  logger = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "05s008w9vy7is3njblmavrbdzyrwwc1fsziffdr58w9pwqj8sqfx";
      type = "gem";
    };
    version = "1.6.6";
  };
  ostruct = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "05xqijcf80sza5pnlp1c8whdaay8x5dc13214ngh790zrizgp8q9";
      type = "gem";
    };
    version = "0.6.1";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1yy220r969x5wckc38ka9an91s4njbkinx79j6zr2xpfwyabiicp";
      type = "gem";
    };
    version = "24.11.0.build20250315145546";
  };
  rainbow = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0smwg4mii0fm38pyb5fddbmrdpifwv22zv3d3px2xx497am93503";
      type = "gem";
    };
    version = "3.1.1";
  };
  require_all = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0sjf2vigdg4wq7z0xlw14zyhcz4992s05wgr2s58kjgin12bkmv8";
      type = "gem";
    };
    version = "2.0.0";
  };
  syslog = {
    dependencies = ["logger"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "023lbh48fcn72gwyh1x52ycs1wx1bnhdajmv0qvkidmdsmxnxzjd";
      type = "gem";
    };
    version = "0.3.0";
  };
}
