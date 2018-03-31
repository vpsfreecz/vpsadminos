require 'gli'
require 'thread'
require_relative 'cgroup_params'
require_relative 'devices'
require_relative 'assets'
require_relative 'container'
require_relative 'event'
require_relative 'group'
require_relative 'history'
require_relative 'migrate'
require_relative 'migration'
require_relative 'net_interface'
require_relative 'pid_finder'
require_relative 'pool'
require_relative 'repository'
require_relative 'self'
require_relative 'top'
require_relative 'tree'
require_relative 'user'

module OsCtl::Cli
  class App
    include GLI::App

    def self.run
      cli = new
      cli.setup
      exit(cli.run(ARGV))
    end

    def setup
      Thread.abort_on_exception = true

      program_desc 'Management utility for vpsAdmin OS'
      version OsCtl::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict

      desc 'Show precise values'
      switch %i(p parsable), negatable: false

      desc 'Format output in JSON'
      switch %i(j json), negatable: false

      desc 'Toggle colorized output'
      switch :color, default_value: true

      desc 'Pool name'
      flag :pool

      desc 'Surpress output'
      switch %i(q quiet), negatable: false

      desc 'Manage data pools'
      command :pool do |p|
        p.desc 'List imported pools'
        p.command %i(ls list) do |ls|
          ls.desc 'Select parameters to output'
          ls.flag %i(o output)

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.action &Command.run(Pool, :list)
        end

        p.desc 'Import pool(s)'
        p.arg_name '[name]'
        p.command :import do |c|
          c.desc 'Import all installed pools'
          c.switch %i(a all), negatable: false

          c.desc 'Start containers that are configured to be started automatically'
          c.switch %i(s autostart), default_value: true

          c.action &Command.run(Pool, :import)
        end

        p.desc 'Export imported pool'
        p.arg_name '<name>'
        p.command :export do |c|
          c.desc 'Export the pool even if there are containers running'
          c.switch %i(f force)

          c.desc 'Stop all containers from the exported pool'
          c.switch %i(s stop-containers), default_value: true

          c.desc 'Unregister system users that come from the exported pool'
          c.switch %i(u unregister-users), default_value: true

          c.action &Command.run(Pool, :export)
        end

        p.desc 'Install a new pool'
        p.arg_name '<name>'
        p.command :install do |c|
          c.desc 'Place osctld datasets into a subdataset'
          c.flag :dataset

          c.action &Command.run(Pool, :install)
        end

        p.desc 'Uninstall pool'
        p.arg_name '<name>'
        p.command :uninstall do |c|
          c.action &Command.run(Pool, :uninstall)
        end

        p.desc "List pool's assets (datasets, files, directories)"
        p.arg_name '<name>'
        assets(p, Pool)

        p.desc 'Check and trigger container auto-starting'
        p.command :autostart do |as|
          as.desc 'Check auto-start queue'
          as.arg_name '<name>'
          as.command :queue do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output)

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Pool, :autostart_queue)
          end

          as.desc 'Start containers that have auto-start enabled'
          as.arg_name '<name>'
          as.command :trigger do |c|
            c.action &Command.run(Pool, :autostart_trigger)
          end

          as.desc 'Cancel start of containers left in the queue'
          as.arg_name '<name>'
          as.command :cancel do |c|
            c.action &Command.run(Pool, :autostart_cancel)
          end
        end
      end

      desc 'Manage system users and user namespace configuration'
      command :user do |u|
        u.desc 'List available users'
        u.arg_name '[name...]'
        u.command %i(ls list) do |ls|
          ls.desc 'Filter by pool, comma separated'
          ls.flag :pool

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
          new.desc 'Pool name'
          new.flag :pool

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
        u.command %i(reg register) do |c|
          c.action &Command.run(User, :register)
        end

        u.desc 'Unregister users from the system'
        u.arg_name '[name] | all'
        u.command %i(unreg unregister) do |c|
          c.action &Command.run(User, :unregister)
        end

        u.desc 'Generate /etc/subuid and /etc/subgid'
        u.command :subugids do |sub|
          sub.action &Command.run(User, :subugids)
        end

        u.desc "List user's assets (datasets, files, directories)"
        u.arg_name '<name>'
        assets(u, User)
      end

      desc 'Manage groups used for cgroup-based resource limiting'
      command :group do |grp|
        grp.desc 'List available groups'
        grp.arg_name '[name...]'
        grp.command %i(ls list) do |ls|
          ls.desc 'Filter by pool, comma separated'
          ls.flag :pool

          ls.desc 'Select parameters to output'
          ls.flag %i(o output)

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.action &Command.run(Group, :list)
        end

        grp.desc 'Print group tree'
        grp.arg_name '<pool>'
        grp.command :tree do |c|
          c.action &Command.run(Group, :tree)
        end

        grp.desc 'Show group info'
        grp.arg_name '<name>'
        grp.command %i(show find) do |c|
          c.action &Command.run(Group, :show)
        end

        grp.desc 'Create group'
        grp.arg_name '<name>'
        grp.command %i(new create) do |new|
          new.desc 'Pool name'
          new.flag :pool

          new.desc 'Create missing parent groups'
          new.switch %i(p parents)

          new.desc 'Set CGroup parameter'
          new.flag %i(cgparam), multiple: true

          new.action &Command.run(Group, :create)
        end

        grp.desc 'Delete group'
        grp.arg_name '<name>'
        grp.command %i(del delete) do |del|
          del.action &Command.run(Group, :delete)
        end

        grp.desc "List group's assets (datasets, files, directories)"
        grp.arg_name '<name>'
        assets(grp, Group)

        cg_params(grp, Group)
        devices(grp, Group)
      end

      desc 'Manage containers'
      command %i(ct vps) do |ct|
        ct.desc 'List containers'
        ct.arg_name '[id...]'
        ct.command %i(ls list) do |ls|
          ls.desc 'Filter by pool, comma separated'
          ls.flag :pool

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

        ct.desc 'Print tree of containers and groups'
        ct.arg_name '<pool>'
        ct.command :tree do |c|
          c.action &Command.run(Container, :tree)
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
          new.desc 'Pool name'
          new.flag :pool

          new.desc 'User name'
          new.flag :user, required: true

          new.desc 'Group name'
          new.flag :group, required: false

          new.desc 'Template from a repository'
          new.flag :template

          new.desc 'Template in a tar archive'
          new.flag 'from-archive'

          new.desc 'Template in a ZFS stream'
          new.flag 'from-stream'

          new.desc 'Use a custom dataset for the rootfs'
          new.flag :dataset

          new.desc 'Do not extract any template (use together with --dataset)'
          new.switch 'no-template', negatable: false

          new.desc 'Distribution name in lower case'
          new.flag :distribution

          new.desc 'Distribution version'
          new.flag :version

          new.desc 'Architecture'
          new.flag :arch

          new.desc 'Vendor (used only when downloading the template)'
          new.flag :vendor

          new.desc 'Variant (used only when downloading the template)'
          new.flag :variant

          new.desc 'Repository'
          new.flag :repository

          new.action &Command.run(Container, :create)
        end

        ct.desc 'Delete container'
        ct.arg_name '<id>'
        ct.command %i(del delete) do |c|
          c.action &Command.run(Container, :delete)
        end

        ct.desc 'Reinstall container'
        ct.arg_name '<id>'
        ct.command :reinstall do |c|
          c.desc 'Template from a repository'
          c.flag :template

          c.desc 'Template in a tar archive'
          c.flag 'from-archive'

          c.desc 'Template in a ZFS stream'
          c.flag 'from-stream'

          c.desc 'Distribution name in lower case'
          c.flag :distribution

          c.desc 'Distribution version'
          c.flag :version

          c.desc 'Architecture'
          c.flag :arch

          c.desc 'Vendor (used only when downloading the template)'
          c.flag :vendor

          c.desc 'Variant (used only when downloading the template)'
          c.flag :variant

          c.desc 'Repository'
          c.flag :repository

          c.desc 'Remove snapshots of the root dataset'
          c.switch %i(r remove-snapshots)

          c.action &Command.run(Container, :reinstall)
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

          c.desc 'How many seconds to wait before killing the container'
          c.flag %i(t timeout), type: Integer, default_value: 60

          c.desc 'Do not request a clean shutdown, kill the container'
          c.switch %i(k kill), negatable: false

          c.desc 'Do not kill the container if clean shutdown fails'
          c.switch 'dont-kill', negatable: false

          c.action &Command.run(Container, :stop)
        end

        ct.desc 'Restart container'
        ct.arg_name '<id>'
        ct.command :restart do |c|
          c.desc 'Open container console (can be later detached)'
          c.switch %i(F foreground)

          c.desc 'Request reboot by signaling the init process'
          c.switch %i(r reboot)

          c.desc 'How many seconds to wait before killing the container'
          c.flag %i(t timeout), type: Integer, default_value: 60

          c.desc 'Do not request a clean shutdown, kill the container'
          c.switch %i(k kill), negatable: false

          c.desc 'Do not kill the container if clean shutdown fails'
          c.switch 'dont-kill', negatable: false

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
          c.desc 'Run shell as configured in the container'
          c.switch %i(u user-shell), negatable: false

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
        ct.command :set do |set|
          set.desc 'Start the container when its pool is imported'
          set.arg_name '<id>'
          set.command :autostart do |c|
            c.desc 'Start priority (0 is the highest priority)'
            c.flag %i(p priority), type: Integer, default_value: 10

            c.desc 'How long to wait before starting another container, in seconds'
            c.flag %i(d delay), type: Integer, default_value: 5

            c.action &Command.run(Container, :set_autostart)
          end

          set.desc 'Set hostname'
          set.arg_name '<id> <hostname>'
          set.command :hostname do |c|
            c.action &Command.run(Container, :set_hostname)
          end

          set.desc 'Set DNS resolver'
          set.arg_name '<id> <address...>'
          set.command :'dns-resolver' do |c|
            c.action &Command.run(Container, :set_dns_resolver)
          end

          set.desc 'Allow/disallow container nesting'
          set.arg_name '<id> enabled|disabled'
          set.command :nesting do |c|
            c.action &Command.run(Container, :set_nesting)
          end

          set.desc 'Change distribution and version info'
          set.arg_name '<id> <distribution> <version>'
          set.command :distribution do |c|
            c.action &Command.run(Container, :set_distribution)
          end
        end

        ct.desc 'Clear configuration options'
        ct.command :unset do |unset|
          unset.desc 'Disable automatic container starting'
          unset.arg_name '<id>'
          unset.command :autostart do |c|
            c.action &Command.run(Container, :unset_autostart)
          end

          unset.desc 'Disable hostname management'
          unset.arg_name '<id>'
          unset.command :hostname do |c|
            c.action &Command.run(Container, :unset_hostname)
          end

          unset.desc 'Disable DNS resolver management'
          unset.arg_name '<id>'
          unset.command :'dns-resolver' do |c|
            c.action &Command.run(Container, :unset_dns_resolver)
          end
        end

        ct.desc 'Move the container to another user namespace'
        ct.arg_name '<id> <user>'
        ct.command :chown do |c|
          c.action &Command.run(Container, :chown)
        end

        ct.desc 'Move the container to another group'
        ct.arg_name '<id> <group>'
        ct.command :chgrp do |c|
          c.desc 'Provide or remove missing devices'
          c.flag 'missing-devices', must_match: %w(provide remove check)

          c.action &Command.run(Container, :chgrp)
        end

        ct.desc 'Set password for a user within the container'
        ct.arg_name '<id> <user> [password]'
        ct.command :passwd do |c|
          c.action &Command.run(Container, :passwd)
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

        ct.desc 'Export the container configs and data into a tar archive'
        ct.arg_name '<id> <file>'
        ct.command :export do |c|
          c.desc 'Stop the container during the export'
          c.switch :consistent, default_value: true

          c.desc 'Compression'
          c.flag %i(c compression), must_match: %w(auto off gzip),
                 default_value: 'auto'

          c.action &Command.run(Container, :export)
        end

        ct.desc 'Import container from tar archive'
        ct.arg_name '<file>'
        ct.command :import do |c|
          c.desc 'Import as container id'
          c.flag 'as-id'

          c.desc 'Import as an existing user'
          c.flag 'as-user'

          c.desc 'Import into an existing group'
          c.flag 'as-group'

          c.desc 'Use a custom dataset for the rootfs'
          c.flag :dataset

          c.desc 'Provide or remove missing devices'
          c.flag 'missing-devices', must_match: %w(provide remove check)

          c.action &Command.run(Container, :import)
        end

        ct.desc 'Migrate container to another node'
        ct.command :migrate do |m|
          m.desc 'Step 1., copy configs to target node'
          m.arg_name '<id> <dst>'
          m.command :stage do |c|
            c.desc 'SSH port'
            c.flag %i(p port), type: Integer

            c.action &Command.run(Migrate, :stage)
          end

          m.desc 'Step 2., do an initial copy of container dataset'
          m.arg_name '<id>'
          m.command :sync do |c|
            c.action &Command.run(Migrate, :sync)
          end

          m.desc 'Step 3., transfer the container to target node'
          m.arg_name '<id>'
          m.command :transfer do |c|
            c.action &Command.run(Migrate, :transfer)
          end

          m.desc 'Step 4., cleanup the container on the source node'
          m.arg_name '<id>'
          m.command :cleanup do |c|
            c.desc 'Delete the container'
            c.switch %i(d delete), default_value: true

            c.action &Command.run(Migrate, :cleanup)
          end

          m.desc 'Cancel ongoing migration in mid-step'
          m.arg_name '<id>'
          m.command :cancel do |c|
            c.desc 'Cancel the migration on the local node, even if remote fails'
            c.switch %i(f force), negatable: false

            c.action &Command.run(Migrate, :cancel)
          end

          m.desc 'Migrate container at once (equals to steps 1-4 in succession)'
          m.arg_name '<id> <dst>'
          m.command :now do |c|
            c.desc 'SSH port'
            c.flag %i(p port), type: Integer

            c.desc 'Delete the container after migration'
            c.switch %i(d delete), default_value: true

            c.action &Command.run(Migrate, :now)
          end
        end

        ct.desc 'Access container LXC log file'
        ct.command :log do |log|
          log.desc 'Cat log file to stdout'
          log.arg_name '<id>'
          log.command :cat do |c|
            c.action &Command.run(Container, :log_cat)
          end

          log.desc 'Print path to the log file'
          log.arg_name '<id>'
          log.command :path do |c|
            c.action &Command.run(Container, :log_path)
          end
        end

        ct.desc 'Monitor container state changes'
        ct.arg_name '[id...]'
        ct.command :monitor do |c|
          c.action &Command.run(Event, :monitor_ct)
        end

        ct.desc 'Wait for container for container to enter state'
        ct.arg_name '<id> <state...>'
        ct.command :wait do |c|
          c.action &Command.run(Event, :wait_ct)
        end

        ct.desc 'Top-like container monitor'
        ct.arg_name '[id...]'
        ct.command :top do |c|
          c.desc 'Refresh rate, in seconds'
          c.flag %i(r rate), type: Float, default_value: 1.0

          c.action &Command.run(Top::Main, :start)
        end

        ct.desc 'Find containers by PID'
        ct.arg_name '[pid...] | -'
        ct.command :pid do |c|
          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.action &Command.run(Container, :pid)
        end

        ct.desc 'List container assets (datasets, files, directories)'
        ct.arg_name '<id>'
        assets(ct, Container)

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

              c.desc "MAC address"
              c.flag :hwaddr

              c.action &Command.run(NetInterface, :create_bridge)
            end

            create.desc 'Create a new routed veth interface'
            create.arg_name '<id> <name>'
            create.command :routed do |c|
              c.desc 'Route via network'
              c.flag :via, multiple: true, required: true

              c.desc "MAC address"
              c.flag :hwaddr

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
            ip.arg_name '<id> <name>'
            ip.command %i(ls list) do |c|
              c.desc 'Filter by IP version'
              c.flag %i(v version), type: Integer

              c.desc 'Select parameters to output'
              c.flag %i(o output)

              c.desc 'Do not show header'
              c.switch %i(H hide-header), negatable: false

              c.desc 'List available parameters'
              c.switch %i(L list), negatable: false

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
          end
        end

        cg_params(ct, Container)
        devices(ct, Container)

        ct.desc 'Manage resource limits'
        ct.command :prlimits do |pr|
          pr.desc 'List configured limits'
          pr.arg_name '<id> [limits...]'
          pr.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output)

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Container, :prlimit_list)
          end

          pr.desc 'Configure limit'
          pr.arg_name '<id> <limit> (<soft_and_hard>| <soft> <hard>)'
          pr.command :set do |c|
            c.action &Command.run(Container, :prlimit_set)
          end

          pr.desc 'Remove configured limit'
          pr.arg_name '<id> <limit>'
          pr.command :unset do |c|
            c.action &Command.run(Container, :prlimit_unset)
          end
        end

        ct.desc 'Manage container datasets'
        ct.command :dataset do |ds|
          ds.desc 'List datasets'
          ds.arg_name '<id>'
          ds.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output)

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Container, :dataset_list)
          end

          ds.desc 'Create a new dataset'
          ds.arg_name '<id> <name> [mountpoint]'
          ds.command %i(new create) do |c|
            c.desc 'Enable/disable auto mount'
            c.flag :mount, default_value: true

            c.action &Command.run(Container, :dataset_create)
          end

          ds.desc 'Delete dataset'
          ds.arg_name '<id> <name>'
          ds.command %i(del delete) do |c|
            c.desc 'Recursively delete all children as well'
            c.switch %i(r recursive)

            c.desc 'Unmount all affected mountpoints'
            c.switch %i(u umount unmount)

            c.action &Command.run(Container, :dataset_delete)
          end
        end

        ct.desc 'Manage mounts'
        ct.command :mounts do |m|
          m.desc 'List configured mounts'
          m.arg_name '<id>'
          m.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output)

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Container, :mount_list)
          end

          m.desc 'Create a new mount'
          m.arg_name '<id>'
          m.command %i(new create) do |c|
            c.desc 'Filesystem'
            c.flag :fs, required: true

            c.desc 'Mountpoint'
            c.flag :mountpoint, required: true

            c.desc 'Type'
            c.flag :type, required: true

            c.desc 'Options'
            c.flag :opts, required: true

            c.action &Command.run(Container, :mount_create)
          end

          m.desc 'Mount a dataset'
          m.arg_name '<id> <name> <mountpoint>'
          m.command :dataset do |c|
            c.desc 'Mount the dataset read-only'
            c.switch %i(ro read-only), negatable: false

            c.desc 'Mount the dataset read-write'
            c.switch %i(rw read-write), negatable: false

            c.action &Command.run(Container, :mount_dataset)
          end

          m.desc 'Remove mount'
          m.arg_name '<id> <mountpoint>'
          m.command %i(del delete) do |c|
            c.action &Command.run(Container, :mount_delete)
          end
        end
      end

      desc 'Migration key chain management'
      command :migration do |m|
        m.desc 'Manage local node identity'
        m.command :key do |k|
          k.desc 'Generate a new public/private key pair'
          k.command :gen do |c|
            c.desc 'Key type'
            c.flag %i(t type), must_match: %w(rsa ecdsa ed25519)

            c.desc 'Key bit size'
            c.flag %i(b bits), type: Integer

            c.desc 'Overwrite existing key'
            c.switch %i(f force), negatable: false

            c.action &Command.run(Migration, :key_gen)
          end

          k.desc 'Print path to public/private key'
          k.arg_name '[public | private]'
          k.command :path do |c|
            c.action &Command.run(Migration, :key_path)
          end
        end

        m.desc 'Manage keys authorized to migrate containers to this node'
        m.command 'authorized-keys' do |a|
          a.desc 'List authorized keys'
          a.command %i(ls list) do |c|
            c.action &Command.run(Migration, :authorized_keys_list)
          end

          a.desc 'Authorize a new key'
          a.command :add do |c|
            c.action &Command.run(Migration, :authorized_keys_add)
          end

          a.desc 'Remove authorized key by index'
          a.arg_name '<index>'
          a.command %i(del delete) do |c|
            c.action &Command.run(Migration, :authorized_keys_delete)
          end
        end
      end

      desc 'Manage template repositories'
      command %i(repo repository) do |r|
        r.desc 'List repositories'
        r.command %i(ls list) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output)

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(Repository, :list)
        end

        r.desc 'Add a new repository'
        r.arg_name '<name> <url>'
        r.command :add do |c|
          c.action &Command.run(Repository, :add)
        end

        r.desc 'Remove a repository'
        r.arg_name '<name>'
        r.command :del do |c|
          c.action &Command.run(Repository, :delete)
        end

        r.desc 'Enable a repository'
        r.arg_name '<name>'
        r.command :enable do |c|
          c.action &Command.run(Repository, :enable)
        end

        r.desc 'Disable a repository'
        r.arg_name '<name>'
        r.command :disable do |c|
          c.action &Command.run(Repository, :disable)
        end

        r.desc 'List repository assets (datasets, files, directories)'
        r.arg_name '<name>'
        assets(r, Repository)

        r.desc 'Browse repository templates'
        r.command :templates do |t|
          t.desc 'List available templates'
          t.arg_name '<name>'
          t.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output)

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.desc 'Filter by vendor'
            c.flag :vendor

            c.desc 'Filter by variant'
            c.flag :variant

            c.desc 'Filter by architecture'
            c.flag :arch

            c.desc 'Filter by distribution'
            c.flag :distribution

            c.desc 'Filter by distribution version'
            c.flag :version

            c.desc 'Filter by version tag'
            c.flag :tag

            c.desc 'Filter locally cached templates'
            c.switch :cached, negatable: false

            c.desc 'Filter locally uncached templates'
            c.switch :uncached, negatable: false

            c.action &Command.run(Repository, :template_list)
          end
        end
      end

      desc 'Monitor'
      command :monitor do |c|
        c.action &Command.run(Event, :monitor)
      end

      desc 'Browse pool management history'
      arg_name '[pool]'
      command :history do |c|
        c.action &Command.run(History, :list)
      end

      desc "List osctld's assets (datasets, files, directories)"
      assets(self, Self)

      desc 'Health check'
      arg_name '[pool...]'
      command :healthcheck do |c|
        c.desc 'Check all pools'
        c.switch %i(a all), negatable: false

        c.action &Command.run(Self, :healthcheck)
      end

      desc 'Export all pools and stop all containers'
      command :shutdown do |c|
        c.action &Command.run(Self, :shutdown)
      end
    end

    protected
    def assets(cmd, handler)
      cmd.command :assets do |c|
        c.desc 'Verbose output'
        c.switch %i(v verbose)

        c.action &Command.run(handler, :assets)
      end
    end

    def cg_params(cmd, handler)
      cmd.desc 'Manage CGroup parameters'
      cmd.command :cgparams do |p|
        p.desc 'List configured parameters'
        p.arg_name '<name>'
        p.command %i(ls list) do |c|
          c.desc 'Filter by CGroup subsystem (comma separated)'
          c.flag %i(S subsystem)

          c.desc 'Show all parameters from parent groups up to <name>'
          c.switch %i(a all), negatable: false

          c.desc 'Select parameters to output'
          c.flag %i(o output)

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(handler, :cgparam_list)
        end

        p.desc 'Configure parameters'
        p.arg_name '<name> <parameter> <value...>'
        p.command :set do |c|
          c.desc 'Append new values, do not overwrite previous values'
          c.switch %i(a append), negatable: false

          c.action &Command.run(handler, :cgparam_set)
        end

        p.desc 'Remove configured parameter'
        p.arg_name '<name> <parameter>'
        p.command :unset do |c|
          c.action &Command.run(handler, :cgparam_unset)
        end

        p.desc 'Reapply configured parameters'
        p.arg_name '<name>'
        p.command :apply do |c|
          c.action &Command.run(handler, :cgparam_apply)
        end
      end
    end

    def devices(cmd, handler)
      cmd.desc 'Manage devices'
      cmd.command :devices do |dev|
        dev.desc 'List allowed devices'
        dev.arg_name '<name>'
        dev.command %i(ls list) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output)

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(handler, :device_list)
        end

        dev.desc 'Grant access to device'
        dev.arg_name '<name> block|char <major> <minor> <mode> [device]'
        dev.command :add do |c|
          c.desc 'Should subgroups and containers inherit the device?'
          c.switch %i(i inherit), default_value: true

          c.desc 'Grant access to the device to all parent groups'
          c.switch %i(p parents)

          c.action &Command.run(handler, :device_add)
        end

        dev.desc 'Revoke access to device'
        dev.arg_name '<name> block|char <major> <minor>'
        dev.command %i(del delete) do |c|
          c.desc 'Remove device from all child groups and containers'
          c.switch %i(r recursive), negatable: false

          c.action &Command.run(handler, :device_delete)
        end

        dev.desc 'Change device access mode'
        dev.arg_name '<name> block|char <major> <minor> <mode>|-'
        dev.command :chmod do |c|
          c.desc "Extend the parents' device access if necessary"
          c.switch %i(p parents)

          c.desc 'Change device access mode in all child groups and containers that use it'
          c.switch %i(r recursive), negatable: false

          c.action &Command.run(handler, :device_chmod)
        end

        dev.desc 'Promote an inherited device, declaring an explicit requirement'
        dev.arg_name '<name> block|char <major> <minor>'
        dev.command :promote do |c|
          c.action &Command.run(handler, :device_promote)
        end

        dev.desc 'Inherit a promoted device'
        dev.arg_name '<name> block|char <major> <minor>'
        dev.command :inherit do |c|
          c.action &Command.run(handler, :device_inherit)
        end

        dev.desc 'Set inheritance'
        dev.command :set do |set|
          set.desc 'Let child groups and containers inherit specified device'
          set.arg_name '<name> block|char <major> <minor>'
          set.command :inherit do |c|
            c.action &Command.run(handler, :device_set_inherit)
          end
        end

        dev.desc 'Unset inheritance'
        dev.command :unset do |unset|
          unset.desc 'Prevent child groups and containers from inheriting specified device'
          unset.arg_name '<name> block|char <major> <minor>'
          unset.command :inherit do |c|
            c.action &Command.run(handler, :device_unset_inherit)
          end
        end
      end
    end
  end
end
