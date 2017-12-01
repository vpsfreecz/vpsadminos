require 'json'

module OsCtld
  module Utils::SwitchUser
    def ct_control(user, cmd, opts = {})
      r, w = IO.pipe

      pid = Process.fork do
        r.close

        SwitchUser.switch_to(user.name, user.username, user.ugid, user.homedir)
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
          ::OsCtld.bin('osctld-user-exec'), user.name, user.username, user.ugid.to_s,
          user.homedir
        ] + args.map(&:to_s),
        env: Hash[ENV.select { |k,_v| k.start_with?('BUNDLE') || k.start_with?('GEM') }]
      }
    end
  end
end
