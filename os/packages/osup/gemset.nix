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
      sha256 = "1kvbzh8530pp3qf63zvx9hnb708x7plv9wfn5ibns3h3knnvs3kw";
      type = "gem";
    };
    version = "2.9.0";
  };
  libosctl = {
    dependencies = ["rainbow" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0jrv4fc8id89k03a6gwv594fdpb3whz0xajg51c4mx7x7rayqvms";
      type = "gem";
    };
    version = "24.11.0.build20241217185649";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0ndr8fdjv8qhjabwg154z7m852hpx932c4gf5jlhssj99ln95g3d";
      type = "gem";
    };
    version = "24.11.0.build20241217185649";
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
