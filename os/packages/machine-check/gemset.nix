{
  machine-check = {
    dependencies = ["prometheus-client" "require_all"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "0bkfqymqd6v0l85qp3dxl9sp7d65p7xngx4p3l8a7sn442xf1nbp";
      type = "gem";
    };
    version = "0.3.0";
  };
  prometheus-client = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.vpsfree.cz"];
      sha256 = "1sbi6frbiyl1zznm24mxcpg74igiqfw9w8jy6m5ckhp6rv1n7vbp";
      type = "gem";
    };
    version = "2.1.0";
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
}
