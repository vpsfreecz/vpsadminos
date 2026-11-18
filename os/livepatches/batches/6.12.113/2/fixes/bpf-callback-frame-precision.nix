{
  id = "bpf-callback-frame-precision";
  patchIds = [ "bpf-preserve-callback-frame-precision" ];
  provenance = {
    source = {
      repository = "stable/linux";
      commit = "cdc93c6370f792d0649df2a145ac0cdcd430e411";
    };
    status = "stable";
    upstream = "e3e4f66cc4b72333d0886ae2673c360248987889";
    stable = "cdc93c6370f792d0649df2a145ac0cdcd430e411";
  };
  cves = [ "CVE-2026-98084" ];
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
  oracleIds = [ "bpf-callback-frame-precision-operation-safety" ];
}
