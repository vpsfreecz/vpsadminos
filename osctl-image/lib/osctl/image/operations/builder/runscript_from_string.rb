require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Builder::RunscriptFromString < Operations::Base
    # @return [Builder]
    attr_reader :builder

    # @return [String]
    attr_reader :script

    # @param builder [Builder]
    # @param script [Script]
    # @param name [nil, String]
    # @param client [nil, OsCtldClient]
    def initialize(builder, script, name: nil, client: nil)
      @builder = builder
      @script = script
      @name = name || 'osctl-image-runscript'
      @client = client || OsCtldClient.new
    end

    # @return [Integer] exit status
    def execute
      tmp = Tempfile.new(name, '/tmp')
      File.chmod(0755, tmp.path)
      tmp.write(script)
      tmp.close

      begin
        OsCtldClient.new.runscript(builder.ctid, tmp.path)
      ensure
        tmp.unlink
      end
    end

    protected
    attr_reader :name, :client
  end
end
