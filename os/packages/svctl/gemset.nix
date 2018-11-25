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
      sha256 = "07r5pb3j7fiw6nwiplm7vqwad0v0l5h66zvdzqw2y8jnyv46d0aa";
      type = "gem";
    };
    version = "18.09.0.build20181127101403";
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
      sha256 = "04gznr23ys6q2l43yi5b6vw0y6nvm4dzxkn678am8nssgzkz4xp2";
      type = "gem";
    };
    version = "18.09.0.build20181127101403";
  };
}