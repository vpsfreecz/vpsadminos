{
  id = "bpf-legacy-load-subprog-precision";
  patchIds = [ "bpf-handle-legacy-load-subprog-exit-precision" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "12c064bcfa56e3631be9f5336ee113b7f849959a";
    };
    status = "stable";
    upstream = "387b1baefbb776e3f48dc2261e77a49213f470f7";
    stable = "12c064bcfa56e3631be9f5336ee113b7f849959a";
  };
  cves = [ "CVE-2026-98085" ];
  prerequisites = [ ];
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
  oracleIds = [ ];
}
