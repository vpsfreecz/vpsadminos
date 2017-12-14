require 'gli'
require_relative 'container'
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

        u.desc 'Get user shell'
        u.arg_name '<name>'
        u.command :su do |su|
          su.action &Command.run(User, :su)
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

        u.default_command :list
      end

      desc 'Manage containers'
      command %i(ct vps) do |ct|
        ct.desc 'List containers'
        ct.arg_name '[id...]'
        ct.command %i(ls list) do |ls|
          ls.desc 'Filter by user name, comma separated'
          ls.flag %i(u user)

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

          new.desc 'Template file'
          new.flag :template, required: true

          new.desc 'Route via network (set one network for IPv4, another for IPv6)'
          new.flag 'route-via', multiple: true

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
          c.action &Command.run(Container, :start)
        end

        ct.desc 'Stop container'
        ct.arg_name '<id>'
        ct.command :stop do |c|
          c.action &Command.run(Container, :stop)
        end

        ct.desc 'Restart container'
        ct.arg_name '<id>'
        ct.command :restart do |c|
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
          set.desc 'Route via network (set one network for IPv4, another for IPv6)'
          set.flag 'route-via', multiple: true

          set.action &Command.run(Container, :set)
        end

        ct.desc "Manage container's IP addresses"
        ct.command :ip do |ip|
          ip.desc 'List IP addresses'
          ip.arg_name '<id>'
          ip.command %i(ls list) do |c|
            c.action &Command.run(Container, :ip_list)
          end

          ip.desc 'Show container routing subnets'
          ip.arg_name '<id>'
          ip.command 'route-via' do |c|
            c.action &Command.run(Container, :ip_route_via)
          end

          ip.desc 'Add IP address'
          ip.arg_name '<id> <addr>'
          ip.command :add do |c|
            c.action &Command.run(Container, :ip_add)
          end

          ip.desc 'Remove IP address'
          ip.arg_name '<id> <addr>'
          ip.command :del do |c|
            c.action &Command.run(Container, :ip_del)
          end

          ip.default_command :list
        end

        ct.default_command :list
      end

      on_error do |exception|
        raise exception
      end
    end
  end
end
