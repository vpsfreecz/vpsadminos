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
      sha256 = "0ljh3yydb637p5b34sj0h3k4jx7gy2jl2m2qkjmz7ypggzajq0qf";
      type = "gem";
    };
    version = "0.1.0.build20180222112125";
  };
  osctl-repo = {
    dependencies = ["filelock" "gli" "json" "libosctl"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1hymb6hrnbz3wpxa1b7s4rigap1ngrdil7rzhdksx8ap6w33pnx8";
      type = "gem";
    };
    version = "0.1.0.build20180222112125";
  };
  osctld = {
    dependencies = ["concurrent-ruby" "ipaddress" "json" "libosctl" "osctl-repo" "ruby-lxc"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1l40q6nz42jj2g1w8srbm0l2m14pkbdw210svczswb6nwnlvq1pz";
      type = "gem";
    };
    version = "0.1.0.build20180222112125";
  };
  ruby-lxc = {
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1n2yf4mi1y6r44hd3bxsj0qfys26s8p3lnr11cb5l9ajm05f7gnm";
      type = "gem";
    };
    version = "1.2.2";
  };
}