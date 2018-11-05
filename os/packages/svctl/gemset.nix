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
      sha256 = "0ciq85z8l6gfvvhz20r85f17gzm9p24cz2rkpgi5nqh66rl9bhdd";
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
  svctl = {
    dependencies = ["gli" "libosctl"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0c2rqq9ydbqi9jw1q18nr7fxwnqmnpdgj6a6l1jpd5w1nc0hvc0x";
      type = "gem";
    };
    version = "18.09.0.build20181109093506";
  };
}