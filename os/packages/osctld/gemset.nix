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
      sha256 = "1iy6vyhm0w75392233by9223cixcj7nrjvbqpp8pl0mxkx3f5z4w";
      type = "gem";
    };
    version = "18.03.0.build20180508175231";
  };
  osctl-repo = {
    dependencies = ["filelock" "gli" "json" "libosctl"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "051a46vvg51fag6h0a1cb4fyflchgk4m3b6s529jff3hjgwfs3mn";
      type = "gem";
    };
    version = "18.03.0.build20180508175231";
  };
  osctld = {
    dependencies = ["concurrent-ruby" "ipaddress" "json" "libosctl" "osctl-repo" "ruby-lxc"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "126rmxyidz811rf1q4qk7fyk1rw3z8qgpz1d7dziygvf7zn1mjrc";
      type = "gem";
    };
    version = "18.03.0.build20180508175231";
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