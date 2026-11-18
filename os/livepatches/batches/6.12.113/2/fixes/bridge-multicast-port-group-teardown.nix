{
  id = "bridge-multicast-port-group-teardown";
  patchIds = [ "bridge-preserve-multicast-port-teardown-walk" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "e69d4927dacd6ddaff09777a89efc0d3143d3b0d";
    };
    status = "stable";
    upstream = "5a3f7a683aee56e1f15c9d53041f3236767eaae7";
    stable = "e69d4927dacd6ddaff09777a89efc0d3143d3b0d";
  };
  cves = [ "CVE-2026-99117" ];
  prerequisites = [ ];
  functions = [
    {
      object = "bridge";
      symbol = "__br_multicast_del_pg";
      sympos = 1;
    }
    {
      object = "bridge";
      symbol = "__br_multicast_disable_port_ctx";
      sympos = 1;
    }
    {
      object = "bridge";
      symbol = "br_multicast_block.constprop.0";
      sympos = 1;
    }
    {
      object = "bridge";
      symbol = "br_multicast_del_port";
      sympos = 0;
    }
    {
      object = "bridge";
      symbol = "br_multicast_group_src_expired";
      sympos = 1;
    }
    {
      object = "bridge";
      symbol = "br_multicast_port_group_expired";
      sympos = 1;
    }
    {
      object = "bridge";
      symbol = "br_multicast_star_g_handle_mode";
      sympos = 0;
    }
    {
      object = "bridge";
      symbol = "br_multicast_toin.constprop.0";
      sympos = 1;
    }
  ];
  oracleIds = [ "bridge-multicast-operation-safety" ];
}
