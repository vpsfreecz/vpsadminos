{ batchLib }:

{
  batch = {
    release = "6.12.113.2";
    kernelVersion = "6.12.113";
    payloadRevision = 1;
    mode = "additive";
    build = {
      targets = [
        "vmlinux"
        "arch/x86/crypto/crc32c-intel.ko"
        "crypto/crc32c_generic.ko"
        "fs/ceph/ceph.ko"
        "fs/nfsd/nfsd.ko"
        "lib/libcrc32c.ko"
        "net/802/stp.ko"
        "net/bridge/bridge.ko"
        "net/ceph/libceph.ko"
        "net/ipv4/netfilter/nf_defrag_ipv4.ko"
        "net/ipv4/udp_tunnel.ko"
        "net/ipv6/ip6_udp_tunnel.ko"
        "net/ipv6/netfilter/nf_defrag_ipv6.ko"
        "net/llc/llc.ko"
        "net/netfilter/nf_conntrack.ko"
        "net/sctp/sctp.ko"
        "net/sunrpc/auth_gss/auth_rpcgss.ko"
      ];
      expected = {
        callbacks = [ ];
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
          {
            object = "ceph";
            symbol = "ceph_mdsmap_decode";
            sympos = 0;
          }
          {
            object = "ceph";
            symbol = "ceph_update_snap_trace";
            sympos = 0;
          }
          {
            object = "ceph";
            symbol = "parse_reply_info_lease";
            sympos = 1;
          }
          {
            object = "libceph";
            symbol = "ceph_x_add_authorizer_challenge";
            sympos = 1;
          }
          {
            object = "libceph";
            symbol = "ceph_x_decrypt";
            sympos = 1;
          }
          {
            object = "libceph";
            symbol = "mon_dispatch";
            sympos = 1;
          }
          {
            object = "nf_conntrack";
            symbol = "nf_conntrack_tcp_packet";
            sympos = 0;
          }
          {
            object = "nfsd";
            symbol = "client_has_state";
            sympos = 1;
          }
          {
            object = "sctp";
            symbol = "sctp_defaults_exit";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "__x64_sys_pivot_root";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "__ia32_sys_pivot_root";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "__mark_chain_precision";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "__skb_gso_segment";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "__tcf_action_put";
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
            symbol = "do_coredump";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "do_check_common";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "do_move_mount";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "do_misc_fixups";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "do_wait";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "enqueue_to_backlog";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "fib_rebalance";
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
            symbol = "inet_gso_segment";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "io_cqring_wait";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "io_ring_exit_work";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "io_tctx_exit_cb";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "io_uring_cancel_generic";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "io_waitid_wait";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "io_worker_handle_work";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "ip6mr_cache_report";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "ip6mr_cache_unresolved";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "ip_fib_metrics_init";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "ipv6_gso_segment";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "is_sync_callback_calling_insn";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "key_or_keyring_common";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "mark_fastcall_pattern_for_call";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "mark_mounts_for_expiry";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "path_mount";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "path_umount";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "propagate_mount_busy";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "push_callback_call";
            sympos = 1;
          }
          {
            object = "vmlinux";
            symbol = "search_process_keyrings_rcu";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "skb_zerocopy";
            sympos = 0;
          }
          {
            object = "vmlinux";
            symbol = "tcf_idrinfo_destroy";
            sympos = 0;
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
          {
            object = "vmlinux";
            symbol = "zap_pid_ns_processes";
            sympos = 0;
          }
        ];
        imports = [
          ".klp.sym.bridge.__br_multicast_add_group,1"
          ".klp.sym.bridge.__br_multicast_del_group_src,0"
          ".klp.sym.bridge.__br_multicast_send_query,1"
          ".klp.sym.bridge.__grp_src_query_marked_and_rexmit,1"
          ".klp.sym.bridge.__rhashtable_remove_fast.constprop.0.isra.0,1"
          ".klp.sym.bridge.br_mdb_ip_get,0"
          ".klp.sym.bridge.br_mdb_notify,0"
          ".klp.sym.bridge.br_multicast_eht_clean_sets,0"
          ".klp.sym.bridge.br_multicast_eht_handle,0"
          ".klp.sym.bridge.br_multicast_find_group_src,0"
          ".klp.sym.bridge.br_multicast_fwd_src_handle,1"
          ".klp.sym.bridge.br_multicast_fwd_src_remove,1"
          ".klp.sym.bridge.br_multicast_new_group_src,0"
          ".klp.sym.bridge.br_multicast_pg_to_port_ctx,1"
          ".klp.sym.bridge.br_multicast_port_ctx_deinit,0"
          ".klp.sym.bridge.br_multicast_port_ngroups_dec,1"
          ".klp.sym.bridge.br_multicast_rport_del_notify.part.0,1"
          ".klp.sym.bridge.br_sg_port_find,1"
          ".klp.sym.ceph.__ceph_build_xattrs_blob,0"
          ".klp.sym.ceph.__ceph_caps_issued,0"
          ".klp.sym.ceph.__ceph_caps_used,0"
          ".klp.sym.ceph.__ceph_finish_cap_snap,0"
          ".klp.sym.ceph.__cleanup_empty_realms,1"
          ".klp.sym.ceph.__lookup_snap_realm.isra.0,1"
          ".klp.sym.ceph.adjust_snap_realm_parent,1"
          ".klp.sym.ceph.ceph_cap_snap_cachep,0"
          ".klp.sym.ceph.ceph_cap_string,0"
          ".klp.sym.ceph.ceph_create_snap_realm,1"
          ".klp.sym.ceph.ceph_get_snap_realm,0"
          ".klp.sym.ceph.ceph_mds_state_name,0"
          ".klp.sym.ceph.ceph_mdsmap_destroy,0"
          ".klp.sym.ceph.ceph_put_snap_realm,0"
          ".klp.sym.ceph.cmpu64_rev,1"
          ".klp.sym.ceph.dup_array,1"
          ".klp.sym.libceph.__ceph_monc_got_map,1"
          ".klp.sym.libceph.__finish_generic_request,1"
          ".klp.sym.libceph.__send_prepared_auth_request,1"
          ".klp.sym.libceph.ceph_auth_is_authenticated,0"
          ".klp.sym.libceph.ceph_buffer_release,0"
          ".klp.sym.libceph.ceph_check_fsid,0"
          ".klp.sym.libceph.ceph_create_snap_context,0"
          ".klp.sym.libceph.ceph_crypt,0"
          ".klp.sym.libceph.ceph_decode_entity_addr,0"
          ".klp.sym.libceph.ceph_decode_entity_addrvec,0"
          ".klp.sym.libceph.ceph_get_snap_context,0"
          ".klp.sym.libceph.ceph_handle_auth_reply,0"
          ".klp.sym.libceph.ceph_monc_blocklist_add,0"
          ".klp.sym.libceph.ceph_msg_put,0"
          ".klp.sym.libceph.ceph_msg_type_name,0"
          ".klp.sym.libceph.ceph_osdc_handle_map,0"
          ".klp.sym.libceph.ceph_pr_addr,0"
          ".klp.sym.libceph.ceph_put_snap_context,0"
          ".klp.sym.libceph.encrypt_authorizer,1"
          ".klp.sym.libceph.finish_auth,1"
          ".klp.sym.libceph.finish_hunting.part.0,1"
          ".klp.sym.libceph.mon_dispatch.cold,1"
          ".klp.sym.libceph.put_generic_request.part.0,1"
          ".klp.sym.nf_conntrack.__nf_ct_refresh_acct,0"
          ".klp.sym.nf_conntrack.nf_ct_delete,0"
          ".klp.sym.nf_conntrack.nf_ct_kill_acct,0"
          ".klp.sym.nf_conntrack.nf_ct_l4proto_log_invalid,0"
          ".klp.sym.nf_conntrack.nf_ct_seq_offset,0"
          ".klp.sym.nf_conntrack.nf_l4proto_log_invalid,0"
          ".klp.sym.nf_conntrack.nf_tcp_log_invalid,1"
          ".klp.sym.nf_conntrack.tcp_conntrack_names,1"
          ".klp.sym.nf_conntrack.tcp_conntracks,1"
          ".klp.sym.nf_conntrack.tcp_new,1"
          ".klp.sym.nf_conntrack.tcp_options,1"
          ".klp.sym.nf_conntrack.tcp_valid_flags,1"
          ".klp.sym.vmlinux.__SCK__cond_resched,0"
          ".klp.sym.vmlinux.__SCK__might_resched,0"
          ".klp.sym.vmlinux.__SCK__perf_snapshot_branch_stack,0"
          ".klp.sym.vmlinux.__SCK__preempt_schedule,0"
          ".klp.sym.vmlinux.__SCK__preempt_schedule_notrace,0"
          ".klp.sym.vmlinux.__SCK__tp_func_io_uring_cqring_wait,0"
          ".klp.sym.vmlinux.__SCK__tp_func_sched_process_wait,0"
          ".klp.sym.vmlinux.__SCT__tp_func_io_uring_cqring_wait,0"
          ".klp.sym.vmlinux.__SCT__tp_func_sched_process_wait,0"
          ".klp.sym.vmlinux.__btf_type_is_scalar_struct,1"
          ".klp.sym.vmlinux.__check_ptr_off_reg,1"
          ".klp.sym.vmlinux.__check_reg_arg,1"
          ".klp.sym.vmlinux.__do_loopback,1"
          ".klp.sym.vmlinux.__do_wait,0"
          ".klp.sym.vmlinux.__find_kfunc_desc_btf,1"
          ".klp.sym.vmlinux.__io_cqring_overflow_flush,1"
          ".klp.sym.vmlinux.__io_napi_busy_loop,0"
          ".klp.sym.vmlinux.__io_req_task_work_add,0"
          ".klp.sym.vmlinux.__io_run_local_work,1"
          ".klp.sym.vmlinux.__io_sqe_buffers_unregister,0"
          ".klp.sym.vmlinux.__io_sqe_files_unregister,0"
          ".klp.sym.vmlinux.__io_uring_free,0"
          ".klp.sym.vmlinux.__is_kfunc_ptr_arg_type.isra.0,1"
          ".klp.sym.vmlinux.__lookup_mnt,0"
          ".klp.sym.vmlinux.__mark_reg_known,1"
          ".klp.sym.vmlinux.__mark_reg_unknown_imprecise,1"
          ".klp.sym.vmlinux.__msg.0,37"
          ".klp.sym.vmlinux.__msg.1,38"
          ".klp.sym.vmlinux.__msg.2,29"
          ".klp.sym.vmlinux.__msg.3,26"
          ".klp.sym.vmlinux.__put_mountpoint.part.0,1"
          ".klp.sym.vmlinux.__raise_softirq_irqoff,0"
          ".klp.sym.vmlinux.__refcount_sub_and_test.constprop.0,1"
          ".klp.sym.vmlinux.__set_current_blocked,0"
          ".klp.sym.vmlinux.__tracepoint_io_uring_cqring_wait,0"
          ".klp.sym.vmlinux.__tracepoint_sched_process_wait,0"
          ".klp.sym.vmlinux.acct_exit_ns,0"
          ".klp.sym.vmlinux.acquire_reference_state,1"
          ".klp.sym.vmlinux.add_kfunc_in_insns,1"
          ".klp.sym.vmlinux.adjust_jmp_off,1"
          ".klp.sym.vmlinux.arch_vma_name,0"
          ".klp.sym.vmlinux.attach_mnt,1"
          ".klp.sym.vmlinux.attach_recursive_mnt,1"
          ".klp.sym.vmlinux.audit_core_dumps,0"
          ".klp.sym.vmlinux.backlog_napi,1"
          ".klp.sym.vmlinux.bpf_arch_uaddress_limit,0"
          ".klp.sym.vmlinux.bpf_bprintf_prepare,0"
          ".klp.sym.vmlinux.bpf_dev_bound_kfunc_check,0"
          ".klp.sym.vmlinux.bpf_dev_bound_kfunc_id,0"
          ".klp.sym.vmlinux.bpf_dev_bound_resolve_kfunc,0"
          ".klp.sym.vmlinux.bpf_dynptr_from_skb_rdonly,0"
          ".klp.sym.vmlinux.bpf_global_ma_set,0"
          ".klp.sym.vmlinux.bpf_global_percpu_ma,0"
          ".klp.sym.vmlinux.bpf_global_percpu_ma_set,1"
          ".klp.sym.vmlinux.bpf_helper_changes_pkt_data,0"
          ".klp.sym.vmlinux.bpf_jit_add_poke_descriptor,0"
          ".klp.sym.vmlinux.bpf_jit_inlines_helper_call,0"
          ".klp.sym.vmlinux.bpf_jit_supports_exceptions,0"
          ".klp.sym.vmlinux.bpf_jit_supports_far_kfunc_call,0"
          ".klp.sym.vmlinux.bpf_jit_supports_insn,0"
          ".klp.sym.vmlinux.bpf_jit_supports_kfunc_call,0"
          ".klp.sym.vmlinux.bpf_jit_supports_percpu_insn,0"
          ".klp.sym.vmlinux.bpf_jit_supports_ptr_xchg,0"
          ".klp.sym.vmlinux.bpf_jit_supports_subprog_tailcalls,0"
          ".klp.sym.vmlinux.bpf_mem_alloc_percpu_init,0"
          ".klp.sym.vmlinux.bpf_mem_alloc_percpu_unit_init,0"
          ".klp.sym.vmlinux.bpf_patch_insn_data,1"
          ".klp.sym.vmlinux.bpf_percpu_ma_lock,1"
          ".klp.sym.vmlinux.bpf_prog_has_trampoline,0"
          ".klp.sym.vmlinux.bpf_prog_offload_remove_insns,0"
          ".klp.sym.vmlinux.bpf_prog_offload_verify_insn,0"
          ".klp.sym.vmlinux.bpf_remove_insns,0"
          ".klp.sym.vmlinux.bpf_sock_convert_ctx_access,0"
          ".klp.sym.vmlinux.bpf_tcp_sock_convert_ctx_access,0"
          ".klp.sym.vmlinux.bpf_user_rnd_init_once,0"
          ".klp.sym.vmlinux.bpf_verifier_lock,1"
          ".klp.sym.vmlinux.bpf_vlog_reset,0"
          ".klp.sym.vmlinux.bpf_xdp_sock_convert_ctx_access,0"
          ".klp.sym.vmlinux.bt_sync_linked_regs,1"
          ".klp.sym.vmlinux.btf_bpf_map_id,0"
          ".klp.sym.vmlinux.btf_check_subprog_call,1"
          ".klp.sym.vmlinux.btf_distill_func_proto,0"
          ".klp.sym.vmlinux.btf_find_struct_meta,0"
          ".klp.sym.vmlinux.btf_id_cmp_func,2"
          ".klp.sym.vmlinux.btf_is_kernel,0"
          ".klp.sym.vmlinux.btf_is_prog_ctx_type,0"
          ".klp.sym.vmlinux.btf_is_projection_of,0"
          ".klp.sym.vmlinux.btf_name_by_offset,0"
          ".klp.sym.vmlinux.btf_param_match_suffix,0"
          ".klp.sym.vmlinux.btf_parse_vmlinux,0"
          ".klp.sym.vmlinux.btf_prepare_func_args,0"
          ".klp.sym.vmlinux.btf_record_find,0"
          ".klp.sym.vmlinux.btf_resolve_size,0"
          ".klp.sym.vmlinux.btf_struct_ids_match,0"
          ".klp.sym.vmlinux.btf_type_ids_nocast_alias,0"
          ".klp.sym.vmlinux.btf_type_is_void,0"
          ".klp.sym.vmlinux.btf_type_resolve_func_ptr,0"
          ".klp.sym.vmlinux.btf_type_skip_modifiers,0"
          ".klp.sym.vmlinux.btf_type_str,0"
          ".klp.sym.vmlinux.btf_vmlinux,0"
          ".klp.sym.vmlinux.caller_saved,1"
          ".klp.sym.vmlinux.can_change_locked_flags.isra.0,1"
          ".klp.sym.vmlinux.change_mnt_propagation,0"
          ".klp.sym.vmlinux.check_alu_op,1"
          ".klp.sym.vmlinux.check_cond_jmp_op,1"
          ".klp.sym.vmlinux.check_func_arg_reg_off,1"
          ".klp.sym.vmlinux.check_helper_mem_access,1"
          ".klp.sym.vmlinux.check_mem_access,1"
          ".klp.sym.vmlinux.check_mem_reg,1"
          ".klp.sym.vmlinux.check_mem_size_reg,1"
          ".klp.sym.vmlinux.check_ptr_alignment,1"
          ".klp.sym.vmlinux.check_reference_leak,1"
          ".klp.sym.vmlinux.check_reg_const_str,1"
          ".klp.sym.vmlinux.check_reg_type,1"
          ".klp.sym.vmlinux.check_return_code,1"
          ".klp.sym.vmlinux.child_wait_callback,1"
          ".klp.sym.vmlinux.chroot_fs_refs,0"
          ".klp.sym.vmlinux.clear_all_pkt_pointers,1"
          ".klp.sym.vmlinux.clear_caller_saved_regs,1"
          ".klp.sym.vmlinux.cmp_vma_size,1"
          ".klp.sym.vmlinux.cn_esc_printf,1"
          ".klp.sym.vmlinux.cn_print_exe_file,1"
          ".klp.sym.vmlinux.cn_printf,1"
          ".klp.sym.vmlinux.copy_verifier_state,1"
          ".klp.sym.vmlinux.core_dump_count.11,1"
          ".klp.sym.vmlinux.core_name_size,1"
          ".klp.sym.vmlinux.core_pattern,1"
          ".klp.sym.vmlinux.core_pipe_limit,1"
          ".klp.sym.vmlinux.core_sort_vma,1"
          ".klp.sym.vmlinux.core_uses_pid,1"
          ".klp.sym.vmlinux.disable_pid_allocation,0"
          ".klp.sym.vmlinux.disasm_kfunc_name,1"
          ".klp.sym.vmlinux.do_add_mount,1"
          ".klp.sym.vmlinux.do_coredump.cold,1"
          ".klp.sym.vmlinux.do_lock_mount,1"
          ".klp.sym.vmlinux.do_truncate,0"
          ".klp.sym.vmlinux.do_unlinkat,0"
          ".klp.sym.vmlinux.dump_interrupted,1"
          ".klp.sym.vmlinux.event,1"
          ".klp.sym.vmlinux.ex_mountpoints,1"
          ".klp.sym.vmlinux.fc_drop_locked,0"
          ".klp.sym.vmlinux.fetch_kfunc_meta,1"
          ".klp.sym.vmlinux.find_containing_subprog,1"
          ".klp.sym.vmlinux.find_prev_entry,1"
          ".klp.sym.vmlinux.fmt_reg_mask.constprop.0,1"
          ".klp.sym.vmlinux.fmt_stack_mask.constprop.0,1"
          ".klp.sym.vmlinux.free_mnt_ns,1"
          ".klp.sym.vmlinux.free_verifier_state,1"
          ".klp.sym.vmlinux.func_id_name,0"
          ".klp.sym.vmlinux.get_callchain_buffers,0"
          ".klp.sym.vmlinux.get_dynptr_arg_reg,1"
          ".klp.sym.vmlinux.get_gate_vma,0"
          ".klp.sym.vmlinux.get_kern_ctx_btf_id,0"
          ".klp.sym.vmlinux.graft_tree,1"
          ".klp.sym.vmlinux.group_send_sig_info,0"
          ".klp.sym.vmlinux.in_rcu_cs,1"
          ".klp.sym.vmlinux.init_reg_state,1"
          ".klp.sym.vmlinux.invalidate_dynptr,1"
          ".klp.sym.vmlinux.invent_group_ids,1"
          ".klp.sym.vmlinux.io_alloc_cache_free.part.0,1"
          ".klp.sym.vmlinux.io_cancel_ctx_cb,1"
          ".klp.sym.vmlinux.io_cqring_min_timer_wakeup,1"
          ".klp.sym.vmlinux.io_cqring_timer_wakeup,1"
          ".klp.sym.vmlinux.io_destroy_buffers,0"
          ".klp.sym.vmlinux.io_eventfd_unregister,0"
          ".klp.sym.vmlinux.io_futex_cache_free,0"
          ".klp.sym.vmlinux.io_napi_free,0"
          ".klp.sym.vmlinux.io_netmsg_cache_free,0"
          ".klp.sym.vmlinux.io_req_caches_free,1"
          ".klp.sym.vmlinux.io_req_normal_work_add,1"
          ".klp.sym.vmlinux.io_rings_free,1"
          ".klp.sym.vmlinux.io_rsrc_node_destroy,0"
          ".klp.sym.vmlinux.io_run_task_work,1"
          ".klp.sym.vmlinux.io_run_task_work,2"
          ".klp.sym.vmlinux.io_rw_cache_free,0"
          ".klp.sym.vmlinux.io_sq_thread_finish,0"
          ".klp.sym.vmlinux.io_sq_thread_park,0"
          ".klp.sym.vmlinux.io_sq_thread_unpark,0"
          ".klp.sym.vmlinux.io_uring_clean_tctx,0"
          ".klp.sym.vmlinux.io_uring_del_tctx_node,0"
          ".klp.sym.vmlinux.io_uring_drop_tctx_refs,1"
          ".klp.sym.vmlinux.io_uring_try_cancel_requests,1"
          ".klp.sym.vmlinux.io_waitid_cb,1"
          ".klp.sym.vmlinux.io_wake_function,1"
          ".klp.sym.vmlinux.io_wq_cancel_cb,0"
          ".klp.sym.vmlinux.io_wq_enqueue,0"
          ".klp.sym.vmlinux.io_wq_exit_start,0"
          ".klp.sym.vmlinux.ip6mr_cache_free_rcu,1"
          ".klp.sym.vmlinux.ipmr_do_expire_process,1"
          ".klp.sym.vmlinux.is_kfunc_arg_scalar_with_name,1"
          ".klp.sym.vmlinux.is_path_reachable,0"
          ".klp.sym.vmlinux.is_ptr_cast_function,1"
          ".klp.sym.vmlinux.iter_state_str,0"
          ".klp.sym.vmlinux.kallsyms_lookup_name,0"
          ".klp.sym.vmlinux.kernel_wait4,0"
          ".klp.sym.vmlinux.key_type_request_key_auth,0"
          ".klp.sym.vmlinux.kfunc_desc_cmp_by_id_off,1"
          ".klp.sym.vmlinux.kfunc_desc_cmp_by_imm_off,1"
          ".klp.sym.vmlinux.mark_all_scalars_precise,1"
          ".klp.sym.vmlinux.mark_btf_func_reg_size,1"
          ".klp.sym.vmlinux.mark_ptr_not_null_reg.part.0,1"
          ".klp.sym.vmlinux.mark_reg_known_zero.part.0,1"
          ".klp.sym.vmlinux.mark_reg_not_init,1"
          ".klp.sym.vmlinux.mark_reg_read,1"
          ".klp.sym.vmlinux.may_access_direct_pkt_data,1"
          ".klp.sym.vmlinux.may_update_sockmap,1"
          ".klp.sym.vmlinux.mfc_unres_lock,2"
          ".klp.sym.vmlinux.mnt_get_count,0"
          ".klp.sym.vmlinux.mnt_get_writers,1"
          ".klp.sym.vmlinux.mnt_warn_timestamp_expiry,1"
          ".klp.sym.vmlinux.mntns_operations,0"
          ".klp.sym.vmlinux.mntput_no_expire,1"
          ".klp.sym.vmlinux.mount_capable,0"
          ".klp.sym.vmlinux.mount_lock,0"
          ".klp.sym.vmlinux.mount_too_revealing,1"
          ".klp.sym.vmlinux.mr6_netlink_event,1"
          ".klp.sym.vmlinux.mrt_cachep,2"
          ".klp.sym.vmlinux.namespace_sem,1"
          ".klp.sym.vmlinux.namespace_unlock,1"
          ".klp.sym.vmlinux.ns_dentry_operations,0"
          ".klp.sym.vmlinux.parse_monolithic_mount_data,0"
          ".klp.sym.vmlinux.path_mount.cold,1"
          ".klp.sym.vmlinux.pid_child_should_wake,0"
          ".klp.sym.vmlinux.pop_stack,1"
          ".klp.sym.vmlinux.prepare_func_exit,1"
          ".klp.sym.vmlinux.print_bpf_insn,0"
          ".klp.sym.vmlinux.print_insn_state,0"
          ".klp.sym.vmlinux.print_verifier_state,0"
          ".klp.sym.vmlinux.process_dynptr_func,1"
          ".klp.sym.vmlinux.process_iter_arg,1"
          ".klp.sym.vmlinux.process_spin_lock,1"
          ".klp.sym.vmlinux.propagate_mount_busy,0"
          ".klp.sym.vmlinux.propagation_next,1"
          ".klp.sym.vmlinux.propagation_would_overmount,0"
          ".klp.sym.vmlinux.push_insn,1"
          ".klp.sym.vmlinux.push_insn_history,1"
          ".klp.sym.vmlinux.push_stack,1"
          ".klp.sym.vmlinux.put_cred_many.constprop.0,1"
          ".klp.sym.vmlinux.put_filesystem,0"
          ".klp.sym.vmlinux.raise_softirq_irqoff,0"
          ".klp.sym.vmlinux.reconfigure_super,0"
          ".klp.sym.vmlinux.ref_set_non_owning.isra.0,1"
          ".klp.sym.vmlinux.reg2btf_ids,1"
          ".klp.sym.vmlinux.reg_bounds_sanity_check,1"
          ".klp.sym.vmlinux.reg_bounds_sync,1"
          ".klp.sym.vmlinux.reg_btf_record,1"
          ".klp.sym.vmlinux.reg_type_str,0"
          ".klp.sym.vmlinux.release_reference,1"
          ".klp.sym.vmlinux.release_reference_state,1"
          ".klp.sym.vmlinux.save_aux_ptr_type,1"
          ".klp.sym.vmlinux.search_cred_keyrings_rcu,0"
          ".klp.sym.vmlinux.security_sb_kern_mount,0"
          ".klp.sym.vmlinux.security_sb_mount,0"
          ".klp.sym.vmlinux.security_sb_pivotroot,0"
          ".klp.sym.vmlinux.security_sb_umount,0"
          ".klp.sym.vmlinux.set_callee_state,1"
          ".klp.sym.vmlinux.set_compat_user_sigmask,0"
          ".klp.sym.vmlinux.set_find_vma_callback_state,1"
          ".klp.sym.vmlinux.set_loop_callback_state,1"
          ".klp.sym.vmlinux.set_map_elem_callback_state,1"
          ".klp.sym.vmlinux.set_rbtree_add_callback_state,1"
          ".klp.sym.vmlinux.set_timer_callback_state,1"
          ".klp.sym.vmlinux.set_user_ringbuf_callback_state,1"
          ".klp.sym.vmlinux.set_user_sigmask,0"
          ".klp.sym.vmlinux.setup_func_entry,1"
          ".klp.sym.vmlinux.signal_wake_up_state,0"
          ".klp.sym.vmlinux.skb_warn_bad_offload,0"
          ".klp.sym.vmlinux.skb_zerocopy_clone,1"
          ".klp.sym.vmlinux.stack_slot_obj_get_spi,1"
          ".klp.sym.vmlinux.states_equal,1"
          ".klp.sym.vmlinux.sysctl_perf_event_max_stack,0"
          ".klp.sym.vmlinux.task_clear_jobctl_pending,0"
          ".klp.sym.vmlinux.task_work_add,0"
          ".klp.sym.vmlinux.tasklist_lock,0"
          ".klp.sym.vmlinux.tcf_action_cleanup,1"
          ".klp.sym.vmlinux.tcp_ca_get_key_by_name,0"
          ".klp.sym.vmlinux.umh_coredump_setup,1"
          ".klp.sym.vmlinux.umount_tree,1"
          ".klp.sym.vmlinux.unhash_mnt,1"
          ".klp.sym.vmlinux.unshare_files,0"
          ".klp.sym.vmlinux.update_loop_entry,1"
          ".klp.sym.vmlinux.use_backlog_threads_key,1"
          ".klp.sym.vmlinux.uts_proc_notify,0"
          ".klp.sym.vmlinux.uts_sem,0"
          ".klp.sym.vmlinux.verbose,1"
          ".klp.sym.vmlinux.verbose_linfo,0"
          ".klp.sym.vmlinux.visit_func_call_insn,1"
          ".klp.sym.vmlinux.wait_task_inactive,0"
          ".klp.sym.vmlinux.wake_up_state,0"
          ".klp.sym.vmlinux.widen_imprecise_scalars.isra.0,1"
        ];
        relocations = [
          ".klp.rela.bridge..text"
          ".klp.rela.ceph..text"
          ".klp.rela.libceph..text"
          ".klp.rela.nf_conntrack..text"
          ".klp.rela.vmlinux..static_call_sites"
          ".klp.rela.vmlinux..text"
          ".klp.rela.vmlinux.__jump_table"
        ];
        states = [ ];
      };
    };
    fixes = batchLib.discoverFixes ./fixes;
    patches = import ./series.nix;
    lineage = {
      predecessorBatch = {
        release = "6.12.113.1";
        payloadRevision = 1;
      };
      functions = [ ];
      states = [ ];
    };
    runtime = {
      prevention = "preserve ordinary CORE, BPF, storage and network operations across the ordered batch transition";
      removal = "disable and remove batch 2 before batch 1, after the reverse transition converges";
      recovery = "does not repair pre-existing state that a selected fix only prevents from being created";
    };
  };

  qualification = import ./qualification;

  documentation = {
    page = "os/livepatches/6.12.113";
    anchor = "release-6-12-113-2";
  };
}
