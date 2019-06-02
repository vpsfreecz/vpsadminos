require 'libosctl'
require 'osctl/template/operations/base'
require 'securerandom'

module OsCtl::Template
  class Operations::Test::Run < Operations::Base
    Status = Struct.new(:template, :test, :success, :exitstatus, :output) do
      alias_method :success?, :success
      alias_method :ok?, :success
    end

    include OsCtl::Lib::Utils::Log

    # @return [String]
    attr_reader :base_dir

    # @return [Test]
    attr_reader :test

    # @return [Operations::Template::Build]
    attr_reader :build

    # @param base_dir [String]
    # @param build [Operations::Template::Build]
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
              "no template file for '#{build.template}' found in output directory"
      end

      client.set_container_attr(
        ctid,
        'org.vpsadminos.osctl-template:type',
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
        [File.join(base_dir, 'bin/test'), 'template', 'run', test.name, ctid]
      )
      log(:warn, "Test '#{test}' successful")
      Status.new(build.template, test, true, 0, nil)
    rescue OsCtl::Lib::Exceptions::SystemCommandFailed => e
      log(:warn, "Test '#{test}' failed with status #{e.rc}: #{e.output}")
      Status.new(build.template, test, false, e.rc, e.output)
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
