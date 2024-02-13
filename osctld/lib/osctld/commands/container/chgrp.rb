require 'osctld/commands/logged'
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
      new_group = DB::Groups.find(opts[:group], ct.pool)

      if new_group.nil?
        error!('group not found')
      elsif ct.group == new_group
        error!("already in group #{new_group.name}")
      elsif ct.state != :stopped
        error!('container has to be stopped first')
      end

      old_group = ct.group

      manipulate([ct, new_group, old_group]) do
        # Double check state
        error!('container has to be stopped first') if ct.state != :stopped

        # Check that devices are available in the new group
        unless %w[provide remove].include?(opts[:missing_devices])
          begin
            ct.devices.check_all_available!(group: new_group)
          rescue DeviceNotAvailable, DeviceModeInsufficient => e
            error!(e.message)
          end
        end

        # Stop monitor for old user/group
        Monitor::Master.demonitor(ct)

        progress('Moving LXC configuration')

        # Ensure LXC home
        unless new_group.setup_for?(ct.user)
          dir = new_group.userdir(ct.user)

          FileUtils.mkdir_p(dir, mode: 0o751)
          File.chown(0, ct.user.ugid, dir)
        end

        # Move CT dir
        syscmd("mv #{ct.lxc_dir} #{ct.lxc_dir(group: new_group)}")

        # Switch group, regenerate configs
        progress('Reconfiguring container')
        ct.chgrp(new_group, missing_devices: opts[:missing_devices] || 'check')

        # Restart monitor
        Monitor::Master.monitor(ct)

        # Clear old LXC home if possible
        unless old_group.has_containers?(ct.user)
          progress('Cleaning up original LXC home')
          Dir.rmdir(old_group.userdir(ct.user))
        end

        ok
      end
    end
  end
end
