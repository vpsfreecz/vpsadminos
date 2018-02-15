module OsCtl::Lib
  module Utils::Migration
    def migrate_ssh_cmd(key_chain, m_opts, cmd)
      ret = [
        'ssh',
        '-o', 'StrictHostKeyChecking=no',
        '-T',
        '-p', m_opts[:port].to_s,
      ]

      ret.concat(['-i', key_chain.private_key_path]) if key_chain

      ret.concat([
        '-l', 'migration',
        m_opts[:dst],
        *cmd
      ])
    end
  end
end
