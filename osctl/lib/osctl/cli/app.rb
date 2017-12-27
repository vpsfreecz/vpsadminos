require 'gli'
require_relative 'container'
require_relative 'group'
require_relative 'net_interface'
require_relative 'user'

module OsCtl::Cli
  class App
    include GLI::App

    def self.run
      cli = new
      cli.setup
      cli.run(ARGV)
    end

    def setup
      program_desc 'Management utility for vpsAdmin OS'
      version OsCtl::VERSION
      subcommand_option_handling :normal
      arguments :strict

      desc 'Manage system users and user namespace configuration'
      command :user do |u|
        u.desc 'List available users'
        u.arg_name '[name...]'
        u.command %i(ls list) do |ls|
          ls.desc 'Filter registered users'
          ls.switch 'registered', negatable: false

          ls.desc 'Filter unregistered users'
          ls.switch 'unregistered', negatable: false

          ls.desc 'Select parameters to output'
          ls.flag %i(o output)

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.action &Command.run(User, :list)
        end

        u.desc "Show user info"
        u.arg_name '<name>'
        u.command %i(show info) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output)

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(User, :show)
        end

        u.desc 'Create a new user with user namespace configuration'
        u.arg_name '<name>'
        u.command %i(new create) do |new|
          new.desc 'User/group ID'
          new.flag :ugid, type: Integer, required: true

          new.desc 'Offset of user/group IDs from zero'
          new.flag :offset, type: Integer, required: true

          new.desc 'Number of user/group IDs available'
          new.flag :size, type: Integer, required: true

          new.action &Command.run(User, :create)
        end

        u.desc 'Delete user'
        u.arg_name '<name>'
        u.command %i(del delete) do |del|
          del.action &Command.run(User, :delete)
        end

        u.desc 'Register users into the system'
        u.arg_name '[name] | all'
        u.command %i(reg register) do |del|
          del.action &Command.run(User, :register)
        end

        u.desc 'Unregister users from the system'
        u.arg_name '[name] | all'
        u.command %i(unreg unregister) do |del|
          del.action &Command.run(User, :unregister)
        end

        u.desc 'Generate /etc/subuid and /etc/subgid'
        u.command :subugids do |sub|
          sub.action &Command.run(User, :subugids)
        end

        u.desc "List user's assets (datasets, files, directories)"
        u.arg_name '<name>'
        u.command :assets do |c|
          c.action &Command.run(User, :assets)
        end

        u.default_command :list
      end

      desc 'Manage groups used for cgroup-based resource limiting'
      command :group do |grp|
        grp.desc 'List available groups'
        grp.arg_name '[name...]'
        grp.command %i(ls list) do |ls|
          ls.desc 'Select parameters to output'
          ls.flag %i(o output)

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.action &Command.run(Group, :list)
        end

        grp.desc 'Create group'
        grp.arg_name '<name>'
        grp.command %i(new create) do |new|
          new.desc 'CGroup path (in all subsystems)'
          new.flag %i(p path), required: true

          new.action &Command.run(Group, :create)
        end

        grp.desc 'Delete group'
        grp.arg_name '<name>'
        grp.command %i(del delete) do |del|
          del.action &Command.run(Group, :delete)
        end

        grp.desc "List group's assets (datasets, files, directories)"
        grp.arg_name '<name>'
        grp.command :assets do |c|
          c.action &Command.run(Group, :assets)
        end

        grp.default_command :list
      end

      desc 'Manage containers'
      command %i(ct vps) do |ct|
        ct.desc 'List containers'
        ct.arg_name '[id...]'
        ct.command %i(ls list) do |ls|
          ls.desc 'Filter by user name, comma separated'
          ls.flag %i(u user)

          ls.desc 'Filter by group name, comma separated'
          ls.flag %i(g group)

          ls.desc 'Filter by distribution, comma separated'
          ls.flag %i(d distribution)

          ls.desc 'Filter by distribution version, comma separated'
          ls.flag %i(v version)

          ls.desc 'Filter by state, comma separated'
          ls.flag %i(s state)

          ls.desc 'Select parameters to output'
          ls.flag %i(o output)

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.action &Command.run(Container, :list)
        end

        ct.desc "Show container's info"
        ct.arg_name '<id>'
        ct.command %i(show info) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output)

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(Container, :show)
        end

        ct.desc 'Create container'
        ct.arg_name '<id>'
        ct.command %i(new create) do |new|
          new.desc 'User name'
          new.flag :user, required: true

          new.desc 'Group name'
          new.flag :group, required: false

          new.desc 'Template file'
          new.flag :template, required: true

          new.action &Command.run(Container, :create)
        end

        ct.desc 'Delete container'
        ct.arg_name '<id>'
        ct.command %i(del delete) do |new|
          new.action &Command.run(Container, :delete)
        end

        ct.desc 'Start container'
        ct.arg_name '<id>'
        ct.command :start do |c|
          c.desc 'Open container console (can be later detached)'
          c.switch %i(F foreground)

          c.action &Command.run(Container, :start)
        end

        ct.desc 'Stop container'
        ct.arg_name '<id>'
        ct.command :stop do |c|
          c.desc 'Open container console (can be later detached)'
          c.switch %i(F foreground)

          c.action &Command.run(Container, :stop)
        end

        ct.desc 'Restart container'
        ct.arg_name '<id>'
        ct.command :restart do |c|
          c.desc 'Open container console (can be later detached)'
          c.switch %i(F foreground)

          c.action &Command.run(Container, :restart)
        end

        ct.desc "Open container's console"
        ct.arg_name '<id>'
        ct.command :console do |c|
          c.desc 'TTY'
          c.flag [:t, :tty], type: Integer, default_value: 0

          c.action &Command.run(Container, :console)
        end

        ct.desc 'Attach the container'
        ct.arg_name '<id>'
        ct.command %i(attach enter) do |c|
          c.action &Command.run(Container, :attach)
        end

        ct.desc 'Execute a command within the container'
        ct.arg_name '<id> <cmd...>'
        ct.command %i(exec) do |c|
          c.action &Command.run(Container, :exec)
        end

        ct.desc "Get container's user's shell"
        ct.arg_name '<id>'
        ct.command :su do |su|
          su.action &Command.run(Container, :su)
        end

        ct.desc 'Configure container'
        ct.arg_name '<id>'
        ct.command :set do |set|
          set.action &Command.run(Container, :set)
        end

        ct.desc "Go to container's rootfs directory"
        ct.arg_name '<id>'
        ct.command :cd do |c|
          c.desc "Go to /proc/<init_pid>/root"
          c.switch %i(r runtime), negatable: false

          c.desc "Go to LXC config directory"
          c.switch %i(l lxc), negatable: false

          c.action &Command.run(Container, :cd)
        end

        ct.desc 'List container assets (datasets, files, directories)'
        ct.arg_name '<id>'
        ct.command :assets do |c|
          c.action &Command.run(Container, :assets)
        end

        ct.desc "Manage container's network interfaces"
        ct.command %i(netif net) do |net|
          net.desc "List network interfaces"
          net.arg_name '<id>'
          net.command %i(ls list) do |c|
            c.desc 'Filter by interface type'
            c.flag %i(t type)

            c.desc 'Filter by linked bridge'
            c.flag %i(l link)

            c.desc 'Select parameters to output'
            c.flag %i(o output)

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(NetInterface, :list)
          end

          net.desc "Create a new network interface"
          net.command %i(new create) do |create|
            create.desc 'Create a new bridged veth interface'
            create.arg_name '<id> <name>'
            create.command :bridge do |c|
              c.desc 'What bridge should the interface be linked with'
              c.flag :link, required: true

              c.action &Command.run(NetInterface, :create_bridge)
            end

            create.desc 'Create a new routed veth interface'
            create.arg_name '<id> <name>'
            create.command :routed do |c|
              c.desc 'Route via network'
              c.flag :via, multiple: true, required: true

              c.action &Command.run(NetInterface, :create_routed)
            end
          end

          net.desc "Remove network interface"
          net.arg_name '<id> <name>'
          net.command %i(del delete) do |c|
            c.action &Command.run(NetInterface, :delete)
          end

          net.desc "Manage IP addresses"
          net.command :ip do |ip|
            ip.desc 'List IP addresses'
            ip.arg_name '<id>'
            ip.command %i(ls list) do |c|
              c.action &Command.run(NetInterface, :ip_list)
            end

            ip.desc 'Add IP address'
            ip.arg_name '<id> <name> <addr>'
            ip.command :add do |c|
              c.action &Command.run(NetInterface, :ip_add)
            end

            ip.desc 'Remove IP address'
            ip.arg_name '<id> <name> <addr>'
            ip.command :del do |c|
              c.action &Command.run(NetInterface, :ip_del)
            end

            ip.default_command :list
          end

          net.default_command :list
        end

        ct.default_command :list
      end

      on_error do |exception|
        raise exception
      end
    end
  end
end
