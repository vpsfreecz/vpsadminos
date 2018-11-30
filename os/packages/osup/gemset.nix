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
      sha256 = "003cda2fw6a2i5hagj3575kmag9bnmzcx7faskc1fylnqzlxydnj";
      type = "gem";
    };
    version = "18.09.0.build20181206174411";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0z9faf1c8kb92pzvpc0al31al1nhwlw37c3kwr40x3zzfxkf9xzn";
      type = "gem";
    };
    version = "18.09.0.build20181206174411";
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