require 'osctld/commands/base'

module OsCtld
  class Commands::Container::List < Commands::Base
    handle :ct_list

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def execute
      ret = []

      DB::Containers.get.each do |ct|
        next if opts[:ids] && !opts[:ids].include?(ct.id)
        next unless include?(ct)

        ret << ct.export
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
      true
    end
  end
end
