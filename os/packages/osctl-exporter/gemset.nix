{
  curses = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0hic9kq09dhh8jqjx3k1991rnqhlj3glz82w0g7ndcri52m1hgqg";
      type = "gem";
    };
    version = "1.3.2";
  };
  daemons = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0l5gai3vd4g7aqff0k1mp41j9zcsvm2rbwmqn115a325k9r7pf4w";
      type = "gem";
    };
    version = "1.3.1";
  };
  eventmachine = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0wh9aqb0skz80fhfn66lbpr4f86ya2z5rx6gm5xlfhd05bj1ch4r";
      type = "gem";
    };
    version = "1.2.7";
  };
  gli = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sgfc8czb7xk0sdnnz7vn61q4ixbkrpz2mkvcgchfkll94rlqhal";
      type = "gem";
    };
    version = "2.17.2";
  };
  highline = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "01ib7jp85xjc4gh4jg0wyzllm46hwv8p0w1m4c75pbgi41fps50y";
      type = "gem";
    };
    version = "1.7.10";
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
      sha256 = "158fawfwmv2sq4whqqaksfykkiad2xxrrj0nmpnc6vnlzi1bp7iz";
      type = "gem";
    };
    version = "2.3.1";
  };
  libosctl = {
    dependencies = ["rainbow" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1vg3vf6isglzqwqjnvr1k9w4qh2zxzfxfah7qaiz512b89sk6q55";
      type = "gem";
    };
    version = "20.03.0.build20200706212117";
  };
  osctl = {
    dependencies = ["curses" "gli" "highline" "ipaddress" "json" "libosctl" "rainbow" "require_all" "ruby-progressbar"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "159a49y23f5c3399p8zxswy8y76nvvqh7cn7c6b3jan46qk519k9";
      type = "gem";
    };
    version = "20.03.0.build20200706212117";
  };
  osctl-exporter = {
    dependencies = ["json" "libosctl" "osctl" "prometheus-client" "require_all" "thin"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "06wjj3gkz4y1q5mb25vqcz6ifrlkk04yvr621bxw99pycdclicwf";
      type = "gem";
    };
    version = "20.03.0.build20200706212117";
  };
  prometheus-client = {
    dependencies = ["quantile"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0fi69m3i8wnrrfsfl5v4xkgrqjlf0wk2cnp6b5y4hcivjgb55zic";
      type = "gem";
    };
    version = "0.9.0";
  };
  quantile = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1jlddrmmvx9qkh29a1narz81fi41qdrbiif9fd8bl6pxxa9awbi3";
      type = "gem";
    };
    version = "0.2.1";
  };
  rack = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0i5vs0dph9i5jn8dfc6aqd6njcafmb20rwqngrf759c9cvmyff16";
      type = "gem";
    };
    version = "2.2.3";
  };
  rainbow = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0bb2fpjspydr6x0s8pn1pqkzmxszvkfapv0p4627mywl7ky4zkhk";
      type = "gem";
    };
    version = "3.0.0";
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
  ruby-progressbar = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1igh1xivf5h5g3y5m9b4i4j2mhz2r43kngh4ww3q1r80ch21nbfk";
      type = "gem";
    };
    version = "1.9.0";
  };
  thin = {
    dependencies = ["daemons" "eventmachine" "rack"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0nagbf9pwy1vg09k6j4xqhbjjzrg5dwzvkn4ffvlj76fsn6vv61f";
      type = "gem";
    };
    version = "1.7.2";
  };
}