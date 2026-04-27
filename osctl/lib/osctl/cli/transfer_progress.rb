require 'json'
require 'ruby-progressbar'

module OsCtl::Cli
  module TransferProgress
    protected

    def with_progress(cmd, progress_title: 'Sending', **opts)
      @progress_title = progress_title

      osctld_call(cmd, **opts) do |msg|
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
    ensure
      @progress_title = nil
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
          title: @progress_title || 'Transfer',
          total: data[:size],
          format: format_str(data[:size]),
          throttle_rate: 0.2,
          starting_at: 0,
          autofinish: false,
          output: $stdout
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
        puts({ type: :update, text: msg }.to_json)
        return
      end

      case msg[:type].to_sym
      when :step
        puts({ type: :step, text: msg[:title] }.to_json)

      when :progress
        puts({ type: :progress, data: msg[:data] }.to_json)
      end
    end
  end
end
