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
      sha256 = "11fl3sb0yvd2r8kh6icrzl278d54rs9xq03hn68jvgasvl310adi";
      type = "gem";
    };
    version = "18.09.0.build20190326164203";
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
      sha256 = "0d0bllllbrdnsbggna8zwl3z1mn5rakf6jw3qh0fw1ylj3fpa80c";
      type = "gem";
    };
    version = "18.09.0.build20190326164203";
  };
}