require 'osctld/commands/logged'
require 'osctld/utils/container'

module OsCtld
  class Commands::Container::Export < Commands::Logged
    handle :ct_export

    include Utils::Container

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        running_at_start = opts[:consistent] && ct.runtime_state == :running
        preflight_export!(ct, running_at_start)

        File.open(opts[:file], 'w') do |f|
          export(ct, f, running_at_start:)
        end

        ok
      end
    end

    protected

    def preflight_export!(ct, running_at_start)
      return unless opts[:consistent]

      ensure_config_ready!(ct) if running_at_start
      guard_residual_generations!(ct, 'consistent container export')
      return if running_at_start

      guard_no_runtime_generations!(ct, 'consistent container export')
    end

    def export(ct, io, running_at_start: opts[:consistent] && ct.runtime_state == :running)
      exporter = OsCtl::Lib::Exporter::Zfs.new(
        ct,
        io,
        compression: opts[:compression] && opts[:compression].to_sym
      )
      exporter.dump_metadata('full')
      exporter.dump_configs
      exporter.dump_user_hook_scripts(Hook::Manager.list_all_scripts(ct))
      exporter.dump_rootfs do
        exporter.dump_base

        if running_at_start
          call_cmd!(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)
          guard_no_runtime_generations!(ct, 'consistent container export')

          exporter.dump_incremental

          call_cmd!(
            Commands::Container::Start,
            id: ct.id,
            pool: ct.pool.name,
            force: true
          )
        end
      end

      exporter.close
    end
  end
end
