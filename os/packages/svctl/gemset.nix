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
      sha256 = "13nl5n4vqj71bp62xzr7ngydz61b9pf5psyn7pyl7pbxjrjnhrda";
      type = "gem";
    };
    version = "18.09.0.build20181109093912";
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
      sha256 = "0cbrf2mnwngrlq7j8r2vqi2m5v5lbsdr9a9vy81b7hbs46zxcqq4";
      type = "gem";
    };
    version = "18.09.0.build20181109093912";
  };
}