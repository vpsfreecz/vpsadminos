require 'osctld/db/pooled_list'
require 'osctld/net_interface'

module OsCtld::DB
  class Containers < PooledList
    def add(obj)
      OsCtld::NetInterface.sync_host_link_registry do
        OsCtld::NetInterface.validate_container_host_link_claims!(obj)
        super
      end
    end

    def remove(obj)
      OsCtld::NetInterface.sync_host_link_registry do
        OsCtld::NetInterface.validate_container_host_links_released!(obj)
        super
      end
    end
  end
end
