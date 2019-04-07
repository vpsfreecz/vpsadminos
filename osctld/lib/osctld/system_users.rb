require 'libosctl'
require 'osctld/lockable'
require 'singleton'

module OsCtld
  # Cache for existing system users
  class SystemUsers
    COMMENT = 'osctl'

    include Lockable
    include Singleton
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    class << self
      %i(add remove include?).each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    def initialize
      init_lock
      @users = []
      load_users
    end

    # Add new user to the system
    # @param name [String]
    # @param ugid [Integer]
    # @param homedir [String]
    def add(name, ugid, homedir)
      fail 'user already exists' if include?(name)
      syscmd("groupadd -g #{ugid} #{name}")
      syscmd("useradd -u #{ugid} -g #{ugid} -d #{homedir} -c #{COMMENT} #{name}")
      exclusively { users << name }
    end

    # Remove user from the system
    # @param name [String]
    def remove(name)
      syscmd("userdel -f #{name}")
      syscmd("groupdel #{name}", valid_rcs: [6])
      exclusively { users.delete(name) }
    end

    # Check if a system user exists
    # @param name [String]
    def include?(name)
      inclusively { users.include?(name) }
    end

    def log_type
      'system-users'
    end

    protected
    attr_reader :users

    def load_users
      exclusively do
        users.clear

        syscmd('getent passwd')[:output].split("\n").each do |line|
          fields = line.split(':')
          name = fields.first
          comment = fields[4]
          users << name if comment == COMMENT
        end
      end
    end
  end
end
