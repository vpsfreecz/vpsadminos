require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtOnStart < UserControl::Commands::Base
    handle :ct_on_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      # Configure network within the CT
      ct.run_conf.dist_configure_network

      Container::Hook.run(ct, :on_start)
      ok

    rescue HookFailed => e
      error(e.message)
    end
  end
end
