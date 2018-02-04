self: super:
{
  lxc = super.lxc.override { dbus = null; systemd = null; };
  gnupg = super.gnupg.override { guiSupport = false; libusb = null; pinentry = null; openldap = null; };
  utillinux = super.utillinux.override { systemd = null; };
}
