require 'libosctl'
require 'osctl/template/operations/base'
require 'securerandom'

module OsCtl::Template
  class Operations::Template::Instantiate < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :base_dir

    # @return [Template]
    attr_reader :template

    # @param base_dir [String]
    # @param template [Template]
    # @param opts [Hash]
    # @option opts [String] :build_dataset
    # @option opts [String] :output_dir
    # @option opts [String] :vendor
    # @option opts [Boolean] :rebuild
    # @option opts [String] :ctid
    def initialize(base_dir, template, opts)
      @base_dir = base_dir
      @template = template
      @opts = opts
      @client = OsCtldClient.new
      @ctid = opts[:ctid] || gen_ctid
      @reinstall = opts[:ctid] ? true : false
    end

    # @return [String] ctid
    def execute
      build = Operations::Template::Build.new(base_dir, template, opts)
      build.execute if opts[:rebuild]

      if (!File.exist?(build.output_stream) && !File.exist?(build.output_tar)) \
         || opts[:rebuild]
        build.execute
      end

      instantiate(build)
      ctid
    end

    protected
    attr_reader :opts, :client, :reinstall, :ctid

    def instantiate(build)
      if File.exist?(build.output_stream)
        use_stream(build)
      elsif File.exist?(build.output_tar)
        use_archive(build)
      else
        fail "no template file for '#{build.template}' found in output directory"
      end
    end

    def use_archive(build)
      if reinstall
        client.stop_container(ctid)
        client.reinstall_container_from_archive(
          ctid,
          build.output_tar,
          remove_snapshots: true,
        )
      else
        client.create_container_from_archive(ctid, build.output_tar)
        sleep(3) # FIXME: wait for osctld...
        client.set_container_attr(
          ctid,
          'org.vpsadminos.osctl-template:type',
          'instance'
        )
      end
    end

    def use_stream(build)
      if reinstall
        client.stop_container(ctid)
        client.reinstall_container_from_stream(
          ctid,
          build.output_stream,
          remove_snapshots: true,
        )
      else
        client.create_container_from_stream(ctid, build.output_stream)
        sleep(3) # FIXME: wait for osctld...
        client.set_container_attr(
          ctid,
          'org.vpsadminos.osctl-template:type',
          'instance'
        )
      end
    end

    def gen_ctid
      "instance-#{SecureRandom.hex(4)}"
    end
  end
end
