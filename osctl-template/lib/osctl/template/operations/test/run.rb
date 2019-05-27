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
    include OsCtl::Lib::Utils::System

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
        use_stream
      elsif File.exist?(build.output_tar)
        use_archive
      else
        fail "no template file for '#{build.template}' found in output directory"
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

    def use_archive
      client.create_container_from_archive(ctid, build.output_tar)
      sleep(3) # FIXME: wait for osctld...
    end

    def use_stream
      client.create_container_from_stream(ctid, build.output_stream)
      sleep(3) # FIXME: wait for osctld...
    end

    def run_test
      syscmd("#{base_dir}/bin/test template run #{test} #{ctid}")
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
