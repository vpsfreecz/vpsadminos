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
      sha256 = "0dhrkfqqzbqbvcvhv0nmbqm2mmbp7g4azxw79cw13x6g7lngqq5k";
      type = "gem";
    };
    version = "18.09.0.build20181109093714";
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
      sha256 = "01bzbl2df1ix2jhdd86lzyx01x0rk15h0ck7n3vq2f46wiri5c6q";
      type = "gem";
    };
    version = "18.09.0.build20181109093714";
  };
}