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
      sha256 = "0qk9njpglm0id63a1frafx9i0n219nnw4mwj1jgmnq8lk0an76p1";
      type = "gem";
    };
    version = "0.1.0.build20180311212541";
  };
  osctl-repo = {
    dependencies = ["filelock" "gli" "json" "libosctl"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1ndxhj3sx2d6haiq4v0i18mcbjsf0kiglc4aqy6z67yj2kxb17x8";
      type = "gem";
    };
    version = "0.1.0.build20180311212541";
  };
  osctld = {
    dependencies = ["concurrent-ruby" "ipaddress" "json" "libosctl" "osctl-repo" "ruby-lxc"];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0crvldzmgjf6dg6336s1pq65yg6isx3rgzwg8h90mj4f1qg2a962";
      type = "gem";
    };
    version = "0.1.0.build20180311212541";
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