require 'libosctl'
require 'tempfile'
require 'vpsadminos-converter/vz6/migrator'

module VpsAdminOS::Converter
  class Vz6::Migrator::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Send

    attr_reader :state

    def initialize(state)
      @state = state
    end

    %i(vz_ct target_ct opts can_proceed?).each do |v|
      define_method(v) { |*args| state.send(v, *args) }
    end

    def stage
      f = Tempfile.open("ct-#{target_ct.id}-skel")
      export_skel(target_ct, f)
      f.seek(0)

      opts[:port] ||= 22

      ssh = send_ssh_cmd(
        nil,
        opts,
        ['receive', 'skel']
      )

      IO.popen("exec #{ssh.join(' ')}", 'r+') do |io|
        io.write(f.readpartial(16*1024)) until f.eof?
      end

      f.close
      f.unlink

      fail 'stage failed' if $?.exitstatus != 0

      state.save
    end

    def sync
      raise NotImplementedError
    end

    def transfer
      raise NotImplementedError
    end

    def cleanup(cmd_opts)
      raise NotImplementedError
    end

    def cancel(cmd_opts)
      raise NotImplementedError
    end

    protected
    attr_accessor :progress_handler

    def export_skel(ct, io)
      exporter = Exporter::Base.new(ct, io)
      exporter.dump_metadata('skel')
      exporter.dump_configs
      exporter.close
    end

    def transfer_container(start)
      progress(:step, 'Starting on the target node')
      ret = system(
        *send_ssh_cmd(
          nil,
          opts,
          ['receive', 'transfer', target_ct.id] + (start ? ['start'] : [])
        )
      )

      fail 'transfer failed' if ret.nil? || $?.exitstatus != 0

      state.set_step(:transfer)
      state.save
    end

    def cancel_remote(nofail)
      ret = system(
        *send_ssh_cmd(
          nil,
          opts,
          ['receive', 'cancel', target_ct.id]
        )
      )

      if ret.nil? || $?.exitstatus != 0 && !nofail
        fail 'cancel failed'
      end
    end

    def progress(type, value)
      return unless progress_handler
      progress_handler.call(type, value)
    end
  end
end
