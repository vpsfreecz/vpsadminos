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

    def shutdown
      osctld_fmt(:self_shutdown)
    end
  end
end
