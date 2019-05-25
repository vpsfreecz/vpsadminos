require 'json'
require 'libosctl'
require 'osctl/cli/command'

module OsCtl::Cli
  class History < Command
    def list
      cols = [
        {
          name: :time,
          label: 'TIME',
          display: Proc.new do |t|
            Time.at(t).strftime('%Y-%m-%d %H:%M:%S')
          end,
        },
        :pool,
        {
          name: :cmd,
          label: 'COMMAND',
          display: Proc.new do |cmd, event|
            if event[:opts] && event[:opts][:cli]
              event[:opts][:cli]
            else
              "#{cmd} #{event[:opts]}"
            end
          end,
        },
      ]

      cmd_opts = {}
      cmd_opts[:pools] = args if args.any?
      data = osctld_call(:history_list, cmd_opts)

      if gopts[:json]
        data.each { puts data.to_json }

      else
        OsCtl::Lib::Cli::OutputFormatter.print(data, cols, layout: :columns)
      end
    end
  end
end
