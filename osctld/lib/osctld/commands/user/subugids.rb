require 'osctld/commands/base'

module OsCtld
  class Commands::User::SubUGIds < Commands::Base
    handle :user_subugids

    @@mutex = Mutex.new

    def execute
      @@mutex.synchronize do
        generate
      end

      ok
    end

    protected

    def generate
      DB::Users.get do |users|
        %w[u g].each do |v|
          File.open("/etc/sub#{v}id.new", 'w') do |f|
            users.each do |u|
              u.send("#{v}id_map").each do |entry|
                f.write("#{u.ugid}:#{entry.host_id}:#{entry.id_count}\n")
              end
            end
          end

          File.rename("/etc/sub#{v}id.new", "/etc/sub#{v}id")
        end
      end
    end
  end
end
