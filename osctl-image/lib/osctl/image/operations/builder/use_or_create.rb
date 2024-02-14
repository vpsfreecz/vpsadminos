require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Builder::UseOrCreate < Operations::Base
    # @return [Builder]
    attr_reader :builder

    # @return [String]
    attr_reader :base_dir

    def initialize(builder, base_dir)
      super()
      @builder = builder
      @base_dir = base_dir
    end

    def execute
      client = OsCtldClient.new

      if client.find_container(builder.ctid)
        client.start_container(builder.ctid)
        builder.load_attrs(client)
        Operations::Builder::WaitForNetwork.run(builder)
      else
        Operations::Builder::Create.run(builder, base_dir)
      end
    end
  end
end
