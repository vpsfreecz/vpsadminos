self: super: {
  lxc = super.lxc.override { systemd = null; };
  gnupg = super.gnupg.override {
    guiSupport = false;
    pinentry = null;
    openldap = null;
  };
  util-linux = super.util-linux.override {
    systemdSupport = false;
  };
  dhcpcd = super.dhcpcd.override { withUdev = false; };
}
