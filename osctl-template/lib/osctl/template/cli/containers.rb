require 'json'
require 'libosctl'
require 'osctl/template/cli/command'

module OsCtl::Template
  class Cli::Containers < Cli::Command
    FIELDS = %i(
      pool
      id
      type
      distribution
      version
    )

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      client = OsCtldClient.new

      cts = client.list_containers.select do |ct|
        ct.has_key?(:'org.vpsadminos.osctl-template:type')
      end.map do |ct|
        ct[:type] = ct[:'org.vpsadminos.osctl-template:type']
        ct
      end

      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
        header: !opts['hide-header'],
      }

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      OsCtl::Lib::Cli::OutputFormatter.print(cts, cols, fmt_opts)
    end
  end
end
