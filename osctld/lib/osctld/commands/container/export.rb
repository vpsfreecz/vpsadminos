require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Export < Commands::Logged
    handle :ct_export

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
        exporter.dump_base

        if ct.state == :running && opts[:consistent]
          call_cmd(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)

          exporter.dump_incremental

          call_cmd(
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
