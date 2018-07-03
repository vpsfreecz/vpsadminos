require 'osctl/cli/command'
require 'osctl/cli/assets'

module OsCtl::Cli
  class Self < Command
    include Assets

    def assets
      print_assets(:self_assets)
    end

    def healthcheck
      entities = osctld_call(
        :self_healthcheck,
        all: opts[:all],
        pools: (opts[:all] || args.empty?) ? nil : args
      )

      if gopts[:json]
        puts entities.to_json
        return
      end

      if entities.empty?
        puts 'No errors detected.'
        return
      end

      entities.each do |ent|
        puts "#{ent[:type]} #{ent[:pool] || '-'} #{ent[:id] || '-'}"

        ent[:assets].each do |asset|
          puts "\t#{asset[:type]} #{asset[:path]}: #{asset[:errors].join('; ')}"
        end
      end
    end

    def activate
      osctld_fmt(:self_activate, system: opts[:system], lxcfs: opts[:lxcfs])
    end

    def shutdown
      unless opts[:force]
        STDOUT.write(
          'Do you really wish to stop all containers and export all pools? '+
          '[y/N]: '
        )

        if !%w(y yes).include?(STDIN.readline.strip.downcase)
          puts 'Aborting'
          return
        end
      end

      osctld_fmt(:self_shutdown)
    end
  end
end
