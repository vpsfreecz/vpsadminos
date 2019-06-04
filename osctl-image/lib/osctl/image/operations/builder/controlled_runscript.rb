require 'libosctl'
require 'osctl/image/operations/base'
require 'securerandom'

module OsCtl::Image
  class Operations::Builder::ControlledRunscript < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [Builder]
    attr_reader :builder

    # @return [String]
    attr_reader :file

    # @return [String]
    attr_reader :script

    # @param builder [Builder]
    # @param file [String] script to execute
    # @param script [String] shell commands to execute
    # @param id [nil, String] optional run identifier
    # @param name [nil, String]
    # @param client [nil, OsCtldClient]
    def initialize(builder, file: nil, script: nil, id: nil, name: nil, client: nil)
      if (file && script ) || (!file && !script)
        raise ArgumentError, 'provide file or script'
      end

      @builder = builder
      @file = file
      @script = script
      @id = id
      @name = name || '.osctl-image-runscript'
      @client = client || OsCtldClient.new
    end

    # @return [Integer] exit status
    def execute
      fh, path = create_file


      if file
        File.open(file, 'r') { |f| IO.copy_stream(f, fh) }
      elsif script
        fh.write(script)
      else
        fail 'programming error'
      end

      fh.close

      begin
        Operations::Builder::ControlledExec.run(builder, [path], id: id, client: client)
      ensure
        unlink(fh.path)
      end
    end

    protected
    attr_reader :id, :name, :client

    # @return [File, String] file, path relative from builder's rootfs
    def create_file
      host_path = nil
      builder_path = nil

      5.times do
        builder_path = File.join('/', "#{name}#{SecureRandom.hex(5)}")
        host_path = File.join(builder.attrs[:rootfs], builder_path)

        if File.exist?(host_path)
          host_path = nil
        else
          break
        end
      end

      if host_path.nil?
        fail 'unable to create temporary file'
      end

      fh = File.open(host_path, 'w')
      File.chmod(0755, host_path)
      [fh, builder_path]
    end

    def unlink(path)
      File.unlink(path)
    rescue Errno::ENOENT
    end
  end
end
