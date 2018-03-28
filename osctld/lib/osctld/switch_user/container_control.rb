require 'lxc'

module OsCtld
  class SwitchUser::ContainerControl
    def self.run(cmd, opts, lxc_home)
      ur = new(lxc_home)
      ur.execute(cmd, opts)
    end

    def initialize(lxc_home)
      @lxc_home = lxc_home
    end

    def execute(cmd, opts)
      method(cmd).call(opts)
    end

    protected
    # Attempt a clean shutdown, fallback to kill
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [Integer] :timeout how long to wait for clean shutdown
    def ct_stop(opts)
      ct = lxc_ct(opts[:id])

      if ct_shutdown(opts, ct)[:status]
        ok

      else
        ct_kill(opts, ct)
      end
    end

    # Kill container immediately
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @param ct [SwitchUser::ContainerControl, nil]
    def ct_kill(opts, ct = nil)
      ct ||= lxc_ct(opts[:id])
      ct.stop
      ok

    rescue LXC::Error
      error('unable to kill container')
    end

    # Shutdown container cleanly or fail
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [Integer] :timeout how long to wait for clean shutdown
    # @param ct [SwitchUser::ContainerControl, nil]
    def ct_shutdown(opts, ct = nil)
      ct ||= lxc_ct(opts[:id])
      ct.shutdown(opts[:timeout])
      ok

    rescue LXC::Error
      error('unable to shutdown container')
    end

    # Request container reboot
    # @param opts [Hash]
    # @option opts [String] :id container id
    def ct_reboot(opts)
      ct = lxc_ct(opts[:id])
      ct.reboot
    end

    def ct_status(opts)
      ret = {}

      opts[:ids].each do |id|
        ct = lxc_ct(id)

        ret[id] = {
          state: ct.state,
          init_pid: ct.init_pid,
        }
      end

      ok(ret)
    end

    def ct_exec(opts)
      pid = lxc_ct(opts[:id]).attach(
        stdin: opts[:stdin],
        stdout: opts[:stdout],
        stderr: opts[:stderr]
      ) do
        ENV.delete_if { |k, _| k != 'TERM' }
        ENV['PATH'] = %w(/bin /usr/bin /sbin /usr/sbin /run/current-system/sw/bin).join(':')

        LXC.run_command(opts[:cmd])
      end

      _, status = Process.wait2(pid)
      ok(exitstatus: status.exitstatus)
    end

    def veth_name(opts)
      ct = lxc_ct(opts[:id])
      ok(ct.running_config_item("lxc.net.#{opts[:index]}.veth.pair"))
    end

    def lxc_ct(id)
      LXC::Container.new(id, @lxc_home)
    end

    def ok(out = nil)
      {status: true, output: out}
    end

    def error(msg)
      {status: false, message: msg}
    end
  end
end
