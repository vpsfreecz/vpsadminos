{
  binman = {
    dependencies = ["opener"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1wn4myh5ir80j6xmvrbz6hrq47m9p4l6yd6nyk1g1r9klds52yvn";
      type = "gem";
    };
    version = "5.1.0";
  };
  gli = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sxpixpkbwi0g1lp9nv08hb4hw9g563zwxqfxd3nqp9c1ymcv5h3";
      type = "gem";
    };
    version = "2.20.1";
  };
  highline = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0yclf57n2j3cw8144ania99h1zinf8q3f5zrhqa754j6gl95rp9d";
      type = "gem";
    };
    version = "2.0.3";
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
      sha256 = "1z9grvjyfz16ag55hg522d3q4dh07hf391sf9s96npc0vfi85xkz";
      type = "gem";
    };
    version = "2.6.1";
  };
  md2man = {
    dependencies = ["binman" "redcarpet" "rouge"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0ii25vxasg3fm93wa2cabl4c8ijqdcdr8if8sd98rv9kix42gpp5";
      type = "gem";
    };
    version = "5.1.2";
  };
  opener = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0ngxijhmcfjv23cp3r0lmnrhya37w8p16bandcw28z59ib4crrbz";
      type = "gem";
    };
    version = "0.1.0";
  };
  osctl-env-exec = {
    dependencies = ["gli" "highline" "ipaddress" "json" "md2man" "rake" "rake-compiler" "ruby-progressbar" "yard"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "15plgvla5cncxcw7fipjdyhqrcamqyjzv4nffk2l1pqa91k9h3hg";
      type = "gem";
    };
    version = "21.11.0.build20220103172453";
  };
  rake = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "15whn7p9nrkxangbs9hh75q585yfn66lv0v2mhj6q6dl6x8bzr2w";
      type = "gem";
    };
    version = "13.0.6";
  };
  rake-compiler = {
    dependencies = ["rake"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "16smqmm5xcvw64mhp3ps2r8r4sd4k19hzvvp1lhmb3rwb11dhlfi";
      type = "gem";
    };
    version = "1.1.6";
  };
  redcarpet = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0bvk8yyns5s1ls437z719y5sdv9fr8kfs8dmr6g8s761dv5n8zvi";
      type = "gem";
    };
    version = "3.5.1";
  };
  rouge = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0530ri0p60km0bg0ib6swkhfnas427cva7vcdmnwl8df52a10y1k";
      type = "gem";
    };
    version = "3.27.0";
  };
  ruby-progressbar = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "02nmaw7yx9kl7rbaan5pl8x5nn0y4j5954mzrkzi9i3dhsrps4nc";
      type = "gem";
    };
    version = "1.11.0";
  };
  webrick = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1d4cvgmxhfczxiq5fr534lmizkhigd15bsx5719r5ds7k7ivisc7";
      type = "gem";
    };
    version = "1.7.0";
  };
  yard = {
    dependencies = ["webrick"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0d08gkis1imlvppyh8dbslk89hwj5af2fmlzvmwahgx2bm48d9sn";
      type = "gem";
    };
    version = "0.9.27";
  };
}
