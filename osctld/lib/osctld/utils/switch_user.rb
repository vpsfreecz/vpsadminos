require 'json'

module OsCtld
  module Utils::SwitchUser
    def ct_control(user, cmd, opts = {})
      r, w = IO.pipe

      pid = Process.fork do
        r.close

        SwitchUser.switch_to(user.name, user.sysusername, user.ugid, user.homedir)
        ret = SwitchUser::ContainerControl.run(cmd, opts, user.lxc_home)
        w.write(ret.to_json + "\n")

        exit
      end

      w.close

      ret = JSON.parse(r.readline, symbolize_names: true)
      Process.wait(pid)
      ret
    end

    def user_exec(user, *args)
      {
        cmd: [
          ::OsCtld.bin('osctld-user-exec'), user.name, user.sysusername, user.ugid.to_s,
          user.homedir
        ] + args.map(&:to_s),
        env: Hash[ENV.select { |k,_v| k.start_with?('BUNDLE') || k.start_with?('GEM') }]
      }
    end

    # Run a command `cmd` within container `ct`
    def ct_syscmd(ct, cmd, opts = {})
      opts[:valid_rcs] ||= []
      log(:work, "CT #{ct.id}", cmd)

      r, w = IO.pipe

      ret = ct_control(ct.user, :ct_exec, {
        id: ct.id,
        cmd: cmd,
        stdin: nil,
        stdout: w,
        stderr: w,
      })

      w.close
      out = r.read

      if !ret[:status]
        fail "Command '#{cmd}' within CT #{ct.id} failed"

      elsif ret[:output][:exitstatus] != 0 && \
            !opts[:valid_rcs].include?(ret[:output][:exitstatus])
        fail "Command '#{cmd}' within CT #{ct.id} failed with exit code "+
             "#{ret[:output][:exitstatus]}: #{out}"
      end

      {output: out, exitstatus: ret[:exitstatus]}
    end
  end
end
