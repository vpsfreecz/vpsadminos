self: super:
{
  lxc = super.lxc.override { systemd = null; };
  gnupg = super.gnupg.override { guiSupport = false; libusb = null; pinentry = null; openldap = null; };
  utillinux = super.utillinux.override { systemd = null; };
  dhcpcd = super.dhcpcd.override { udev = null; };
  logrotate = super.logrotate.override { mailutils = null; };
}
