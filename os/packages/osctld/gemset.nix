{
  concurrent-ruby = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0s4fpn3mqiizpmpy2a24k4v365pv75y50292r8ajrv4i1p5b2k14";
      type = "gem";
    };
    version = "1.1.10";
  };
  filelock = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "085vrb6wf243iqqnrrccwhjd4chphfdsybkvjbapa2ipfj1ja1sj";
      type = "gem";
    };
    version = "1.1.1";
  };
  gli = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sxpixpkbwi0g1lp9nv08hb4hw9g563zwxqfxd3nqp9c1ymcv5h3";
      type = "gem";
    };
    version = "2.20.1";
  };
  ipaddress = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1x86s0s11w202j6ka40jbmywkrx8fhq8xiy8mwvnkhllj57hqr45";
      type = "gem";
    };
    version = "0.8.3";
  };
  json = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0yk5d10yvspkc5jyvx9gc1a9pn1z8v4k2hvjk1l88zixwf3wf3cl";
      type = "gem";
    };
    version = "2.6.2";
  };
  libosctl = {
    dependencies = ["rainbow" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0akmhhkskg9r9x19ihh2nb37z52gwxcn617p5fi5sln18a5x9d6m";
      type = "gem";
    };
    version = "21.11.0.build20220927174021";
  };
  netlinkrb = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0lhy9jdvwa9ywj63a7cvmiqx3nxccl7vllsawwmqrwaqgxnqc5ii";
      type = "gem";
    };
    version = "0.18.vpsadminos.0";
  };
  osctl-repo = {
    dependencies = ["filelock" "gli" "json" "libosctl" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "113r0w8a6x9693hf58vkwbk0c2b80q0dyk6s41rwfr6b31dy0d44";
      type = "gem";
    };
    version = "21.11.0.build20220927174021";
  };
  osctld = {
    dependencies = ["concurrent-ruby" "ipaddress" "json" "libosctl" "netlinkrb" "osctl-repo" "osup" "require_all" "ruby-lxc"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1pxsj8q6mv99a4jhxi0nrm1sah8ix3dwq35s5dcyyh249rh6ab5b";
      type = "gem";
    };
    version = "21.11.0.build20220927174021";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1n47xzwspv1c7wxyjvyfs6a9gqbl27889kkp77hml78py3ywy0v2";
      type = "gem";
    };
    version = "21.11.0.build20220927174021";
  };
  rainbow = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0smwg4mii0fm38pyb5fddbmrdpifwv22zv3d3px2xx497am93503";
      type = "gem";
    };
    version = "3.1.1";
  };
  require_all = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0sjf2vigdg4wq7z0xlw14zyhcz4992s05wgr2s58kjgin12bkmv8";
      type = "gem";
    };
    version = "2.0.0";
  };
  ruby-lxc = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1p5zgv5fwdgfrhh7sc8mlcck0ckv73yza9yf1hb1j6q1637xqvv0";
      type = "gem";
    };
    version = "1.2.4.vpsadminos.3";
  };
}
