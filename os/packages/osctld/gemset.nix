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
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1igbcykrg6qazam2p3spyxxzq7k9q23kclzzg07xbshqn9f5fwd7";
      type = "gem";
    };
    version = "18.03.0.build20180404091929";
  };
  osctl-repo = {
    dependencies = ["filelock" "gli" "json" "libosctl"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "00vd9lvlx46cf9pviq9lzv164aji10jk8rdpmjgnv548imfpfw5p";
      type = "gem";
    };
    version = "18.03.0.build20180404091929";
  };
  osctld = {
    dependencies = ["concurrent-ruby" "ipaddress" "json" "libosctl" "osctl-repo" "ruby-lxc"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0j6mgx3mb86bpmnmxhdb4gpc70v3h8h86lyfg8nmnbg9y7z43x3m";
      type = "gem";
    };
    version = "18.03.0.build20180404091929";
  };
  ruby-lxc = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1rhkvwc8c4w8928wilv7xhazvn57761n10h2w83plwvi7drci4yg";
      type = "gem";
    };
    version = "1.2.99";
  };
}