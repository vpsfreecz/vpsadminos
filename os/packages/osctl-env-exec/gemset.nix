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
  curses = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0hdgz18a21wi2hg5aw8abc012ni055jr1fbam0v2r8nsqsnx8dy2";
      type = "gem";
    };
    version = "1.2.4";
  };
  gli = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0g7g3lxhh2b4h4im58zywj9vcfixfgndfsvp84cr3x67b5zm4kaq";
      type = "gem";
    };
    version = "2.17.1";
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
      sha256 = "01v6jjpvh3gnq6sgllpfqahlgxzj50ailwhj9b3cd20hi2dx0vxp";
      type = "gem";
    };
    version = "2.1.0";
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
    dependencies = ["curses" "gli" "highline" "ipaddress" "json" "md2man" "rake" "ruby-progressbar" "yard"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0zifh8ygvdm3jvb5a622crhldyiv72nmd7j5yk4adza2ihwk8mpx";
      type = "gem";
    };
    version = "0.1.0.build20180216183755";
  };
  rake = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "190p7cs8zdn07mjj6xwwsdna3g0r98zs4crz7jh2j2q5b0nbxgjf";
      type = "gem";
    };
    version = "12.3.0";
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
      sha256 = "1sfhy0xxqjnzqa7qxmpz1bmy0mzcr55qyvi410gsb6d6i4ialbw3";
      type = "gem";
    };
    version = "3.1.1";
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
      sha256 = "11x58w0ccayvgy0lmhfyrzxd33ya1v41prh5zzhvaajhw8vr74lh";
      type = "gem";
    };
    version = "0.9.12";
  };
}