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
        File.open(opts[:file], 'w') do |f|
          export(ct, f)
        end

        ok
      end
    end

    protected

    def export(ct, io)
      exporter = OsCtl::Lib::Exporter::Zfs.new(
        ct,
        io,
        compression: opts[:compression] && opts[:compression].to_sym
      )
      exporter.dump_metadata('full')
      exporter.dump_configs
      exporter.dump_user_hook_scripts(Hook::Manager.list_all_scripts(ct))
      exporter.dump_rootfs do
        running_at_start = opts[:consistent] && ct.state == :running

        if opts[:consistent]
          guard_residual_generations!(ct, 'consistent container export')
          unless running_at_start
            guard_no_runtime_generations!(ct, 'consistent container export')
          end
        end

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
