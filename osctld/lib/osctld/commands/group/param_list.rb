module OsCtld
  class Commands::Group::ParamList < Commands::Base
    handle :group_param_list

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      ret = []

      grp.params.each do |p|
        next if opts[:parameters] && !opts[:parameters].include?(p.name)
        next if opts[:subsystem] && !opts[:subsystem].include?(p.subsystem)
        ret << p.export
      end

      ok(ret)
    end
  end
end
