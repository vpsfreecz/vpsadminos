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
      sha256 = "16jm936jjlz6mnvrklcld5i32cqjz0cs2cqkkagaxbsr9lsw16zf";
      type = "gem";
    };
    version = "18.09.0.build20181127101449";
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
      sha256 = "0h1gb1cc6pwz0yp541ypkfs7mkwkb3ppdnw55mkzgi3vsj592rwn";
      type = "gem";
    };
    version = "18.09.0.build20181127101449";
  };
}