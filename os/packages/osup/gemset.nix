{
  gli = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sxpixpkbwi0g1lp9nv08hb4hw9g563zwxqfxd3nqp9c1ymcv5h3";
      type = "gem";
    };
    version = "2.20.1";
  };
  json = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0lrirj0gw420kw71bjjlqkqhqbrplla61gbv1jzgsz6bv90qr3ci";
      type = "gem";
    };
    version = "2.5.1";
  };
  libosctl = {
    dependencies = ["rainbow" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "07mzn72jsv3i64m8zv5jfx75fs10m3d004cx7g086m2w57x21xfx";
      type = "gem";
    };
    version = "21.05.0.build20210726190655";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0wcxz3wr6npxplm80nspk3zy4n1adp73inqwdpb9bgqnc70cf5jm";
      type = "gem";
    };
    version = "21.05.0.build20210726190655";
  };
  rainbow = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0bb2fpjspydr6x0s8pn1pqkzmxszvkfapv0p4627mywl7ky4zkhk";
      type = "gem";
    };
    version = "3.0.0";
  };
  require_all = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0sjf2vigdg4wq7z0xlw14zyhcz4992s05wgr2s58kjgin12bkmv8";
      type = "gem";
    };
    version = "2.0.0";
  };
}
