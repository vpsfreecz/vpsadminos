require 'libosctl'
require 'osctld/db/pooled_list'

module OsCtld::DB
  class Users < PooledList
    class << self
      %i[by_ugid].each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    def initialize(*_)
      super
      @ugid_index = OsCtl::Lib::Index.new(&:ugid)
    end

    def add(user)
      sync do
        OsCtld::UGidRegistry << user.ugid
        super
        @ugid_index << user
      end
    end

    def remove(user)
      sync do
        unless OsCtld::SystemUsers.include?(user.sysusername)
          OsCtld::UGidRegistry.remove(user.ugid)
        end

        super
        @ugid_index.delete(user)
        user
      end
    end

    def by_ugid(ugid)
      sync { @ugid_index[ugid] }
    end
  end
end
