{
  gli = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sgfc8czb7xk0sdnnz7vn61q4ixbkrpz2mkvcgchfkll94rlqhal";
      type = "gem";
    };
    version = "2.17.2";
  };
  json = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "01v6jjpvh3gnq6sgllpfqahlgxzj50ailwhj9b3cd20hi2dx0vxp";
      type = "gem";
    };
    version = "2.1.0";
  };
  libosctl = {
    dependencies = ["require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "06s7sacq53mwdwvfdxfb0p16lv233h1l2n9j0agmz6mzfhz9fpvw";
      type = "gem";
    };
    version = "18.09.0.build20180930173708";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "13ywp1dh1wcjzx8bd9kgrlsi32g1lpqaprcv7z24sy4vzkfl2nwl";
      type = "gem";
    };
    version = "18.09.0.build20180930173708";
  };
  require_all = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0sjf2vigdg4wq7z0xlw14zyhcz4992s05wgr2s58kjgin12bkmv8";
      type = "gem";
    };
    version = "2.0.0";
  };
}