# Keep this black-box catalog independent of the kernel implementation.
let
  testCase =
    {
      command,
      domain,
      reason ? "corrupt",
      trigger ? "debugfs",
    }:
    {
      inherit
        command
        domain
        reason
        trigger
        ;
    };

  corruption = domain: command: testCase { inherit command domain; };
  credObject = corruption "cred_object";
  selinuxCred = corruption "selinux_cred";
  taskAuthorityFor =
    trigger: command:
    testCase {
      inherit command trigger;
      domain = "task_authority";
    };
  taskAuthority = taskAuthorityFor "debugfs";
  nsproxyAuthority = corruption "nsproxy_authority";
  cssSetAuthority = corruption "css_set_authority";
  cgroupNsRoot =
    command:
    testCase {
      inherit command;
      domain = "cgroup_ns_root";
      reason = "missing endpoint";
    };
  seccompFilter = taskAuthorityFor "seccomp_filter";
in
[
  (credObject "cred_uid")
  (credObject "cred_cap")
  (selinuxCred "selinux_sid")
  (taskAuthority "cred_edge")
  (taskAuthority "real_cred_edge")
  (taskAuthority "nsproxy")
  (nsproxyAuthority "nsproxy_mnt")
  (cgroupNsRoot "nsproxy_cgroup_root")
  (nsproxyAuthority "nsproxy_syslog")
  (nsproxyAuthority "nsproxy_tracing")
  (taskAuthority "cgroups")
  (cssSetAuthority "css_set_dfl")
  (cssSetAuthority "css_set_dom")
  (cssSetAuthority "css_set_subsys")
  (taskAuthority "seccomp")
  (seccompFilter "seccomp_filter")
  (seccompFilter "seccomp_filter_count")
  (taskAuthority "files")
]
