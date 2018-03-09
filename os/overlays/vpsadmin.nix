vpsadmin: self: super:
{
  nodectld = super.callPackage "${vpsadmin}/packages/nodectld" {};
  nodectl = super.callPackage "${vpsadmin}/packages/nodectl" {};
}
