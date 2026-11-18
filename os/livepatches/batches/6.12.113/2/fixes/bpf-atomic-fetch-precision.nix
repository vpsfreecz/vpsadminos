{
  id = "bpf-atomic-fetch-precision";
  patchIds = [
    "bpf-factor-atomic-pointer-type-check"
    "bpf-factor-atomic-rmw-check"
    "bpf-factor-verifier-load-store-checks"
    "bpf-track-atomic-fetch-precision"
  ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "7c72e5f3741d1c5cc53439137162f0e09254e6e9";
    };
    status = "stable";
    upstream = "179ee84a89114b854ac2dd1d293633a7f6c8dac1";
    stable = "7c72e5f3741d1c5cc53439137162f0e09254e6e9";
  };
  cves = [ "CVE-2026-43009" ];
  prerequisites = [
    "45dd007c6a06b193ede8592f2fed3b24f0490e7b"
    "ac18f999a73a0c4307ab03701119d2265b0f6bd5"
    "dbc88b9d63ad3d99b3c2888a41af062ef86719da"
  ];
  # GCC emits the selected verifier patches as one mandatory shared closure.
  # This is group ownership, not a minimal per-fix source attribution.
  functions = [
    {
      object = "vmlinux";
      symbol = "__mark_chain_precision";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "add_kfunc_call";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "check_helper_call";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "check_kfunc_call.isra.0";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "check_max_stack_depth_subprog";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "convert_ctx_accesses";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "do_check_common";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "do_misc_fixups";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "get_kfunc_ptr_arg_type";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "in_rbtree_lock_required_cb.isra.0";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "is_sync_callback_calling_insn";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "mark_fastcall_pattern_for_call";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "push_callback_call";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "verifier_remove_insns";
      sympos = 1;
    }
    {
      object = "vmlinux";
      symbol = "visit_insn";
      sympos = 1;
    }
  ];
  oracleIds = [ "bpf-atomic-fetch-precision-operation-safety" ];
}
