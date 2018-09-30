require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPostStop < UserControl::Commands::Base
    handle :ct_post_stop

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      # Unload AppArmor profile and destroy namespace
      ct.apparmor.destroy_namespace
      ct.apparmor.unload_profile

      ct.stopped

      # User-defined hook
      Container::Hook.run(ct, :post_stop)

      ok

    rescue HookFailed => e
      error(e.message)
    end
  end
end
