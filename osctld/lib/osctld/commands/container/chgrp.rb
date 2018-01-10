module OsCtld
  class Commands::Container::Chgrp < Commands::Base
    handle :ct_chgrp

    include Utils::Log
    include Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      grp = DB::Groups.find(opts[:group], ct.pool)
      return error('group not found') unless grp

      return error("already in group #{grp.name}") if ct.group == grp

      return error('container has to be stopped first') if ct.state != :stopped
      Monitor::Master.demonitor(ct)

      old_grp = ct.group

      grp.inclusively do
        ct.exclusively do
          # Double check state while having exclusive lock
          next error('container has to be stopped first') if ct.state != :stopped

          # Ensure LXC home
          Dir.mkdir(grp.userdir(ct.user), 0751) unless grp.setup_for?(ct.user)

          # Move CT dir
          syscmd("mv #{ct.lxc_dir} #{ct.lxc_dir(group: grp)}")

          # Switch group, regenerate configs
          ct.chgrp(grp)

          # Restart monitor
          Monitor::Master.monitor(ct)

          # Clear old LXC home if possible
          Dir.rmdir(old_grp.userdir(ct.user)) unless old_grp.has_containers?(ct.user)

          ok
        end
      end
    end
  end
end
