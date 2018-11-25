{
  gli = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sgfc8czb7xk0sdnnz7vn61q4ixbkrpz2mkvcgchfkll94rlqhal";
      type = "gem";
    };
    version = "2.17.2";
  };
  libosctl = {
    dependencies = ["require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0m4qxa8xq245klfl7wyxyxi8div06pl4iz8pcbp56j1wmy0prkhi";
      type = "gem";
    };
    version = "18.09.0.build20181127101505";
  };
  require_all = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0sjf2vigdg4wq7z0xlw14zyhcz4992s05wgr2s58kjgin12bkmv8";
      type = "gem";
    };
    version = "2.0.0";
  };
  svctl = {
    dependencies = ["gli" "libosctl"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1jz0ax3qx5raxhfy1a22xvpr3xwq9zgyr1swc72k15g2dl1k95b6";
      type = "gem";
    };
    version = "18.09.0.build20181127101505";
  };
}