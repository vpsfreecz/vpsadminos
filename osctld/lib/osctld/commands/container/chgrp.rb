require 'fileutils'

module OsCtld
  class Commands::Container::Chgrp < Commands::Logged
    handle :ct_chgrp

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      grp = DB::Groups.find(opts[:group], ct.pool)
      return error('group not found') unless grp

      return error("already in group #{grp.name}") if ct.group == grp
      return error('container has to be stopped first') if ct.state != :stopped

      old_grp = ct.group

      grp.inclusively do
        ct.exclusively do
          # Double check state while having exclusive lock
          next error('container has to be stopped first') if ct.state != :stopped

          # Check that devices are available in the new group
          unless %w(provide remove).include?(opts[:missing_devices])
            begin
              ct.devices.check_all_available!(grp)

            rescue DeviceNotAvailable, DeviceModeInsufficient => e
              error!(e.message)
            end
          end

          # Stop monitor for old user/group
          Monitor::Master.demonitor(ct)

          progress('Moving LXC configuration')

          # Ensure LXC home
          unless grp.setup_for?(ct.user)
            dir = grp.userdir(ct.user)

            FileUtils.mkdir_p(dir, mode: 0751)
            File.chown(0, ct.user.ugid, dir)
          end

          # Move CT dir
          syscmd("mv #{ct.lxc_dir} #{ct.lxc_dir(group: grp)}")

          # Switch group, regenerate configs
          progress('Reconfiguring container')
          ct.chgrp(grp, missing_devices: opts[:missing_devices] || 'check')

          # Restart monitor
          Monitor::Master.monitor(ct)

          # Clear old LXC home if possible
          unless old_grp.has_containers?(ct.user)
            progress('Cleaning up original LXC home')
            Dir.rmdir(old_grp.userdir(ct.user))
          end

          ok
        end
      end
    end
  end
end
