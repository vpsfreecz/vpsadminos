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

        ctid = opts[:as_id] || ct.id

        f = Tempfile.open("ct-#{ct.id}-skel")
        export(
          ct,
          f,
          ctid: ctid,
          user: opts[:as_user] || ct.user.name,
          group: opts[:as_group] || ct.group.name,
          network_interfaces: opts[:network_interfaces],
        )
        f.seek(0)

        m_opts = {
          ctid: ctid,
          port: opts[:port] || 22,
          dst: opts[:dst],
          snapshots: opts.has_key?(:snapshots) ? opts[:snapshots] : true,
        }

        recv_opts = [
          'receive', 'skel',
          opts[:to_pool] ? opts[:to_pool] : '-'
        ]

        recv_opts << opts[:passphrase] if opts[:passphrase]

        ssh = send_ssh_cmd(
          ct.pool.send_receive_key_chain,
          m_opts,
          recv_opts,
        )
        token = nil

        IO.popen("exec #{ssh.join(' ')}", 'r+') do |io|
          io.write(f.readpartial(128*1024)) until f.eof?
          io.close_write
          token = io.readline.strip
        end

        f.close
        f.unlink

        if $?.exitstatus == 0
          ct.open_send_log(:source, token, m_opts)
          ok
        else
          error('send config failed')
        end
      end
    end

    protected
    # @param ct [Container]
    # @param io [IO]
    # @param opts [Hash]
    # @option opts [String] :ctid
    # @option opts [String] :user
    # @option opts [String] :group
    # @option opts [Boolean] :network_interfaces
    def export(ct, io, opts = {})
      exporter = OsCtl::Lib::Exporter::Zfs.new(ct, io)
      exporter.dump_metadata(
        'skel',
        id: opts[:ctid],
        user: opts[:user],
        group: opts[:group],
      )
      exporter.dump_configs do |dump|
        dump.user(File.read(ct.user.config_path))
        dump.group(File.read(ct.group.config_path))

        ct_cfg = ct.dump_config
        ct_cfg.delete('net_interfaces') if !opts[:network_interfaces]
        ct_cfg['user'] = opts[:user]
        ct_cfg['group'] = opts[:group]
        dump.container(YAML.dump(ct_cfg))
      end
      exporter.dump_user_hook_scripts(Container::HookManager.list_all_scripts(ct))
      exporter.close
    end
  end
end
