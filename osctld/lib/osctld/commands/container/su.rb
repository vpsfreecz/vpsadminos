require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Su < Commands::Base
    handle :ct_su

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      # LXC recognizes init.scope as the launcher's leaf and places its
      # monitor/payload beneath the parent. Do not launch beneath the exec
      # helper leaf, or later helpers would enter a delegated internal node.
      CGroup.mkpath_all(
        ct.cgroup_path.split('/'),
        delegate_existing: false
      )
      CGroup.subsystems.each do |subsystem|
        CGroup.chown_delegated(
          CGroup.abs_cgroup_path(subsystem, ct.cgroup_path),
          uid: ct.user.ugid,
          gid: ct.root_host_gid,
          unified: subsystem == 'unified'
        )
      end

      # Direct lxc-start from this shell needs the same syslog boundary as
      # ordinary startup before LXC can create a child tracing namespace.
      ok(ct_attach(
           ct,
           'bash', '--rcfile', File.join(ct.lxc_dir, '.bashrc'),
           syslogns_tag: ct.syslogns_tag,
           cgroup_path: File.join(ct.cgroup_path, 'init.scope')
         ))
    end
  end
end
