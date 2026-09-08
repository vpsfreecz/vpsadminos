require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Su < Commands::Base
    handle :ct_su

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      # Direct lxc-start from this shell needs the same syslog boundary as
      # ordinary startup before LXC can create a child tracing namespace.
      ok(ct_attach(
           ct,
           'bash', '--rcfile', File.join(ct.lxc_dir, '.bashrc'),
           syslogns_tag: ct.syslogns_tag
         ))
    end
  end
end
