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
      sha256 = "00dl0dm4js8s7hjg2hbi5hir0nddsdafxs2fn7y44w8n46qcz0yz";
      type = "gem";
    };
    version = "18.09.0.build20181102152554";
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
      sha256 = "0vl26dzl2c5nbkbj8ldmnjl92i7ax4ch3vzz5ic1q3m36iwgkx3d";
      type = "gem";
    };
    version = "18.09.0.build20181102152554";
  };
}