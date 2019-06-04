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
    def initialize(base_dir, build, test)
      @base_dir = base_dir
      @build = build
      @test = test
      @client = OsCtldClient.new
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
    attr_reader :client, :ctid

    def create_container(file)
      client.create_container_from_file(ctid, file)
      sleep(3) # FIXME: wait for osctld...
    end

    def run_test
      Operations::Nix::RunInShell.run(
        File.join(base_dir, 'shell-test.nix'),
        [File.join(base_dir, 'bin/test'), 'image', 'run', test.name, ctid]
      )
      log(:warn, "Test '#{test}' successful")
      Status.new(build.image, test, true, 0, nil)
    rescue OsCtl::Lib::Exceptions::SystemCommandFailed => e
      log(:warn, "Test '#{test}' failed with status #{e.rc}: #{e.output}")
      Status.new(build.image, test, false, e.rc, e.output)
    ensure
      cleanup(ctid)
    end

    def cleanup(ctid)
      client.delete_container(ctid)
      client.delete_user(ctid)
    end

    def gen_ctid
      "test-#{SecureRandom.hex(4)}"
    end
  end
end
