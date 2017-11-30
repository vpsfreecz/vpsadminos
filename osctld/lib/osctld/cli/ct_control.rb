require 'json'

module OsCtld
  class Cli::CtControl
    def self.run
      opts = JSON.parse($stdin.readline, symbolize_names: true)

      SwitchUser.switch_to(
        opts[:user],
        opts[:sysuser],
        opts[:ugid],
        opts[:homedir]
      )

      #puts `lxc-start -P #{opts[:homedir]}/ct -n myct01`
      #exit

      ret = SwitchUser::ContainerControl.run(
        opts[:cmd].to_sym,
        opts[:opts],
        opts[:lxc_home]
      )
      puts ret.to_json
      exit(ret[:status] == :ok)
    end
  end
end
