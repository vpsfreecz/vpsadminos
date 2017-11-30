require 'json'

module OsCtld
  module Utils::SwitchUser
    def ct_control(user, cmd, opts = {})
      ret = syscmd(::OsCtld::bin('osctld-user-ctcontrol'), input: {
        user: user.name,
        ugid: user.ugid,
        sysuser: user.username,
        homedir: user.homedir,
        lxc_home: user.lxc_home,
        cmd: cmd,
        opts: opts,
      }.to_json + "\n", valid_rcs: [1])

      JSON.parse(ret[:output], symbolize_names: true)
    end

    def user_exec(user, *args)
      [::OsCtld.bin('osctld-user-exec'), user.name, user.username, user.ugid.to_s,
       user.homedir] + args.map(&:to_s)
    end
  end
end
