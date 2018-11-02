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
      sha256 = "0428cbxflkg15l4069w7bwq9mr9z4mhjwry3m83371p6pm01rpvi";
      type = "gem";
    };
    version = "18.09.0.build20181102175417";
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
      sha256 = "1vpghq7zba8pspfdjgshh8kr2vxv00826w2sk7rl3j7i4xqk7yfm";
      type = "gem";
    };
    version = "18.09.0.build20181102175417";
  };
}