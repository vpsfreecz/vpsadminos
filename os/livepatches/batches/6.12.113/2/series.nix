[
  {
    id = "namespace-check-mounts-before-pivot-parent";
    path = ./patches/namespace-check-mounts-before-pivot-parent.patch;
    fixIds = [ "pivot-root-mount-parent-lifetime" ];
  }
  {
    id = "bpf-factor-atomic-pointer-type-check";
    path = ./patches/bpf-factor-atomic-pointer-type-check.patch;
    fixIds = [ "bpf-atomic-fetch-precision" ];
  }
  {
    id = "bpf-factor-atomic-rmw-check";
    path = ./patches/bpf-factor-atomic-rmw-check.patch;
    fixIds = [ "bpf-atomic-fetch-precision" ];
  }
  {
    id = "bpf-factor-verifier-load-store-checks";
    path = ./patches/bpf-factor-verifier-load-store-checks.patch;
    fixIds = [ "bpf-atomic-fetch-precision" ];
  }
  {
    id = "bpf-track-atomic-fetch-precision";
    path = ./patches/bpf-track-atomic-fetch-precision.patch;
    fixIds = [ "bpf-atomic-fetch-precision" ];
  }
  {
    id = "cephx-decrypt-header-bounds";
    path = ./patches/cephx-decrypt-header-bounds.patch;
    fixIds = [ "cephx-decrypt-header-bounds" ];
  }
  {
    id = "sctp-shutdown-address-work-timer";
    path = ./patches/sctp-shutdown-address-work-timer.patch;
    fixIds = [ "sctp-address-work-teardown" ];
  }
  {
    id = "net-serialize-backlog-enqueue-on-unregister";
    path = ./patches/net-serialize-backlog-enqueue-on-unregister.patch;
    fixIds = [ "network-backlog-unregister-serialization" ];
  }
  {
    id = "ipv6-drop-dst-before-multicast-resolution";
    path = ./patches/ipv6-drop-dst-before-multicast-resolution.patch;
    fixIds = [ "ipv6-multicast-unresolved-dst-lifetime" ];
  }
  {
    id = "bpf-mark-null-call-argument-precise";
    path = ./patches/bpf-mark-null-call-argument-precise.patch;
    fixIds = [ "bpf-null-call-argument-precision" ];
  }
  {
    id = "bpf-preserve-callback-frame-precision";
    path = ./patches/bpf-preserve-callback-frame-precision.patch;
    fixIds = [ "bpf-callback-frame-precision" ];
  }
  {
    id = "bpf-handle-legacy-load-subprog-exit-precision";
    path = ./patches/bpf-handle-legacy-load-subprog-exit-precision.patch;
    fixIds = [ "bpf-legacy-load-subprog-precision" ];
  }
  {
    id = "tc-serialize-action-release-counters";
    path = ./patches/tc-serialize-action-release-counters.patch;
    fixIds = [ "tc-action-release-ordering" ];
  }
  {
    id = "ipv4-guard-zero-weight-fib-rebalance";
    path = ./patches/ipv4-guard-zero-weight-fib-rebalance.patch;
    fixIds = [ "ipv4-fib-rebalance-zero-weight" ];
  }
  {
    id = "bridge-preserve-multicast-port-teardown-walk";
    path = ./patches/bridge-preserve-multicast-port-teardown-walk.patch;
    fixIds = [ "bridge-multicast-port-group-teardown" ];
  }
  {
    id = "io-uring-cancel-stop-local-work-spin";
    path = ./patches/io-uring-cancel-stop-local-work-spin.patch;
    fixIds = [ "io-uring-cancel-local-work" ];
  }
  {
    id = "io-uring-waitid-own-request-before-head-clear";
    path = ./patches/io-uring-waitid-own-request-before-head-clear.patch;
    fixIds = [ "io-waitid-request-ownership" ];
  }
  {
    id = "io-uring-wait-stop-stuck-overflow-spin";
    path = ./patches/io-uring-wait-stop-stuck-overflow-spin.patch;
    fixIds = [ "io-cq-overflow-wait-progress" ];
  }
  {
    id = "io-wq-preserve-exit-signal";
    path = ./patches/io-wq-preserve-exit-signal.patch;
    fixIds = [ "io-wq-exit-signal" ];
  }
  {
    id = "io-uring-limit-cancel-task-work";
    path = ./patches/io-uring-limit-cancel-task-work.patch;
    fixIds = [ "io-uring-cancel-task-work" ];
  }
  {
    id = "keys-check-auth-payload-in-process-search";
    path = ./patches/keys-check-auth-payload-in-process-search.patch;
    fixIds = [ "request-key-auth-payload-lifetime" ];
  }
  {
    id = "asymmetric-keys-reject-trust-keys-without-ids";
    path = ./patches/asymmetric-keys-reject-trust-keys-without-ids.patch;
    fixIds = [ "asymmetric-key-missing-id" ];
  }
  {
    id = "coredump-hold-rcu-releasing-parked-threads";
    path = ./patches/coredump-hold-rcu-releasing-parked-threads.patch;
    fixIds = [ "coredump-parked-task-lifetime" ];
  }
  {
    id = "pidns-make-reaper-waits-freezable";
    path = ./patches/pidns-make-reaper-waits-freezable.patch;
    fixIds = [
      "pidns-freezable-reaper-wait"
      "pidns-livepatch-reaper-progress"
    ];
  }
  {
    id = "signal-localize-no-notify-guard";
    path = ./patches/signal-localize-no-notify-guard.patch;
    fixIds = [ "pidns-livepatch-reaper-progress" ];
  }
  {
    id = "pidns-preserve-reaper-signal-progress";
    path = ./patches/pidns-preserve-reaper-signal-progress.patch;
    fixIds = [ "pidns-livepatch-reaper-progress" ];
  }
  {
    id = "skb-propagate-shared-frag-on-zerocopy";
    path = ./patches/skb-propagate-shared-frag-on-zerocopy.patch;
    fixIds = [ "skb-zerocopy-shared-frag" ];
  }
  {
    id = "net-limit-ip-gso-recursion";
    path = ./patches/net-limit-ip-gso-recursion.patch;
    fixIds = [ "ip-gso-recursion-depth" ];
  }
  {
    id = "conntrack-use-unack-timeout-for-nonclosing-rst";
    path = ./patches/conntrack-use-unack-timeout-for-nonclosing-rst.patch;
    fixIds = [ "conntrack-nonclosing-rst-timeout" ];
  }
  {
    id = "ceph-monitor-command-ack-bounds";
    path = ./patches/ceph-monitor-command-ack-bounds.patch;
    fixIds = [ "ceph-monitor-command-ack-bounds" ];
  }
  {
    id = "ipv4-reject-locked-zero-route-cwnd";
    path = ./patches/ipv4-reject-locked-zero-route-cwnd.patch;
    fixIds = [ "ipv4-route-cwnd-zero" ];
  }
  {
    id = "fs-preserve-busy-propagated-mounts";
    path = ./patches/fs-preserve-busy-propagated-mounts.patch;
    fixIds = [ "propagated-mount-busy-unmount" ];
  }
  {
    id = "namespace-reject-recursive-bind-loop";
    path = ./patches/namespace-reject-recursive-bind-loop.patch;
    fixIds = [ "recursive-bind-namespace-loop" ];
  }
  {
    id = "namespace-never-expire-locked-mount";
    path = ./patches/namespace-never-expire-locked-mount.patch;
    fixIds = [ "mount-expiry-locked-mount" ];
  }
  {
    id = "nfsd-openowner-list-locking";
    path = ./patches/nfsd-openowner-list-locking.patch;
    fixIds = [ "nfsd-openowner-list-locking" ];
  }
  {
    id = "ceph-mdsmap-rank-bounds";
    path = ./patches/ceph-mdsmap-rank-bounds.patch;
    fixIds = [ "ceph-mdsmap-rank-bounds" ];
  }
  {
    id = "ceph-dentry-lease-record-bounds";
    path = ./patches/ceph-dentry-lease-record-bounds.patch;
    fixIds = [ "ceph-dentry-lease-record-bounds" ];
  }
  {
    id = "ceph-snap-trace-count-bounds";
    path = ./patches/ceph-snap-trace-count-bounds.patch;
    fixIds = [ "ceph-snap-trace-count-bounds" ];
  }
]
