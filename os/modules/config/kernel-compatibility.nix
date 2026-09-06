{
  config,
  lib,
  ...
}:
let
  beforeLinux618 = lib.versionOlder config.boot.kernelVersion "6.18";
in
{
  boot.kernelModules =
    lib.optionals beforeLinux618 [
      "cifs_arc4"
      "crc32c_generic"
      "crypto_simd"
      "ip6_tables"
      "ip6table_filter"
      "ip6table_mangle"
      "ip6table_nat"
      "ip6table_raw"
      "ip6table_security"
      "ip_tables"
      "iptable_filter"
      "iptable_mangle"
      "iptable_nat"
      "iptable_raw"
      "iptable_security"
      "libcrc32c"
      "libcurve25519_generic"
      "sha1_generic"
      "xt_TRACE"
    ]
    ++ lib.optionals (!beforeLinux618) [
      "crc32c_cryptoapi"
      "libcurve25519"
      "sha1"
    ];
}
