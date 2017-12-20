module OsCtld
  class Commands::User::SubUGIds < Commands::Base
    handle :user_subugids

    def execute
      UserList.get do |users|
        %w(u g).each do |v|
          File.open("/etc/sub#{v}id.new", 'w') do |f|
            users.each do |u|
              f.write("#{u.sysusername}:#{u.offset}:#{u.size}\n")
            end
          end

          File.rename("/etc/sub#{v}id.new", "/etc/sub#{v}id")
        end
      end

      ok
    end
  end
end
