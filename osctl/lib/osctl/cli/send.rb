require 'json'
require 'ruby-progressbar'
require 'osctl/cli/command'

module OsCtl::Cli
  class Send < Command
    def key_gen
      c = osctld_open

      unless opts[:force]
        ret = c.cmd_data!(:send_key_path, pool: gopts[:pool])

        %i(public_key private_key).each do |v|
          if File.exist?(ret[v])
            fail "File #{ret[v]} already exists, use -f, --force to overwrite"
          end
        end
      end

      c.cmd_data!(
        :send_key_gen,
        pool: gopts[:pool],
        type: opts[:type],
        bits: opts[:bits]
      )
    end

    def key_path
      if args[0] && !%w(public private).include?(args[0])
        raise GLI::BadCommandLine, "expected public/private, got '#{args[0]}'"
      end

      ret = osctld_call(:send_key_path, pool: gopts[:pool])

      if !args[0] || args[0] == 'public'
        puts ret[:public_key]

      else
        puts ret[:private_key]
      end
    end

    def config
      require_args!('id', 'dst')

      with_progress(
        :ct_send_config,
        pool: gopts[:pool],
        id: args[0],
        dst: args[1],
        port: opts[:port],
        as_id: opts['as-id'],
        to_pool: opts['to-pool'],
        network_interfaces: opts['network-interfaces'],
      )
    end

    def rootfs
      require_args!('id')

      with_progress(
        :ct_send_rootfs,
        pool: gopts[:pool],
        id: args[0]
      )
    end

    def sync
      require_args!('id')

      with_progress(
        :ct_send_sync,
        pool: gopts[:pool],
        id: args[0],
      )
    end

    def state
      require_args!('id')

      with_progress(
        :ct_send_state,
        pool: gopts[:pool],
        id: args[0],
        clone: opts[:clone],
        consistent: opts[:consistent],
        restart: opts[:restart],
        start: opts[:start],
      )
    end

    def cleanup
      require_args!('id')

      with_progress(
        :ct_send_cleanup,
        pool: gopts[:pool],
        id: args[0],
      )
    end

    def cancel
      require_args!('id')

      with_progress(
        :ct_send_cancel,
        pool: gopts[:pool],
        id: args[0],
        force: opts[:force],
        local: opts[:local],
      )
    end

    def now
      require_args!('id', 'dst')

      with_progress(
        :ct_send_now,
        pool: gopts[:pool],
        id: args[0],
        dst: args[1],
        port: opts[:port],
        as_id: opts['as-id'],
        to_pool: opts['to-pool'],
        clone: opts[:clone],
        consistent: opts[:consistent],
        restart: opts[:restart],
        start: opts[:start],
        network_interfaces: opts['network-interfaces'],
      )
    end

    protected
    def with_progress(cmd, opts)
      osctld_call(cmd, opts) do |msg|
        if gopts[:json]
          json_progress(msg)

        else
          terminal_progress(msg)
        end
      end

      @pb.finish if @pb

    rescue OsCtl::Client::Error
      @pb.cancel if @pb
      raise
    end

    def terminal_progress(msg)
      return if gopts[:quiet]

      if msg.is_a?(String)
        if @pb
          @pb.finish
          @pb = nil
        end

        puts "> #{msg}"
        return
      end

      case msg[:type].to_sym
      when :step
        if @pb
          @pb.finish
          @pb = nil
        end

        puts "* #{msg[:title]}"

      when :progress
        data = msg[:data]
        @pb ||= ProgressBar.create(
          title: 'Sending',
          total: data[:size],
          format: format_str(data[:size]),
          throttle_rate: 0.2,
          starting_at: 0,
          autofinish: false,
          output: STDOUT,
        )

        if data[:transfered] > @pb.total
          @pb.total = data[:transfered]
          @pb.format = format_str(@pb.total)
        end

        @pb.progress = data[:transfered]
      end
    end

    def format_str(maxsize)
      "%E %t #{(maxsize / 1024.0).round(2)} GB: [%B] %p%% %r MB/s"
    end

    def json_progress(msg)
      if msg.is_a?(String)
        puts({type: :update, text: msg}.to_json)
        return
      end

      case msg[:type].to_sym
      when :step
        puts({type: :step, text: msg[:title]}.to_json)

      when :progress
        puts({type: :progress, data: msg[:data]}.to_json)
      end
    end
  end
end
