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
      sha256 = "1574zsfccblyf6i0yy1qhxakzix2ps6gpzbc0m23ypdw6asz259m";
      type = "gem";
    };
    version = "18.09.0.build20181116134941";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0kb60yv5q9vc7syqbmdp35d4ighc7j92c432mvckxlpy0y9269ar";
      type = "gem";
    };
    version = "18.09.0.build20181116134941";
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