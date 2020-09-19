require 'osctl/cli/command'

module OsCtl::Cli
  class Receive < Command
    def authorized_keys_list
      osctld_fmt(:receive_authkey_list, pool: gopts[:pool])
    end

    def authorized_keys_add
      require_args!('name')
      osctld_fmt(
        :receive_authkey_add,
        pool: gopts[:pool],
        name: args[0],
        public_key: STDIN.readline.strip,
        from: opts['from'],
        ctid: opts['ctid'],
        passphrase: opts['passphrase'],
        single_use: opts['single-use'],
      )
    end

    def authorized_keys_delete
      require_args!('name')
      osctld_fmt(
        :receive_authkey_delete,
        pool: gopts[:pool],
        name: args[0],
      )
    end
  end
end
