module OsCtl::Lib
  module Utils::Send
    def send_ssh_cmd(key_chain, m_opts, cmd)
      ret = [
        'ssh',
        '-o', 'StrictHostKeyChecking=no',
        '-T',
        '-p', m_opts[:port].to_s
      ]

      ret.push('-i', key_chain.private_key_path) if key_chain

      ret.push(
        '-l', 'osctl-ct-receive',
        m_opts[:dst],
        *cmd
      )
    end
  end
end
