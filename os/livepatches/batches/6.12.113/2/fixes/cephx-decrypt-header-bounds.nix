{
  id = "cephx-decrypt-header-bounds";
  patchIds = [ "cephx-decrypt-header-bounds" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "ebc7eddf6225b87e3aae720875f9dd40cb6b1cef";
    };
    status = "stable";
    upstream = "821365487aa58d06bda65c676ba215d506ba9768";
    stable = "ebc7eddf6225b87e3aae720875f9dd40cb6b1cef";
  };
  cves = [ "CVE-2026-52956" ];
  prerequisites = [ ];
  functions = [
    {
      object = "libceph";
      symbol = "ceph_x_decrypt";
      sympos = 1;
    }
    {
      object = "libceph";
      symbol = "ceph_x_add_authorizer_challenge";
      sympos = 1;
    }
  ];
  oracleIds = [ ];
}
