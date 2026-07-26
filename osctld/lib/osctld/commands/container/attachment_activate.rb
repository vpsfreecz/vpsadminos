require 'osctld/commands/base'

module OsCtld
  class Commands::Container::AttachmentActivate < Commands::Base
    handle :ct_attachment_activate

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      activated = ct.lifecycle.handoff_attachment(
        opts[:run_id],
        opts[:process_id],
        pid: client_pid
      )
      return error('container attachment reservation is no longer valid') \
        unless activated

      ok
    end
  end
end
