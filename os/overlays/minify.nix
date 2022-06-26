self: super:
{
  lxc = super.lxc.override { systemd = null; };
  gnupg = super.gnupg.override { guiSupport = false; pinentry = null; openldap = null; };
  util-linux = super.util-linux.override { systemdSupport = false; systemd = null; };
  dhcpcd = super.dhcpcd.override { udev = null; };
}
