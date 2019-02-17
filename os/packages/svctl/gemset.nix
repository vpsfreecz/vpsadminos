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
      sha256 = "0ik6ams7hlkqv0wacpf9ghk6nxknpjjrdggzxf3l4v79jqyi89pj";
      type = "gem";
    };
    version = "18.09.0.build20190221200305";
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
      sha256 = "1v4nyd2z04qgjxyqqhqs8f132jxy42wcl3rcp0ba2gdyh7cvbcdn";
      type = "gem";
    };
    version = "18.09.0.build20190221200305";
  };
}