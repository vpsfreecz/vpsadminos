{
  gli = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "14m132y05s90zpy5r464vkydl521jy91wfnkbb9hig04k8p87gdv";
      type = "gem";
    };
    version = "2.22.0";
  };
  json = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1kw68hs5jfii7p4pkhsd9nxzsmc9xmb6x8vfp1rczbhxr34sckyx";
      type = "gem";
    };
    version = "2.8.2";
  };
  libosctl = {
    dependencies = ["rainbow" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "172qjgqshahjnvw4spb6sn07xpl91jb16qc9637asfl5mcww22lh";
      type = "gem";
    };
    version = "24.05.0.build20241127093924";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0i8ljqz1761k8g319ymwamxsq8qjgc32zff2nrwn538qhlc9xvbb";
      type = "gem";
    };
    version = "24.05.0.build20241127093924";
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
}
