require 'tempfile'

module OsCtld
  class Commands::Container::MigrateStage < Commands::Base
    handle :ct_migrate_stage

    include OsCtl::Lib::Utils::Migration

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        next error('this container is already being migrated') if ct.migration_log

        f = Tempfile.open("ct-#{ct.id}-skel")
        export(ct, f)
        f.seek(0)

        m_opts = {
          port: opts[:port] || 22,
          dst: opts[:dst],
        }

        ssh = migrate_ssh_cmd(
          ct.pool.migration_key_chain,
          m_opts,
          ['receive', 'skel']
        )

        IO.popen("exec #{ssh.join(' ')}", 'r+') do |io|
          io.write(f.readpartial(16*1024)) until f.eof?
        end

        f.close
        f.unlink

        if $?.exitstatus == 0
          ct.open_migration_log(:source, m_opts)
          ok
        else
          error('stage failed')
        end
      end
    end

    protected
    def export(ct, io)
      exporter = OsCtl::Lib::Exporter::Base.new(ct, io)
      exporter.dump_metadata('skel')
      exporter.dump_configs
      exporter.close
    end
  end
end
