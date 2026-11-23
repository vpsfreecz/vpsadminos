{
  id = "asymmetric-key-missing-id";
  patchIds = [ "asymmetric-keys-reject-trust-keys-without-ids" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "2a40bdd4409567de4c2a141ac66439dc238af752";
    };
    status = "stable";
    upstream = "9695df3b1db4ac4534274d38ee16e3b9b0bf910e";
    stable = "2a40bdd4409567de4c2a141ac66439dc238af752";
  };
  cves = [ "CVE-2026-99220" ];
  prerequisites = [ ];
  functions = [
    {
      object = "vmlinux";
      symbol = "key_or_keyring_common";
      sympos = 1;
    }
  ];
  oracleIds = [ ];
}
