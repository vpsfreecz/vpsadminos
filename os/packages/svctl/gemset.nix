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
      sha256 = "0mvlii0wbbb0s81cawg4jg4yrzviz2kw8ffy4mbahad5g5swv4mq";
      type = "gem";
    };
    version = "18.09.0.build20181206174948";
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
      sha256 = "16bybmsndy9dv2yaiwmlrl5ffy2zrxhh7dqd7mzqfsc0c1rjiyy1";
      type = "gem";
    };
    version = "18.09.0.build20181206174948";
  };
}