require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Show < Commands::Base
    handle :ct_show

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')

      data = ct.export
      data[:hostname_readout] = ct.read_hostname if opts[:read_hostname]

      ok(data)
    end
  end
end
