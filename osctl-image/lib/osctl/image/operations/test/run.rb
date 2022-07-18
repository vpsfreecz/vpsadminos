require 'libosctl'
require 'osctl/image/operations/base'
require 'securerandom'

module OsCtl::Image
  class Operations::Test::Run < Operations::Base
    Status = Struct.new(:image, :test, :success, :exitstatus, :output) do
      alias_method :success?, :success
      alias_method :ok?, :success
    end

    include OsCtl::Lib::Utils::Log

    # @return [String]
    attr_reader :base_dir

    # @return [Test]
    attr_reader :test

    # @return [Operations::Image::Build]
    attr_reader :build

    # @param base_dir [String]
    # @param build [Operations::Image::Build]
    # @param test [Test]
    # @param opts [Hash]
    # @option opts [Boolean] :keep_failed
    # @option opts [IpAllocator] :ip_allocator
    def initialize(base_dir, build, test, opts = {})
      @base_dir = base_dir
      @build = build
      @test = test
      @client = OsCtldClient.new
      @keep_failed = opts.has_key?(:keep_failed) ? opts[:keep_failed] : false
      @ip_allocator = opts[:ip_allocator]
    end

    # @return [Status]
    def execute
      @ctid = gen_ctid

      if File.exist?(build.output_stream)
        create_container(build.output_stream)
      elsif File.exist?(build.output_tar)
        create_container(build.output_tar)
      else
        raise OperationError,
              "no image file for '#{build.image}' found in output directory"
      end

      client.set_container_attr(
        ctid,
        'org.vpsadminos.osctl-image:type',
        'test'
      )

      run_test
    end

    protected
    attr_reader :client, :ctid, :keep_failed, :ip_allocator, :status

    def create_container(file)
      client.create_container_from_file(ctid, file)
      sleep(3) # FIXME: wait for osctld...
      log(:info, "Created container '#{ctid}' for test '#{test}'")
      client.unset_container_start_menu(ctid)
    end

    def run_test
      ip = ip_allocator.get

      Operations::Nix::RunInShell.run(
        File.join(base_dir, 'shell-test.nix'),
        [
          File.join(base_dir, 'bin/test'), 'image', 'run',
          build.image.name, test.name, ctid,
        ],
        {env: ENV.to_h.update({'OSCTL_IMAGE_TEST_IPV4_ADDRESS' => ip.to_s})}
      )
      log(:warn, "Test '#{test}' successful")
      @status = Status.new(build.image, test, true, 0, nil)
    rescue OsCtl::Lib::Exceptions::SystemCommandFailed => e
      log(:warn, "Test '#{test}' failed with status #{e.rc}: #{e.output}")
      @status = Status.new(build.image, test, false, e.rc, e.output)
    ensure
      ip_allocator.put(ip)
      cleanup(ctid)
    end

    def cleanup(ctid)
      if status.success? || !keep_failed
        log(:info, "Cleaning up assets of test '#{test}'")
        client.delete_container(ctid)
      else
        log(:info, "Preserving container '#{ctid}' of failed test '#{test}'")
      end
    end

    def gen_ctid
      "test-#{SecureRandom.hex(4)}"
    end
  end
end
