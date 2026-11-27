{
  id = "nfsd-sequence-reply-preflight";
  patchIds = [ "nfsd-sequence-reply-preflight" ];
  provenance = {
    source = {
      repository = "gregkh/linux";
      commit = "1a5a227bca6a8a9f9d31230697aeb84c62a21da6";
    };
    status = "stable";
    upstream = "35ff1a7a7e3835c3e974bc5c45d335897564ceae";
    stable = "1a5a227bca6a8a9f9d31230697aeb84c62a21da6";
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
