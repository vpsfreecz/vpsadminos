require 'osctld/commands/base'
require 'osctld/container/lifecycle_finalizer'

module OsCtld
  class Commands::Container::AttachmentFinish < Commands::Base
    handle :ct_attachment_finish

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      completion = ct.lifecycle.finish_external_attachment(
        opts[:run_id],
        opts[:process_id],
        pid: client_pid
      )
      return error('container attachment reservation is no longer valid') \
        unless completion

      _finished, effect_id = completion
      if effect_id
        run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
          conf.run_id.to_s == opts[:run_id].to_s
        end
        if run_conf
          Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id)
        else
          ct.lifecycle.fail_cleanup(
            opts[:run_id],
            effect_id,
            'exact run configuration is missing'
          )
        end
      end

      ok
    end
  end
end
