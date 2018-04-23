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
      sha256 = "06xapwbdha5bfj7mr3h660mpbdngp653vfwa34rbqyl9m82vj2fs";
      type = "gem";
    };
    version = "18.03.0.build20180424093648";
  };
  osctl-repo = {
    dependencies = ["filelock" "gli" "json" "libosctl"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0647l5s8c7vqi1cm9fxmfm5l5710v7464hj0mn6x93mcpf778amx";
      type = "gem";
    };
    version = "18.03.0.build20180424093648";
  };
  osctld = {
    dependencies = ["concurrent-ruby" "ipaddress" "json" "libosctl" "osctl-repo" "ruby-lxc"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0sbm2nv52bpvynwik93qnz7w8i4xy40z5miznxf9jga096m2f5pc";
      type = "gem";
    };
    version = "18.03.0.build20180424093648";
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