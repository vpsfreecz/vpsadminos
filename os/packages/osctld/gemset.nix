{
  base64 = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "0yx9yn47a8lkfcjmigk79fykxvr80r4m1i35q82sxzynpbm7lcr7";
      type = "gem";
    };
    version = "0.3.0";
  };
  bindata = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "0n4ymlgik3xcg94h52dzmh583ss40rl3sn0kni63v56sq8g6l62k";
      type = "gem";
    };
    version = "2.5.1";
  };
  concurrent-ruby = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "1ipbrgvf0pp6zxdk5ascp6i29aybz2bx9wdrlchjmpx6mhvkwfw1";
      type = "gem";
    };
    version = "1.3.5";
  };
  fiddle = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "1vifygrkw22gcd4wzh8gc4pv6h1zpk6kll6mmprrf5174wvfxa3z";
      type = "gem";
    };
    version = "1.1.8";
  };
  filelock = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "085vrb6wf243iqqnrrccwhjd4chphfdsybkvjbapa2ipfj1ja1sj";
      type = "gem";
    };
    version = "1.1.1";
  };
  gli = {
    dependencies = [ "ostruct" ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "1c2x5wh3d3mz8vg5bs7c5is0zvc56j6a2b4biv5z1w5hi1n8s3jq";
      type = "gem";
    };
    version = "2.22.2";
  };
  ipaddress = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "1x86s0s11w202j6ka40jbmywkrx8fhq8xiy8mwvnkhllj57hqr45";
      type = "gem";
    };
    version = "0.8.3";
  };
  json = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "0s5vklcy2fgdxa9c6da34jbfrqq7xs6mryjglqqb5iilshcg3q82";
      type = "gem";
    };
    version = "2.13.2";
  };
  libosctl = {
    dependencies = [
      "fiddle"
      "logger"
      "rainbow"
      "require_all"
      "syslog"
    ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.vpsfree.cz" ];
      sha256 = "0dxjv4w21ajm0gmy0r1r5n8447mnakrgwxxys46nlx60382a4b3r";
      type = "gem";
    };
    version = "25.05.0.build20250822233506";
  };
  logger = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "00q2zznygpbls8asz5knjvvj2brr3ghmqxgr83xnrdj4rk3xwvhr";
      type = "gem";
    };
    version = "1.7.0";
  };
  netlinkrb = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.vpsfree.cz" ];
      sha256 = "0lhy9jdvwa9ywj63a7cvmiqx3nxccl7vllsawwmqrwaqgxnqc5ii";
      type = "gem";
    };
    version = "0.18.vpsadminos.0";
  };
  osctl-repo = {
    dependencies = [
      "filelock"
      "gli"
      "json"
      "libosctl"
      "require_all"
    ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.vpsfree.cz" ];
      sha256 = "1cqigph58faa5j6mr5gdkv9668nv7998q718sy5df6wxhf3ld7cs";
      type = "gem";
    };
    version = "25.05.0.build20250822233506";
  };
  osctld = {
    dependencies = [
      "base64"
      "bindata"
      "concurrent-ruby"
      "fiddle"
      "ipaddress"
      "json"
      "libosctl"
      "netlinkrb"
      "osctl-repo"
      "osup"
      "require_all"
      "ruby-lxc"
    ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.vpsfree.cz" ];
      sha256 = "0pa9b7wdxhcqscsqvaxgzk4192ibifn2f9jjw0cnzgkzavnic641";
      type = "gem";
    };
    version = "25.05.0.build20250822233506";
  };
  ostruct = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "04nrir9wdpc4izqwqbysxyly8y7hsfr4fsv69rw91lfi9d5fv8lm";
      type = "gem";
    };
    version = "0.6.3";
  };
  osup = {
    dependencies = [
      "gli"
      "json"
      "libosctl"
      "require_all"
    ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.vpsfree.cz" ];
      sha256 = "0pfympr3pmn9yybw62vhi049zfhsgzw2acxfhbl3mjg36vhjbv3c";
      type = "gem";
    };
    version = "25.05.0.build20250822233506";
  };
  rainbow = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "0smwg4mii0fm38pyb5fddbmrdpifwv22zv3d3px2xx497am93503";
      type = "gem";
    };
    version = "3.1.1";
  };
  require_all = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "0sjf2vigdg4wq7z0xlw14zyhcz4992s05wgr2s58kjgin12bkmv8";
      type = "gem";
    };
    version = "2.0.0";
  };
  ruby-lxc = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.vpsfree.cz" ];
      sha256 = "08db047sg211i8agjmc6h9h0li1l16qf9bnmqlgbgbxdsjfddkrj";
      type = "gem";
    };
    version = "1.2.4.vpsadminos.5";
  };
  syslog = {
    dependencies = [ "logger" ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "023lbh48fcn72gwyh1x52ycs1wx1bnhdajmv0qvkidmdsmxnxzjd";
      type = "gem";
    };
    version = "0.3.0";
  };
}
