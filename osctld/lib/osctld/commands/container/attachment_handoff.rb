require 'osctld/commands/base'

module OsCtld
  class Commands::Container::AttachmentHandoff < Commands::Base
    handle :ct_attachment_handoff

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      handed_off = ct.lifecycle.handoff_attachment_child(
        opts[:run_id],
        opts[:process_id],
        pid: client_pid,
        child_pid: opts[:pid]
      )
      return error('container attachment reservation is no longer valid') \
        unless handed_off

      ok
    end
  end
end
