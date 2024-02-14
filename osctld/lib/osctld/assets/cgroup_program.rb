require 'osctld/assets/base'

module OsCtld
  class Assets::CgroupProgram < Assets::Base
    register :cgroup_program

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param opts [Hash] options
    # @option opts [String] program_name
    # @option opts [String] attach_type
    # @option opts [String] attach_flags
    # @option opts [Boolean] optional
    def initialize(cgroup_path, opts) # rubocop:disable all
      super
    end

    def exist?
      Dir.exist?(path)
    end

    protected

    def validate(_run)
      unless exist?
        return if opts[:optional]

        add_error('cgroup not found')
        return
      end

      begin
        res = syscmd("bpftool -j cgroup list #{path}")
      rescue SystemCommandFailed => e
        add_error("bpftool failed: #{e.message}")
        return
      end

      begin
        progs = JSON.parse(res.output)
      rescue TypeError, JSON::ParserError => e
        add_error("failed to parse bpftool output: #{e.message}")
        return
      end

      add_error('more than one program attached') if progs.length > 2

      prog = progs.detect { |v| v['name'] == opts[:program_name] }

      if prog.nil?
        add_error("program #{opts[:program_name]} not attached")
        return
      end

      if opts[:attach_type] && prog['attach_type'] != opts[:attach_type]
        add_error("invalid attach_type: expected #{opts[:attach_type]}, got #{prog['attach_type']}")
      end

      return unless opts[:attach_flags] && prog['attach_flags'] != opts[:attach_flags]

      add_error("invalid attach_flags: expected #{opts[:attach_flags]}, got #{prog['attach_flags']}")
    end
  end
end
