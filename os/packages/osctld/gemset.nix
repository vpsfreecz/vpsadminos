{
  concurrent-ruby = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "183lszf5gx84kcpb779v6a2y0mx9sssy8dgppng1z9a505nj1qcf";
      type = "gem";
    };
    version = "1.0.5";
  };
  filelock = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "085vrb6wf243iqqnrrccwhjd4chphfdsybkvjbapa2ipfj1ja1sj";
      type = "gem";
    };
    version = "1.1.1";
  };
  gli = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0g7g3lxhh2b4h4im58zywj9vcfixfgndfsvp84cr3x67b5zm4kaq";
      type = "gem";
    };
    version = "2.17.1";
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
  libosctl = {
    dependencies = ["require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0hxi5af9m0vsh20g6hxkm90wmd0bl1mpwvid1fcifbzg6ypgv2r8";
      type = "gem";
    };
    version = "18.03.0.build20180717110835";
  };
  osctl-repo = {
    dependencies = ["filelock" "gli" "json" "libosctl" "require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1kjks7l35i4am1f67q7r2d569qnglqhm4kig70523qd42iw490v3";
      type = "gem";
    };
    version = "18.03.0.build20180717110835";
  };
  osctld = {
    dependencies = ["concurrent-ruby" "ipaddress" "json" "libosctl" "osctl-repo" "osup" "require_all" "ruby-lxc"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1vxvffq3pakasz0rqyzdwglmn1lazwdfqbrnvk4j16pxgqqbr03x";
      type = "gem";
    };
    version = "18.03.0.build20180717110835";
  };
  osup = {
    dependencies = ["gli" "json" "libosctl" "require_all"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1vgbpfzirisxmwrdgpjqj0kk3yrj45pqhv3xbbh8sk7jbsl0p49c";
      type = "gem";
    };
    version = "18.03.0.build20180717110835";
  };
  require_all = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0sjf2vigdg4wq7z0xlw14zyhcz4992s05wgr2s58kjgin12bkmv8";
      type = "gem";
    };
    version = "2.0.0";
  };
  ruby-lxc = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0zpmgqldjikpda73za1ppi8z6pywvdv7kml71qri6a875mrn23fp";
      type = "gem";
    };
    version = "1.2.3.vpsadminos.1";
  };
}