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
      sha256 = "0na99x915l2nkb652kjpvgqvg7ddz6zi2wdf3j03xwzgwjb48h7z";
      type = "gem";
    };
    version = "18.09.0.build20190215182212";
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
      sha256 = "168s56kv4xygz89c6rrlda6zimananybsn9z79c4y9r22wh18z0r";
      type = "gem";
    };
    version = "18.09.0.build20190215182212";
  };
}