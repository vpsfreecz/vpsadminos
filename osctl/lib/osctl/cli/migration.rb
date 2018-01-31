module OsCtl::Cli
  class Migration < Command
    def key_gen
      c = osctld_open

      unless opts[:force]
        ret = c.cmd_data!(:migration_key_path, pool: gopts[:pool])

        %i(public_key private_key).each do |v|
          if File.exist?(ret[v])
            fail "File #{ret[v]} already exists, use -f, --force to overwrite"
          end
        end
      end

      c.cmd_data!(
        :migration_key_gen,
        pool: gopts[:pool],
        type: opts[:type],
        bits: opts[:bits]
      )
    end

    def key_path
      if args[0] && !%w(public private).include?(args[0])
        raise GLI::BadCommandLine, "expected public/private, got '#{args[0]}'"
      end

      ret = osctld_call(:migration_key_path, pool: gopts[:pool])

      if !args[0] || args[0] == 'public'
        puts ret[:public_key]

      else
        puts ret[:private_key]
      end
    end

    def authorized_keys_list
      keys = osctld_call(:migration_authkey_list, pool: gopts[:pool])

      i = 0

      format_output(keys.map do |key|
        ret = {index: i, key: key}
        i += 1
        ret
      end)
    end

    def authorized_keys_add
      osctld_fmt(
        :migration_authkey_add,
        pool: gopts[:pool],
        public_key: STDIN.readline.strip
      )
    end

    def authorized_keys_delete
      require_args!('index')
      osctld_fmt(
        :migration_authkey_delete,
        pool: gopts[:pool],
        index: args[0].to_i
      )
    end
  end
end
