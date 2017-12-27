module OsCtld
  class Commands::Group::List < Commands::Base
    handle :group_list

    def execute
      ret = []

      GroupList.get.each do |grp|
        next if opts[:names] && !opts[:names].include?(grp.name)

        grp.inclusively do
          ret << {
            name: grp.name,
            path: grp.path,
          }
        end
      end

      ok(ret)
    end
  end
end
