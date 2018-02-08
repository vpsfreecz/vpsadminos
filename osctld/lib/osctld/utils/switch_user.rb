require 'json'

module OsCtld
  module Utils::SwitchUser
    def ct_control(ct, cmd, opts = {})
      r, w = IO.pipe

      pid = Process.fork do
        r.close

        SwitchUser.switch_to(
          ct.user.sysusername,
          ct.user.ugid,
          ct.user.homedir,
          ct.cgroup_path
        )
        ret = SwitchUser::ContainerControl.run(cmd, opts, ct.lxc_home)
        w.write(ret.to_json + "\n")

        exit
      end

      w.close

      ret = JSON.parse(r.readline, symbolize_names: true)
      Process.wait(pid)
      ret
    end

    def ct_exec(ct, *args)
      {
        cmd: [
          ::OsCtld.bin('osctld-ct-exec'), ct.user.sysusername, ct.user.ugid.to_s,
          ct.user.homedir, ct.cgroup_path
        ] + args.map(&:to_s),
        env: Hash[ENV.select { |k,_v| k.start_with?('BUNDLE') || k.start_with?('GEM') }]
      }
    end

    # Run a command `cmd` within container `ct`
    def ct_syscmd(ct, cmd, opts = {})
      opts[:valid_rcs] ||= []
      log(:work, ct, cmd)

      in_r, in_w = nil
      out_r, out_w = IO.pipe

      if opts[:stdin].is_a?(String)
        in_r, in_w = IO.pipe
        in_w.write(opts[:stdin])
        in_w.close

      elsif opts[:stdin]
        in_r = opts[:stdin]
      end

      ret = ct_control(ct, :ct_exec, {
        id: ct.id,
        cmd: cmd,
        stdin: in_r,
        stdout: out_w,
        stderr: out_w,
      })

      in_r.close if in_r && opts[:stdin].is_a?(String)
      out_w.close
      out = out_r.read
      out_r.close

      if !ret[:status]
        raise SystemCommandFailed "Command '#{cmd}' within CT #{ct.id} failed"

      elsif ret[:output][:exitstatus] != 0 && \
            opts[:valid_rcs] != :all && \
            !opts[:valid_rcs].include?(ret[:output][:exitstatus])
        raise SystemCommandFailed,
              "Command '#{cmd}' within CT #{ct.id} failed with exit code "+
              "#{ret[:output][:exitstatus]}: #{out}"
      end

      {output: out, exitstatus: ret[:output][:exitstatus]}
    end
  end
end
