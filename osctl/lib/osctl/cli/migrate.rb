require 'json'
require 'ruby-progressbar'

module OsCtl::Cli
  class Migrate < Command
    def stage
      require_args!('id', 'dst')

      with_progress(
        :ct_migrate_stage,
        pool: gopts[:pool],
        id: args[0],
        dst: args[1],
        port: opts[:port]
      )
    end

    def sync
      require_args!('id')

      with_progress(
        :ct_migrate_sync,
        pool: gopts[:pool],
        id: args[0]
      )
    end

    def transfer
      require_args!('id')

      with_progress(
        :ct_migrate_transfer,
        pool: gopts[:pool],
        id: args[0]
      )
    end

    def cleanup
      require_args!('id')

      with_progress(
        :ct_migrate_cleanup,
        pool: gopts[:pool],
        id: args[0],
        delete: opts[:delete]
      )
    end

    def cancel
      require_args!('id')

      with_progress(
        :ct_migrate_cancel,
        pool: gopts[:pool],
        id: args[0]
      )
    end

    def now
      require_args!('id', 'dst')

      with_progress(
        :ct_migrate_now,
        pool: gopts[:pool],
        id: args[0],
        dst: args[1],
        port: opts[:port],
        delete: opts[:delete]
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
          title: 'Copying',
          total: nil,
          format: "%E %t #{(data[:size] / 1024).round(2)} GB: [%B] %p%% %r MB/s",
          throttle_rate: 0.2,
          starting_at: 0,
          autofinish: false,
          output: STDOUT,
        )

        @pb.total = @pb.progress > data[:size] ? @pb.progress : data[:size]
        @pb.progress = data[:transfered]
      end
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
