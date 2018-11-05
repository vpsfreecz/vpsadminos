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
      sha256 = "0ciq85z8l6gfvvhz20r85f17gzm9p24cz2rkpgi5nqh66rl9bhdd";
      type = "gem";
    };
    version = "18.09.0.build20181109093506";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0k9q419q4ygh4lh0i1mlzya37yimfcm6b9333yikrwhs5cjl3zgg";
      type = "gem";
    };
    version = "18.09.0.build20181109093506";
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