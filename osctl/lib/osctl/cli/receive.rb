require 'osctl/cli/command'

module OsCtl::Cli
  class Receive < Command
    def authorized_keys_list
      keys = osctld_call(:receive_authkey_list, pool: gopts[:pool])

      i = 0

      format_output(keys.map do |key|
        ret = {index: i, key: key}
        i += 1
        ret
      end)
    end

    def authorized_keys_add
      osctld_fmt(
        :receive_authkey_add,
        pool: gopts[:pool],
        public_key: STDIN.readline.strip
      )
    end

    def authorized_keys_delete
      require_args!('index')
      osctld_fmt(
        :receive_authkey_delete,
        pool: gopts[:pool],
        index: args[0].to_i
      )
    end

    def authorized_keys_set
      osctld_fmt(
        :receive_authkey_set,
        pool: gopts[:pool],
        public_keys: read_keys(STDIN),
      )
    end

    protected
    def read_keys(io)
      keys = []
      keys << io.readline.strip until io.eof?
      keys
    end
  end
end
