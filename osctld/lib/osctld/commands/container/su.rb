require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Su < Commands::Base
    handle :ct_su

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ok(ct_attach(ct, 'bash', '--rcfile', File.join(ct.lxc_dir, '.bashrc')))
    end
  end
end
