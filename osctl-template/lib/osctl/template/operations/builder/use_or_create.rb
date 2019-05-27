require 'libosctl'
require 'osctl/template/operations/base'

module OsCtl::Template
  class Operations::Builder::UseOrCreate < Operations::Base
    # @return [Builder]
    attr_reader :builder

    # @return [String]
    attr_reader :base_dir

    def initialize(builder, base_dir)
      @builder = builder
      @base_dir = base_dir
    end

    def execute
      client = OsCtldClient.new

      if client.find_container(builder.ctid)
        client.start_container(builder.ctid)
        Operations::Builder::WaitForNetwork.run(builder)
      else
        Operations::Builder::Create.run(builder, base_dir)
      end

      builder.attrs = client.find_container(builder.ctid)
    end
  end
end
