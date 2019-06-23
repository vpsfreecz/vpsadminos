require 'osctld/commands/base'
require 'tempfile'

module OsCtld
  class Commands::Container::SendConfig < Commands::Base
    handle :ct_send_config

    include OsCtl::Lib::Utils::Send

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      manipulate(ct) do
        next error('this container is already being sent') if ct.send_log

        f = Tempfile.open("ct-#{ct.id}-skel")
        export(ct, f)
        f.seek(0)

        m_opts = {
          port: opts[:port] || 22,
          dst: opts[:dst],
        }

        ssh = send_ssh_cmd(
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
          ct.open_send_log(:source, m_opts)
          ok
        else
          error('send config failed')
        end
      end
    end

    protected
    def export(ct, io)
      exporter = OsCtl::Lib::Exporter::Base.new(ct, io)
      exporter.dump_metadata('skel')
      exporter.dump_configs
      exporter.dump_user_hook_scripts(Container::Hook.hooks)
      exporter.close
    end
  end
end
