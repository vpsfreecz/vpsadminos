require 'libosctl'
require 'osctld/net_config'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtNetnsSetup < UserControl::Commands::Base
    handle :ct_netns_setup

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      init_pid = opts[:init_pid].to_i
      return error('invalid init pid') if init_pid <= 0

      setup_netns(init_pid, opts[:net_config])
    end

    protected

    def setup_netns(init_pid, net_config)
      r, w = IO.pipe

      pid = Process.fork do
        r.close
        msg = nil
        status = 0

        begin
          sys = OsCtl::Lib::Sys.new
          sys.setns_path(
            File.join('/proc', init_pid.to_s, 'ns/net'),
            OsCtl::Lib::Sys::CLONE_NEWNET
          )
          NetConfig.import(net_config).setup
        rescue StandardError => e
          msg = "#{e.class}: #{e.message}"
          status = 1
        ensure
          w.write(msg) if msg
          w.close
        end

        exit!(status)
      end

      w.close
      msg = r.read
      r.close

      _, status = Process.wait2(pid)
      return ok if status.success?

      error(msg.empty? ? "network setup exited with status #{status.exitstatus}" : msg)
    end
  end
end
