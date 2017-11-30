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
    def ct_start(opts)
      # TODO: start using LXC Ruby binding does not work, dunno why
      #lxc_ct(opts[:id]).start
      IO.popen("lxc-start -P #{@lxc_home} -n #{opts[:id]} 2>&1") { |io| io.read }
      ok
    end

    def ct_stop(opts)
      lxc_ct(opts[:id]).stop
      ok
    end

    def ct_restart(opts)
      ct_stop(opts)
      ct_start(opts)
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

    def lxc_ct(id)
      LXC::Container.new(id, @lxc_home)
    end

    def ok(out = nil)
      {status: :ok, output: out}
    end

    def error(msg)
      {status: :error, message: msg}
    end
  end
end
