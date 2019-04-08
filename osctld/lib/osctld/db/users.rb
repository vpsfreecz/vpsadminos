require 'libosctl'
require 'osctld/db/pooled_list'

module OsCtld::DB
  class Users < PooledList
    class << self
      %i(by_name by_ugid).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    def initialize(*_)
      super
      @name_index = OsCtl::Lib::Index.new { |u| u.name }
      @ugid_index = OsCtl::Lib::Index.new { |u| u.ugid }
    end

    def add(user)
      sync do
        OsCtld::UGidRegistry << user.ugid
        super
        @name_index << user
        @ugid_index << user
      end
    end

    def remove(user)
      sync do
        unless OsCtld::SystemUsers.include?(user.sysusername)
          OsCtld::UGidRegistry.remove(user.ugid)
        end

        super
        @name_index.delete(user)
        @ugid_index.delete(user)
        user
      end
    end

    def by_name(name)
      sync { @name_index[name] }
    end

    def by_ugid(ugid)
      sync { @ugid_index[ugid] }
    end
  end
end
