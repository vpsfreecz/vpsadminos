require 'json'

module OsCtl::Cli
  module Assets
    def print_assets(cmd, cmd_opts)
      data = osctld_call(cmd, cmd_opts)
      cols = [
        :type,
        :path,
        :valid,
        {
          name: :purpose,
          label: 'PURPOSE',
          display: ->(_, asset) { asset[:opts][:desc] },
        },
      ]

      if opts[:verbose]
        cols << {
          name: :errors,
          label: 'ERRORS',
          display: ->(_, asset) { asset[:errors].join('; ') },
        }
      end

      if gopts[:parsable]
        puts data.to_json
      else
        OutputFormatter.print(data, cols, layout: :columns)
      end
    end
  end
end
