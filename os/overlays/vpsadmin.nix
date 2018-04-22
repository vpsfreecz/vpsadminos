vpsadmin: self: super:
{
  libnodectld = super.callPackage "${vpsadmin}/packages/libnodectld" {};
  nodectld = super.callPackage "${vpsadmin}/packages/nodectld" {};
  nodectl = super.callPackage "${vpsadmin}/packages/nodectl" {};
}
