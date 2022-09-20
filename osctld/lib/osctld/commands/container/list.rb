require 'osctld/commands/base'

module OsCtld
  class Commands::Container::List < Commands::Base
    handle :ct_list

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def execute
      ret = []
      hostname_reader = ExecutionPlan.new

      DB::Containers.get.each do |ct|
        next if opts[:ids] && !opts[:ids].include?(ct.id)
        next unless include?(ct)

        data = ct.export

        if opts[:read_hostname]
          if ct.running?
            hostname_reader << [ct, data]
          else
            data[:hostname_readout] = nil
          end
        end

        ret << data
      end

      if opts[:read_hostname] && hostname_reader.length > 0
        hostname_reader.run do |ct, data|
          data[:hostname_readout] = ct.read_hostname
        end

        hostname_reader.wait
      end

      ok(ret)
    end

    protected
    def include?(ct)
      return false if opts[:pool] && !opts[:pool].include?(ct.pool.name)
      return false if opts[:user] && !opts[:user].include?(ct.user.name)
      return false if opts[:group] && !opts[:group].include?(ct.group.name)
      return false if opts[:distribution] && !opts[:distribution].include?(ct.distribution)
      return false if opts[:version] && !opts[:version].include?(ct.version)
      return false if opts[:state] && !opts[:state].include?(ct.state.to_s)
      return false if opts.has_key?(:ephemeral) && !!ct.ephemeral != !!opts[:ephemeral]
      true
    end
  end
end
