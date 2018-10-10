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
      sha256 = "03jdg3y1mi1076m8g43qdpxdj300rpblq0w91pcxs8dnaspxf7vb";
      type = "gem";
    };
    version = "18.09.0.build20181010201231";
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
      sha256 = "0z18w8p52vilphz5cma567995vw5l1hlal8ps39gc56k6l4wrljs";
      type = "gem";
    };
    version = "18.09.0.build20181010201231";
  };
}