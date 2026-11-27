{
  id = "nfsd-sequence-reply-bounds";
  patchIds = [ "nfsd-preflight-sequence-replies" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "1a5a227bca6a8a9f9d31230697aeb84c62a21da6";
    };
    status = "stable";
    stable = "1a5a227bca6a8a9f9d31230697aeb84c62a21da6";
    upstream = "35ff1a7a7e3835c3e974bc5c45d335897564ceae";
  };
  cves = [ "CVE-2026-99362" ];
  prerequisites = [ ];
  functions = [
    {
      object = "nfsd";
      symbol = "nfsd4_sequence";
      sympos = 0;
    }
  ];
  oracleIds = [ "nfsd-sequence-operation-safety" ];
}
