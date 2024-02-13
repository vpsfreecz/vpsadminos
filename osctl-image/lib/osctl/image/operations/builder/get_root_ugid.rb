require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Builder::GetRootUgid < Operations::Base
    # @return [Builder]
    attr_reader :builder

    # @param builder [Builder]
    def initialize(builder)
      @builder = builder
    end

    # @return [Array(Integer, Integer)] ugid, gid
    def execute
      OsCtldClient.new.batch do |client|
        ct = client.find_container(builder.ctid)
        idmap = client.user_idmap(ct[:user])
        [find_root(idmap, 'uid'), find_root(idmap, 'gid')]
      end
    end

    protected

    def find_root(idmap, type)
      idmap.each do |entry|
        if entry[:type] == type && entry[:ns_id] == 0
          return entry[:host_id]
        end
      end

      raise OperationError, "unable to find root #{type} in id map"
    end
  end
end
