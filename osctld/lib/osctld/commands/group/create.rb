module OsCtld
  class Commands::Group::Create < Commands::Base
    handle :group_create

    include Utils::Log
    include Utils::System

    def execute
      grp = Group.new(opts[:name], load: false)
      return error('group already exists') if GroupList.contains?(grp.name)

      params = grp.import_params(opts[:params])

      grp.exclusively do
        grp.configure(opts[:path], params)
        GroupList.add(grp)
      end

      ok

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end
  end
end
