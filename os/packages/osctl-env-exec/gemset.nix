{
  binman = {
    dependencies = ["opener"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1wn4myh5ir80j6xmvrbz6hrq47m9p4l6yd6nyk1g1r9klds52yvn";
      type = "gem";
    };
    version = "5.1.0";
  };
  gli = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sgfc8czb7xk0sdnnz7vn61q4ixbkrpz2mkvcgchfkll94rlqhal";
      type = "gem";
    };
    version = "2.17.2";
  };
  highline = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "01ib7jp85xjc4gh4jg0wyzllm46hwv8p0w1m4c75pbgi41fps50y";
      type = "gem";
    };
    version = "1.7.10";
  };
  ipaddress = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1x86s0s11w202j6ka40jbmywkrx8fhq8xiy8mwvnkhllj57hqr45";
      type = "gem";
    };
    version = "0.8.3";
  };
  json = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0sx97bm9by389rbzv8r1f43h06xcz8vwi3h5jv074gvparql7lcx";
      type = "gem";
    };
    version = "2.2.0";
  };
  md2man = {
    dependencies = ["binman" "redcarpet" "rouge"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0ii25vxasg3fm93wa2cabl4c8ijqdcdr8if8sd98rv9kix42gpp5";
      type = "gem";
    };
    version = "5.1.2";
  };
  opener = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0ngxijhmcfjv23cp3r0lmnrhya37w8p16bandcw28z59ib4crrbz";
      type = "gem";
    };
    version = "0.1.0";
  };
  osctl-env-exec = {
    dependencies = ["gli" "highline" "ipaddress" "json" "md2man" "rake" "rake-compiler" "ruby-progressbar" "yard"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "01dvrjx8skig9nmqz4n1p6irncgmvv975g6c88mknjh3zpa5wgmw";
      type = "gem";
    };
    version = "0.1.0.build20190406095130";
  };
  rake = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sy5a7nh6xjdc9yhcw31jji7ssrf9v5806hn95gbrzr998a2ydjn";
      type = "gem";
    };
    version = "12.3.2";
  };
  rake-compiler = {
    dependencies = ["rake"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1p8l19pdvwmlgni683s2qa41ls7mc73z31j2gw6r01jsaq0fapbm";
      type = "gem";
    };
    version = "1.0.7";
  };
  redcarpet = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0h9qz2hik4s9knpmbwrzb3jcp3vc5vygp9ya8lcpl7f1l9khmcd7";
      type = "gem";
    };
    version = "3.4.0";
  };
  rouge = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1digsi2s8wyzx8vsqcxasw205lg6s7izx8jypl8rrpjwshmv83ql";
      type = "gem";
    };
    version = "3.3.0";
  };
  ruby-progressbar = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1igh1xivf5h5g3y5m9b4i4j2mhz2r43kngh4ww3q1r80ch21nbfk";
      type = "gem";
    };
    version = "1.9.0";
  };
  yard = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1w0i13a0vsw4jmlj59xn64rdsqcsl9r3rmjjgdca5i51m1q4ix6v";
      type = "gem";
    };
    version = "0.9.19";
  };
}