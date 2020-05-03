require 'gli'
require 'thread'

module OsCtl::Cli
  class App
    include GLI::App

    def self.get
      cli = new
      cli.setup
      cli
    end

    def self.run
      cli = get
      exit(cli.run(ARGV))
    end

    def setup
      Thread.abort_on_exception = true

      program_desc 'Management utility for vpsAdminOS'
      version OsCtl::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict
      hide_commands_without_desc true

      desc 'Show precise values'
      switch %i(p parsable), negatable: false

      desc 'Format output in JSON'
      switch %i(j json), negatable: false

      desc 'Toggle colorized output'
      switch :color, default_value: true

      desc 'Pool name'
      flag :pool, arg_name: 'pool'

      desc 'Surpress output'
      switch %i(q quiet), negatable: false

      desc 'Manage data pools'
      command :pool do |p|
        p.desc 'List imported pools'
        p.arg_name '[pools...]'
        p.command %i(ls list) do |ls|
          ls.desc 'Select parameters to output'
          ls.flag %i(o output), arg_name: 'parameters'

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.desc 'Sort by parameter(s)'
          ls.flag %i(s sort), arg_name: 'parameters'

          ls.action &Command.run(Pool, :list)
        end

        p.desc 'Show information about imported pool'
        p.arg_name '<pool>'
        p.command :show do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(Pool, :show)
        end

        p.desc 'Import pool(s)'
        p.arg_name '[pool]'
        p.command :import do |c|
          c.desc 'Import all installed pools'
          c.switch %i(a all), negatable: false

          c.desc 'Start containers that are configured to be started automatically'
          c.switch %i(s autostart), default_value: true

          c.action &Command.run(Pool, :import)
        end

        p.desc 'Export imported pool'
        p.arg_name '<pool>'
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
        p.arg_name '<pool>'
        p.command :install do |c|
          c.desc 'Place osctld datasets into a subdataset'
          c.flag :dataset, arg_name: 'dataset'

          c.action &Command.run(Pool, :install)
        end

        p.desc 'Uninstall pool'
        p.arg_name '<pool>'
        p.command :uninstall do |c|
          c.action &Command.run(Pool, :uninstall)
        end

        p.desc "List pool's assets (datasets, files, directories)"
        p.arg_name '<pool>'
        assets(p, Pool)

        p.desc 'Check and trigger container auto-starting'
        p.command :autostart do |as|
          as.desc 'Check auto-start queue'
          as.arg_name '<pool>'
          as.command :queue do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Pool, :autostart_queue)
          end

          as.desc 'Start containers that have auto-start enabled'
          as.arg_name '<pool>'
          as.command :trigger do |c|
            c.action &Command.run(Pool, :autostart_trigger)
          end

          as.desc 'Cancel start of containers left in the queue'
          as.arg_name '<pool>'
          as.command :cancel do |c|
            c.action &Command.run(Pool, :autostart_cancel)
          end
        end

        p.desc 'Configure pool options'
        p.command :set do |set|
          set.desc 'How many containers should be simultaneously started at pool import'
          set.arg_name '<pool> <n>'
          set.command 'parallel-start' do |c|
            c.action &Command.run(Pool, :set, [:parallel_start])
          end

          set.desc 'How many containers should be simultaneously stopped at pool export'
          set.arg_name '<pool> <n>'
          set.command 'parallel-stop' do |c|
            c.action &Command.run(Pool, :set, [:parallel_stop])
          end

          set_attr(set, Pool, 'pool')
        end

        p.desc 'Reset pool options'
        p.command :unset do |unset|
          unset.desc 'How many containers should be simultaneously started at pool import'
          unset.arg_name '<pool>'
          unset.command 'parallel-start' do |c|
            c.action &Command.run(Pool, :unset, [:parallel_start])
          end

          unset.desc 'How many containers should be simultaneously stopped at pool export'
          unset.arg_name '<pool>'
          unset.command 'parallel-stop' do |c|
            c.action &Command.run(Pool, :unset, [:parallel_stop])
          end

          unset_attr(unset, Pool, 'pool')
        end
      end

      desc 'Manage ID ranges'
      command 'id-ranges' do |idr|
        idr.desc 'Create a new ID range'
        idr.arg_name '<id-range>'
        idr.command %i(new create) do |c|
          c.desc 'The first user/group ID'
          c.flag 'start-id', arg_name: 'n', required: true, type: Integer

          c.desc 'Number of user/group IDs making up the minimum allocation unit'
          c.flag 'block-size', arg_name: 'n', required: true, type: Integer

          c.desc 'How many blocks should the range include'
          c.flag 'block-count', arg_name: 'n', required: true, type: Integer

          c.action &Command.run(IdRange, :create)
        end

        idr.desc 'Delete ID range'
        idr.arg_name '<id-range>'
        idr.command %i(del delete) do |c|
          c.action &Command.run(IdRange, :delete)
        end

        idr.desc 'List configured ID ranges'
        idr.arg_name '[id-range...]'
        idr.command %i(ls list) do |ls|
          ls.desc 'Select parameters to output'
          ls.flag %i(o output), arg_name: 'parameters'

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.desc 'Sort by parameter(s)'
          ls.flag %i(s sort), arg_name: 'parameters'

          ls.action &Command.run(IdRange, :list)
        end

        idr.desc "Show ID range info"
        idr.arg_name '<id-range>'
        idr.command %i(show info) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(IdRange, :show)
        end

        idr.desc 'Access allocation table'
        idr.command :table do |tbl|
          tbl.desc 'List entries in the allocation table'
          tbl.arg_name '<id-range> [all|allocated|free]'
          tbl.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.desc 'Sort by parameter(s)'
            c.flag %i(s sort), arg_name: 'parameters'

            c.action &Command.run(IdRange, :table_list)
          end

          tbl.desc 'Show information about entry in the allocation table'
          tbl.arg_name '<id-range> <block-index>'
          tbl.command %i(show info) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(IdRange, :table_show)
          end
        end

        idr.desc 'Allocate blocks from ID range'
        idr.arg_name '<id-range>'
        idr.command :allocate do |c|
          c.desc 'Number of blocks to allocate'
          c.flag 'block-count', arg_name: 'n', default_value: 1, type: Integer

          c.desc 'Optional index of the starting block'
          c.flag 'block-index', arg_name: 'n', type: Integer

          c.desc 'Identify owner of the allocation'
          c.flag 'owner'

          c.action &Command.run(IdRange, :allocate)
        end

        idr.desc 'Free allocated blocks from ID range'
        idr.arg_name '<id-range>'
        idr.command :free do |c|
          c.desc 'Index of a block to free'
          c.flag 'block-index', type: Integer

          c.desc 'Free allocations belonging to owner'
          c.flag 'owner'

          c.action &Command.run(IdRange, :free)
        end

        idr.desc "List ID range assets (datasets, files, directories)"
        idr.arg_name '<id-range>'
        assets(idr, IdRange)

        idr.desc 'Configure ID range options'
        idr.command :set do |set|
          set_attr(set, IdRange, 'id-range')
        end

        idr.desc 'Reset ID range options'
        idr.command :unset do |unset|
          unset_attr(unset, IdRange, 'id-range')
        end
      end

      desc 'Manage system users and user namespace configuration'
      command :user do |u|
        u.desc 'List available users'
        u.arg_name '[user...]'
        u.command %i(ls list) do |ls|
          ls.desc 'Filter by pool, comma separated'
          ls.flag :pool, arg_name: 'pool'

          ls.desc 'Filter registered users'
          ls.switch 'registered', negatable: false

          ls.desc 'Filter unregistered users'
          ls.switch 'unregistered', negatable: false

          ls.desc 'Select parameters to output'
          ls.flag %i(o output), arg_name: 'parameters'

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.desc 'Sort by parameter(s)'
          ls.flag %i(s sort), arg_name: 'parameters'

          ls.action &Command.run(User, :list)
        end

        u.desc "Show user info"
        u.arg_name '<user>'
        u.command %i(show info) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(User, :show)
        end

        u.desc 'Create a new user with user namespace configuration'
        u.arg_name '<user>'
        u.command %i(new create) do |new|
          new.desc 'Pool name'
          new.flag :pool, arg_name: 'pool'

          new.desc 'ID range to allocate UID/GID block from'
          new.flag 'id-range', arg_name: 'id-range'

          new.desc 'Specify allocated block index from ID range'
          new.flag 'id-range-block-index', type: Integer, arg_name: 'n'

          new.desc 'UID/GID mapping'
          new.flag 'map', multiple: true, arg_name: 'id_map'

          new.desc 'UID mapping'
          new.flag 'map-uid', multiple: true, arg_name: 'uid_map'

          new.desc 'GID mapping'
          new.flag 'map-gid', multiple: true, arg_name: 'gid_map'

          new.action &Command.run(User, :create)
        end

        u.desc 'Delete user'
        u.arg_name '<user>'
        u.command %i(del delete) do |del|
          del.action &Command.run(User, :delete)
        end

        u.desc 'Register users into the system'
        u.arg_name '<user>|all'
        u.command %i(reg register) do |c|
          c.action &Command.run(User, :register)
        end

        u.desc 'Unregister users from the system'
        u.arg_name '<user>|all'
        u.command %i(unreg unregister) do |c|
          c.action &Command.run(User, :unregister)
        end

        u.desc 'Generate /etc/subuid and /etc/subgid'
        u.command :subugids do |sub|
          sub.action &Command.run(User, :subugids)
        end

        u.desc "List user's assets (datasets, files, directories)"
        u.arg_name '<user>'
        assets(u, User)

        u.desc "List UID/GID mappings"
        u.arg_name '<user> [uid|gid|both]'
        u.command :map do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(User, :idmap_ls)
        end

        u.desc 'Configure user options'
        u.command :set do |set|
          set_attr(set, User, 'user')
        end

        u.desc 'Reset user options'
        u.command :unset do |unset|
          unset_attr(unset, User, 'user')
        end
      end

      desc 'Manage groups used for cgroup-based resource limiting'
      command :group do |grp|
        grp.desc 'List available groups'
        grp.arg_name '[group...]'
        grp.command %i(ls list) do |ls|
          ls.desc 'Filter by pool, comma separated'
          ls.flag :pool, arg_name: 'pool'

          ls.desc 'Select parameters to output'
          ls.flag %i(o output), arg_name: 'parameters'

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.desc 'Sort by parameter(s)'
          ls.flag %i(s sort), arg_name: 'parameters'

          ls.action &Command.run(Group, :list)
        end

        grp.desc 'Print group tree'
        grp.arg_name '<pool>'
        grp.command :tree do |c|
          c.action &Command.run(Group, :tree)
        end

        grp.desc 'Show group info'
        grp.arg_name '<group>'
        grp.command %i(show find) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(Group, :show)
        end

        grp.desc 'Create group'
        grp.arg_name '<group>'
        grp.command %i(new create) do |new|
          new.desc 'Pool name'
          new.flag :pool, arg_name: 'pool'

          new.desc 'Create missing parent groups'
          new.switch %i(p parents)

          new.desc 'Set CGroup parameter'
          new.flag %i(cgparam), multiple: true

          new.action &Command.run(Group, :create)
        end

        grp.desc 'Delete group'
        grp.arg_name '<group>'
        grp.command %i(del delete) do |del|
          del.action &Command.run(Group, :delete)
        end

        grp.desc 'Configure group'
        grp.command :set do |set|
          set_limits(set, Group, 'group')
          set_attr(set, Group, 'group')
        end

        grp.desc 'Clear configuration options'
        grp.command :unset do |unset|
          unset_limits(unset, Group, 'group')
          unset_attr(unset, Group, 'group')
        end

        grp.desc "List group's assets (datasets, files, directories)"
        grp.arg_name '<group>'
        assets(grp, Group)

        cg_params(grp, Group, 'group')
        devices(grp, Group, 'group')
      end

      desc 'Manage containers'
      command %i(ct vps) do |ct|
        ct.desc 'List containers'
        ct.arg_name '[ctid...]'
        ct.command %i(ls list) do |ls|
          ls.desc 'Filter by pool, comma separated'
          ls.flag :pool, arg_name: 'pool'

          ls.desc 'Filter by user name, comma separated'
          ls.flag %i(u user), arg_name: 'user'

          ls.desc 'Filter by group name, comma separated'
          ls.flag %i(g group), arg_name: 'group'

          ls.desc 'Filter by distribution, comma separated'
          ls.flag %i(d distribution), arg_name: 'distribution'

          ls.desc 'Filter by distribution version, comma separated'
          ls.flag %i(v version), arg_name: 'version'

          ls.desc 'Filter by state, comma separated'
          ls.flag %i(S state), arg_name: 'state'

          ls.desc 'Filter ephemeral containers'
          ls.switch %i(e ephemeral), negatable: false

          ls.desc 'Filter persistent (non-ephemeral) containers'
          ls.switch %i(p persistent), negatable: false

          ls.desc 'Select parameters to output'
          ls.flag %i(o output), arg_name: 'parameters'

          ls.desc 'Do not show header'
          ls.switch %i(H hide-header), negatable: false

          ls.desc 'List available parameters'
          ls.switch %i(L list), negatable: false

          ls.desc 'Sort by parameter(s)'
          ls.flag %i(s sort), arg_name: 'parameters'

          ls.action &Command.run(Container, :list)
        end

        ct.desc 'Print tree of containers and groups'
        ct.arg_name '<pool>'
        ct.command :tree do |c|
          c.action &Command.run(Container, :tree)
        end

        ct.desc "Show container's info"
        ct.arg_name '<ctid>'
        ct.command %i(show info) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(Container, :show)
        end

        ct.desc 'Create container'
        ct.arg_name '<ctid>'
        ct.command %i(new create) do |new|
          new.desc 'Pool name'
          new.flag :pool, arg_name: 'pool'

          new.desc 'User name'
          new.flag :user, arg_name: 'user'

          new.desc 'Group name'
          new.flag :group, required: false, arg_name: 'group'

          new.desc 'Use a custom dataset for the rootfs'
          new.flag :dataset, arg_name: 'dataset'

          new.desc 'Do not extract any image'
          new.switch 'skip-image', negatable: false

          new.desc 'Distribution name in lower case'
          new.flag :distribution, arg_name: 'distribution'

          new.desc 'Distribution version'
          new.flag :version, arg_name: 'version'

          new.desc 'Architecture'
          new.flag :arch, arg_name: 'arch'

          new.desc 'Vendor (used only when downloading the image)'
          new.flag :vendor, arg_name: 'vendor'

          new.desc 'Variant (used only when downloading the image)'
          new.flag :variant, arg_name: 'variant'

          new.desc 'Repository'
          new.flag :repository, arg_name: 'repository'

          new.action &Command.run(Container, :create)
        end

        ct.desc 'Delete container'
        ct.arg_name '<ctid>'
        ct.command %i(del delete) do |c|
          c.desc 'Stop and delete running container'
          c.switch %i(f force), negatable: false

          c.action &Command.run(Container, :delete)
        end

        ct.desc 'Reinstall container'
        ct.arg_name '<ctid>'
        ct.command :reinstall do |c|
          c.desc 'Reinstall from container image'
          c.flag 'from-file', arg_name: 'file'

          c.desc 'Distribution name in lower case'
          c.flag :distribution, arg_name: 'distribution'

          c.desc 'Distribution version'
          c.flag :version, arg_name: 'version'

          c.desc 'Architecture'
          c.flag :arch, arg_name: 'arch'

          c.desc 'Vendor (used only when downloading the image)'
          c.flag :vendor, arg_name: 'vendor'

          c.desc 'Variant (used only when downloading the image)'
          c.flag :variant, arg_name: 'variant'

          c.desc 'Repository'
          c.flag :repository, arg_name: 'repository'

          c.desc 'Remove snapshots of the root dataset'
          c.switch %i(r remove-snapshots)

          c.action &Command.run(Container, :reinstall)
        end

        ct.desc "Mount the container's datasets"
        ct.arg_name '<ctid>'
        ct.command :mount do |c|
          c.action &Command.run(Container, :mount)
        end

        ct.desc 'Start container'
        ct.arg_name '<ctid>'
        ct.command :start do |c|
          c.desc 'How long to wait for the container to start'
          c.flag %i(w wait), type: Integer, default_value: 60, arg_name: 'n'

          c.desc 'Open container console (can be later detached)'
          c.switch %i(F foreground)

          c.desc 'Enqueue the start operation using pool autostart facility'
          c.switch %i(q queue)

          c.desc 'Priority for the autostart queue'
          c.flag %i(p priority), type: Integer, default_value: 10, arg_name: 'n'

          c.desc 'Enable debug messages in LXC'
          c.switch %i(D debug)

          c.action &Command.run(Container, :start)
        end

        ct.desc 'Stop container'
        ct.arg_name '<ctid>'
        ct.command :stop do |c|
          c.desc 'Open container console (can be later detached)'
          c.switch %i(F foreground)

          c.desc 'How many seconds to wait before killing the container'
          c.flag %i(t timeout), type: Integer, default_value: 60, arg_name: 'n'

          c.desc 'Do not request a clean shutdown, kill the container'
          c.switch %i(k kill), negatable: false

          c.desc 'Do not kill the container if clean shutdown fails'
          c.switch 'dont-kill', negatable: false

          c.action &Command.run(Container, :stop)
        end

        ct.desc 'Restart container'
        ct.arg_name '<ctid>'
        ct.command :restart do |c|
          c.desc 'How long to wait for the container to start'
          c.flag %i(w wait), type: Integer, default_value: 60, arg_name: 'n'

          c.desc 'Open container console (can be later detached)'
          c.switch %i(F foreground)

          c.desc 'Request reboot by signaling the init process'
          c.switch %i(r reboot)

          c.desc 'How many seconds to wait before killing the container'
          c.flag %i(t timeout), type: Integer, default_value: 60, arg_name: 'n'

          c.desc 'Do not request a clean shutdown, kill the container'
          c.switch %i(k kill), negatable: false

          c.desc 'Do not kill the container if clean shutdown fails'
          c.switch 'dont-kill', negatable: false

          c.action &Command.run(Container, :restart)
        end

        ct.desc "Open container's console"
        ct.arg_name '<ctid>'
        ct.command :console do |c|
          c.desc 'TTY'
          c.flag [:t, :tty], type: Integer, default_value: 0, arg_name: 'ttyN'

          c.action &Command.run(Container, :console)
        end

        ct.desc 'Attach the container'
        ct.arg_name '<ctid>'
        ct.command %i(attach enter) do |c|
          c.desc 'Run shell as configured in the container'
          c.switch %i(u user-shell), negatable: false

          c.action &Command.run(Container, :attach)
        end

        ct.desc 'Execute a command within the container'
        ct.arg_name '<ctid> <cmd...>'
        ct.command %i(exec) do |c|
          c.desc "Run the container if it isn't running already"
          c.switch %i(r run-container), negatable: false

          c.desc 'Configure network'
          c.switch %i(n network), negatable: false

          c.action &Command.run(Container, :exec)
        end

        ct.desc 'Run script within the container'
        ct.arg_name '<ctid> <script> [arguments...]'
        ct.command %i(runscript) do |c|
          c.desc "Run the container if it isn't running already"
          c.switch %i(r run-container), negatable: false

          c.desc 'Configure network'
          c.switch %i(n network), negatable: false

          c.action &Command.run(Container, :runscript)
        end

        ct.desc "Get container's user's shell"
        ct.arg_name '<ctid>'
        ct.command :su do |su|
          su.action &Command.run(Container, :su)
        end

        ct.desc 'Configure container'
        ct.command :set do |set|
          set.desc 'Start the container when its pool is imported'
          set.arg_name '<ctid>'
          set.command :autostart do |c|
            c.desc 'Start priority (0 is the highest priority)'
            c.flag %i(p priority), type: Integer, default_value: 10, arg_name: 'n'

            c.desc 'How long to wait before starting another container, in seconds'
            c.flag %i(d delay), type: Integer, default_value: 5, arg_name: 'n'

            c.action &Command.run(Container, :set_autostart)
          end

          set.desc 'Destroy the container after it is stopped'
          set.arg_name '<ctid>'
          set.command :ephemeral do |c|
            c.action &Command.run(Container, :set_ephemeral)
          end

          set.desc 'Set hostname'
          set.arg_name '<ctid> <hostname>'
          set.command :hostname do |c|
            c.action &Command.run(Container, :set_hostname)
          end

          set.desc 'Set DNS resolver'
          set.arg_name '<ctid> <address...>'
          set.command :'dns-resolver' do |c|
            c.action &Command.run(Container, :set_dns_resolver)
          end

          set.desc 'Enable container nesting'
          set.arg_name '<ctid>'
          set.command :nesting do |c|
            c.action &Command.run(Container, :set_nesting)
          end

          set.desc 'Change distribution and version info'
          set.arg_name '<ctid> <distribution> <version> [arch]'
          set.command :distribution do |c|
            c.action &Command.run(Container, :set_distribution)
          end

          set.desc 'Set image config'
          set.arg_name '<ctid>'
          set.command 'image-config' do |c|
            c.desc 'Use container image from local file'
            c.flag 'from-file', arg_name: 'file'

            c.desc 'Distribution name in lower case'
            c.flag :distribution, arg_name: 'distribution'

            c.desc 'Distribution version'
            c.flag :version, arg_name: 'version'

            c.desc 'Architecture'
            c.flag :arch, arg_name: 'arch'

            c.desc 'Vendor (used only when downloading the image)'
            c.flag :vendor, arg_name: 'vendor'

            c.desc 'Variant (used only when downloading the image)'
            c.flag :variant, arg_name: 'variant'

            c.desc 'Repository'
            c.flag :repository, arg_name: 'repository'

            c.action &Command.run(Container, :set_image_config)
          end

          set.desc 'Set path to seccomp profile'
          set.arg_name '<ctid> <profile>'
          set.command :seccomp do |c|
            c.action &Command.run(Container, :set_seccomp_profile)
          end

          set.desc 'Set path to the binary within the container to use as init'
          set.arg_name '<ctid> <binary> [arguments...]'
          set.command :'init-cmd' do |c|
            c.action &Command.run(Container, :set_init_cmd)
          end

          set.desc 'Append raw configuration to auto-generated config files'
          set.command :raw do |raw|
            raw.desc 'Append raw LXC configuration'
            raw.arg_name '<ctid>'
            raw.command :lxc do |c|
              c.action &Command.run(Container, :set_raw_lxc)
            end
          end

          set_attr(set, Container, 'ctid')
          set_limits(set, Container, 'ctid')
        end

        ct.desc 'Clear configuration options'
        ct.command :unset do |unset|
          unset.desc 'Disable automatic container starting'
          unset.arg_name '<ctid>'
          unset.command :autostart do |c|
            c.action &Command.run(Container, :unset_autostart)
          end

          unset.desc 'Do not destroy the container after it is stopped'
          unset.arg_name '<ctid>'
          unset.command :ephemeral do |c|
            c.action &Command.run(Container, :unset_ephemeral)
          end

          unset.desc 'Disable hostname management'
          unset.arg_name '<ctid>'
          unset.command :hostname do |c|
            c.action &Command.run(Container, :unset_hostname)
          end

          unset.desc 'Disable DNS resolver management'
          unset.arg_name '<ctid>'
          unset.command :'dns-resolver' do |c|
            c.action &Command.run(Container, :unset_dns_resolver)
          end

          unset.desc 'Disable container nesting'
          unset.arg_name '<ctid>'
          unset.command :nesting do |c|
            c.action &Command.run(Container, :unset_nesting)
          end

          unset.desc 'Use the default seccomp profile'
          unset.arg_name '<ctid>'
          unset.command :seccomp do |c|
            c.action &Command.run(Container, :unset_seccomp_profile)
          end

          unset.desc 'Use default path to binary used as init (/sbin/init)'
          unset.arg_name '<ctid>'
          unset.command :'init-cmd' do |c|
            c.action &Command.run(Container, :unset_init_cmd)
          end

          unset.desc 'Remove raw configuration from auto-generated config files'
          unset.command :raw do |raw|
            raw.desc 'Remove raw LXC configuration'
            raw.arg_name '<ctid>'
            raw.command :lxc do |c|
              c.action &Command.run(Container, :unset_raw_lxc)
            end
          end

          unset_attr(unset, Container, 'ctid')
          unset_limits(unset, Container, 'ctid')
        end

        ct.desc 'Copy container'
        ct.arg_name '<ctid> [pool:]<new-id>'
        ct.command %i(cp copy) do |c|
          c.desc 'Stop the container during the copy'
          c.switch :consistent, default_value: true

          c.desc 'Target pool'
          c.flag :pool, arg_name: 'pool'

          c.desc 'Target user'
          c.flag :user, arg_name: 'user'

          c.desc 'Target group'
          c.flag :group, arg_name: 'group'

          c.desc 'Target dataset'
          c.flag :dataset, arg_name: 'dataset'

          c.desc 'Copy network interfaces'
          c.switch 'network-interfaces', default_value: true

          c.action &Command.run(Container, :copy)
        end

        ct.desc 'Move container'
        ct.arg_name '<ctid> [pool:]<new-id>'
        ct.command %i(mv move) do |c|
          c.desc 'Target pool'
          c.flag :pool, arg_name: 'pool'

          c.desc 'Target user'
          c.flag :user, arg_name: 'user'

          c.desc 'Target group'
          c.flag :group, arg_name: 'group'

          c.desc 'Target dataset'
          c.flag :dataset, arg_name: 'dataset'

          c.action &Command.run(Container, :move)
        end

        ct.desc 'Move the container to another user namespace'
        ct.arg_name '<ctid> <user>'
        ct.command :chown do |c|
          c.action &Command.run(Container, :chown)
        end

        ct.desc 'Move the container to another group'
        ct.arg_name '<ctid> <group>'
        ct.command :chgrp do |c|
          c.desc 'Provide or remove missing devices'
          c.flag 'missing-devices', must_match: %w(provide remove check)

          c.action &Command.run(Container, :chgrp)
        end

        ct.desc "Manipulate the container's config file"
        ct.command %i(cfg config) do |cfg|
          cfg.desc "Reload the container's configuration file"
          cfg.arg_name '<ctid>'
          cfg.command :reload do |c|
            c.action &Command.run(Container, :config_reload)
          end

          cfg.desc "Replace the container's configuration file"
          cfg.arg_name '<ctid>'
          cfg.command :replace do |c|
            c.action &Command.run(Container, :config_replace)
          end
        end

        ct.desc 'Set password for a user within the container'
        ct.arg_name '<ctid> <username> [password]'
        ct.command :passwd do |c|
          c.action &Command.run(Container, :passwd)
        end

        ct.desc "Go to container's rootfs directory"
        ct.arg_name '<ctid>'
        ct.command :cd do |c|
          c.desc "Go to /proc/<init_pid>/root"
          c.switch %i(r runtime), negatable: false

          c.desc "Go to LXC config directory"
          c.switch %i(l lxc), negatable: false

          c.action &Command.run(Container, :cd)
        end

        ct.desc 'Regenerate LXC configuration'
        ct.arg_name '<ctid>'
        ct.command :reconfigure do |c|
          c.action &Command.run(Container, :reconfigure)
        end

        ct.desc 'Export the container configs and data into a tar archive'
        ct.arg_name '<ctid> <file>'
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
          c.flag :dataset, arg_name: 'dataset'

          c.desc 'Provide or remove missing devices'
          c.flag 'missing-devices', must_match: %w(provide remove check)

          c.action &Command.run(Container, :import)
        end

        ct.desc 'Send container at once (equals to steps 1-4 in succession)'
        ct.arg_name '<ctid> <dst>'
        ct.command :send do |s|
          s.desc 'SSH port'
          s.flag %i(p port), type: Integer, arg_name: 'port'

          s.desc 'Send the container with a different id'
          s.flag 'as-id'

          s.desc 'Pool on the target node to send the container to'
          s.flag 'to-pool'

          s.desc 'Clone the container on the target node, do not move it'
          s.switch :clone

          s.desc 'Stop the container when cloning'
          s.switch :consistent, default_value: true

          s.desc 'Do not restart the container after cloning on the source node'
          s.switch :restart, default_value: true

          s.desc 'Do not start the container on the target node'
          s.switch :start, default_value: true

          s.desc 'Send network interfaces to target node'
          s.switch 'network-interfaces', default_value: true

          s.action &Command.run(Send, :now)

          s.desc 'Step 1., copy configs to target node'
          s.arg_name '<ctid> <dst>'
          s.command :config do |c|
            c.desc 'SSH port'
            c.flag %i(p port), type: Integer, arg_name: 'port'

            c.desc 'Send the container with a different id'
            c.flag 'as-id'

            c.desc 'Pool on the target node to send the container to'
            c.flag 'to-pool'

            c.desc 'Send network interfaces to target node'
            c.switch 'network-interfaces', default_value: true

            c.action &Command.run(Send, :config)
          end

          s.desc 'Step 2., do an initial copy of container dataset'
          s.arg_name '<ctid>'
          s.command :rootfs do |c|
            c.action &Command.run(Send, :rootfs)
          end

          s.desc 'Optional step 3., transfer rootfs changes'
          s.arg_name '<ctid>'
          s.command :sync do |c|
            c.action &Command.run(Send, :sync)
          end

          s.desc 'Step 4., transfer the container to target node'
          s.arg_name '<ctid>'
          s.command :state do |c|
            c.desc 'Clone the container on the target node, do not move it'
            c.switch :clone

            c.desc 'Stop the container when cloning'
            c.switch :consistent, default_value: true

            c.desc 'Do not restart the container after cloning on the source node'
            c.switch :restart, default_value: true

            c.desc 'Do not start the container on the target node'
            c.switch :start, default_value: true

            c.action &Command.run(Send, :state)
          end

          s.desc 'Step 5., cleanup the container on the source node'
          s.arg_name '<ctid>'
          s.command :cleanup do |c|
            c.action &Command.run(Send, :cleanup)
          end

          s.desc 'Cancel ongoing send in mid-step'
          s.arg_name '<ctid>'
          s.command :cancel do |c|
            c.desc 'Cancel the send on the local node, even if remote fails'
            c.switch %i(f force), negatable: false

            c.desc 'Cancel the send only on the local node'
            c.switch %i(l local), negatable: false

            c.action &Command.run(Send, :cancel)
          end
        end

        ct.desc 'Access container LXC log file'
        ct.command :log do |log|
          log.desc 'Cat log file to stdout'
          log.arg_name '<ctid>'
          log.command :cat do |c|
            c.action &Command.run(Container, :log_cat)
          end

          log.desc 'Print path to the log file'
          log.arg_name '<ctid>'
          log.command :path do |c|
            c.action &Command.run(Container, :log_path)
          end
        end

        ct.desc 'Monitor container state changes'
        ct.arg_name '[ctid...]'
        ct.command :monitor do |c|
          c.action &Command.run(Event, :monitor_ct)
        end

        ct.desc 'Wait for container for container to enter state'
        ct.arg_name '<ctid> <state...>'
        ct.command :wait do |c|
          c.action &Command.run(Event, :wait_ct)
        end

        ct.desc 'Top-like container monitor'
        ct.arg_name '[ctid...]'
        ct.command :top do |c|
          c.desc 'Refresh rate, in seconds'
          c.flag %i(r rate), type: Float, default_value: 1.0, arg_name: 'n'

          c.action &Command.run(Top::Main, :start)
        end

        ct.desc 'Find containers by PID'
        ct.arg_name '[pid...] | -'
        ct.command :pid do |c|
          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.action &Command.run(Container, :pid)
        end

        ct.desc 'List container processes'
        ct.arg_name '<ctid>'
        ct.command :ps do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.desc 'Sort by parameter(s)'
          c.flag %i(s sort), arg_name: 'parameters'

          c.action &Command.run(Ps::Main, :run)
        end

        ct.desc 'List container assets (datasets, files, directories)'
        ct.arg_name '<ctid>'
        assets(ct, Container)

        ct.desc "Manage container's network interfaces"
        ct.command %i(netif net) do |net|
          net.desc "List network interfaces"
          net.arg_name '<ctid>'
          net.command %i(ls list) do |c|
            c.desc 'Filter by interface type'
            c.flag %i(t type), arg_name: 'netif_type'

            c.desc 'Filter by linked bridge'
            c.flag %i(l link), arg_name: 'netif_bridge'

            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.desc 'Sort by parameter(s)'
            c.flag %i(s sort), arg_name: 'parameters'

            c.action &Command.run(NetInterface, :list)
          end

          net.desc "Create a new network interface"
          net.command %i(new create) do |create|
            create.desc 'Create a new bridged veth interface'
            create.arg_name '<ctid> <ifname>'
            create.command :bridge do |c|
              c.desc 'What bridge should the interface be linked with'
              c.flag :link, required: true, arg_name: 'host_netif'

              c.desc 'Use DHCP client within the container'
              c.switch :dhcp, default_value: true

              c.desc 'IPv4 gateway to use when DHCP is disabled'
              c.flag 'gateway-v4', arg_name: 'ipv4'

              c.desc 'IPv6 gateway to use when DHCP is disabled'
              c.flag 'gateway-v6', arg_name: 'ipv6'

              c.desc "MAC address"
              c.flag :hwaddr, arg_name: 'hwaddr'

              c.action &Command.run(NetInterface, :create_bridge)
            end

            create.desc 'Create a new routed veth interface'
            create.arg_name '<ctid> <ifname>'
            create.command :routed do |c|
              c.desc "MAC address"
              c.flag :hwaddr, arg_name: 'hwaddr'

              c.action &Command.run(NetInterface, :create_routed)
            end
          end

          net.desc "Remove network interface"
          net.arg_name '<ctid> <ifname>'
          net.command %i(del delete) do |c|
            c.action &Command.run(NetInterface, :delete)
          end

          net.desc "Rename network interface"
          net.arg_name '<ctid> <ifname> <new-ifname>'
          net.command :rename do |c|
            c.action &Command.run(NetInterface, :rename)
          end

          net.desc "Configure network interface"
          net.arg_name '<ctid> <ifname>'
          net.command :set do |c|
            c.desc 'What bridge should the interface be linked with'
            c.flag :link, arg_name: 'host_netif'

            c.desc 'Use DHCP client within the container'
            c.switch 'enable-dhcp', negatable: false

            c.desc 'Do not use DHCP client within the container'
            c.switch 'disable-dhcp', negatable: false

            c.desc 'IPv4 gateway to use when DHCP is disabled'
            c.flag 'gateway-v4', arg_name: 'ipv4'

            c.desc 'IPv6 gateway to use when DHCP is disabled'
            c.flag 'gateway-v6', arg_name: 'ipv6'

            c.desc "MAC address"
            c.flag :hwaddr, arg_name: 'hwaddr'

            c.action &Command.run(NetInterface, :set)
          end

          net.desc "Manage IP addresses"
          net.command :ip do |ip|
            ip.desc 'List IP addresses'
            ip.arg_name '[ctid] [ifname]'
            ip.command %i(ls list) do |c|
              c.desc 'Filter by IP version'
              c.flag %i(v version), type: Integer

              c.desc 'Select parameters to output'
              c.flag %i(o output), arg_name: 'parameters'

              c.desc 'Do not show header'
              c.switch %i(H hide-header), negatable: false

              c.desc 'List available parameters'
              c.switch %i(L list), negatable: false

              c.desc 'Sort by parameter(s)'
              c.flag %i(s sort), arg_name: 'parameters'

              c.action &Command.run(NetInterface, :ip_list)
            end

            ip.desc 'Add IP address'
            ip.arg_name '<ctid> <ifname> <addr>'
            ip.command :add do |c|
              c.desc 'Add route for addr'
              c.switch :route, default_value: true

              c.desc 'Add route for a different network than addr'
              c.flag 'route-as', arg_name: 'addr'

              c.action &Command.run(NetInterface, :ip_add)
            end

            ip.desc 'Remove IP address'
            ip.arg_name '<ctid> <ifname> <addr>'
            ip.command :del do |c|
              c.desc 'Remove route for addr'
              c.switch 'keep-route'

              c.desc 'IP versions to remove'
              c.flag %i(v version), type: Integer

              c.action &Command.run(NetInterface, :ip_del)
            end
          end

          net.desc "Manage routes"
          net.command :route do |ip|
            ip.desc 'List routes'
            ip.arg_name '[ctid] [ifname]'
            ip.command %i(ls list) do |c|
              c.desc 'Filter by IP version'
              c.flag %i(v version), type: Integer

              c.desc 'Select parameters to output'
              c.flag %i(o output), arg_name: 'parameters'

              c.desc 'Do not show header'
              c.switch %i(H hide-header), negatable: false

              c.desc 'List available parameters'
              c.switch %i(L list), negatable: false

              c.desc 'Sort by parameter(s)'
              c.flag %i(s sort), arg_name: 'parameters'

              c.action &Command.run(NetInterface, :route_list)
            end

            ip.desc 'Add route'
            ip.arg_name '<ctid> <ifname> <addr>'
            ip.command :add do |c|
              c.desc 'Route via specific address'
              c.flag :via, arg_name: 'hostaddr'

              c.action &Command.run(NetInterface, :route_add)
            end

            ip.desc 'Remove route'
            ip.arg_name '<ctid> <ifname> <addr>'
            ip.command :del do |c|
              c.desc 'IP versions to remove'
              c.flag %i(v version), type: Integer

              c.action &Command.run(NetInterface, :route_del)
            end
          end
        end

        cg_params(ct, Container, 'ctid')
        devices(ct, Container, 'ctid')

        ct.desc 'Manage resource limits'
        ct.command :prlimits do |pr|
          pr.desc 'List configured limits'
          pr.arg_name '<ctid> [limits...]'
          pr.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Container, :prlimit_list)
          end

          pr.desc 'Configure limit'
          pr.arg_name '<ctid> <limit> (<soft_and_hard>| <soft> <hard>)'
          pr.command :set do |c|
            c.action &Command.run(Container, :prlimit_set)
          end

          pr.desc 'Remove configured limit'
          pr.arg_name '<ctid> <limit>'
          pr.command :unset do |c|
            c.action &Command.run(Container, :prlimit_unset)
          end
        end

        ct.desc 'Manage container datasets'
        ct.command :dataset do |ds|
          ds.desc 'List datasets'
          ds.arg_name '<ctid>'
          ds.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Container, :dataset_list)
          end

          ds.desc 'Create a new dataset'
          ds.arg_name '<ctid> <dataset> [mountpoint]'
          ds.command %i(new create) do |c|
            c.desc 'Enable/disable auto mount'
            c.switch :mount, default_value: true

            c.action &Command.run(Container, :dataset_create)
          end

          ds.desc 'Delete dataset'
          ds.arg_name '<ctid> <dataset>'
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
          m.arg_name '<ctid>'
          m.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.action &Command.run(Container, :mount_list)
          end

          m.desc 'Create a new mount'
          m.arg_name '<ctid>'
          m.command %i(new create) do |c|
            c.desc 'Filesystem'
            c.flag :fs, required: true

            c.desc 'Mountpoint'
            c.flag :mountpoint, required: true

            c.desc 'Type'
            c.flag :type, required: true

            c.desc 'Options'
            c.flag :opts, required: true

            c.desc 'Activate this mount when the container starts'
            c.switch :automount, default_value: true

            c.action &Command.run(Container, :mount_create)
          end

          m.desc 'Mount a dataset'
          m.arg_name '<ctid> <dataset> <mountpoint>'
          m.command :dataset do |c|
            c.desc 'Mount the dataset read-only'
            c.switch %i(ro read-only), negatable: false

            c.desc 'Mount the dataset read-write'
            c.switch %i(rw read-write), negatable: false

            c.desc 'Activate this mount when the container starts'
            c.switch :automount, default_value: true

            c.action &Command.run(Container, :mount_dataset)
          end

          m.desc 'Register manually created mounts'
          m.arg_name '<id> <mountpoint>'
          m.command %i(reg register) do |c|
            c.desc 'Filesystem'
            c.flag :fs

            c.desc 'Type'
            c.flag :type

            c.desc 'Options'
            c.flag :opts

            c.desc 'Skip container locking to prevent deadlocks'
            c.switch 'on-ct-start', negatable: false

            c.action &Command.run(Container, :mount_register)
          end

          m.desc 'Activate a mount'
          m.arg_name '<ctid> <mountpoint>'
          m.command :activate do |c|
            c.action &Command.run(Container, :mount_activate)
          end

          m.desc 'Deactivate a mount'
          m.arg_name '<ctid> <mountpoint>'
          m.command :deactivate do |c|
            c.action &Command.run(Container, :mount_deactivate)
          end

          m.desc 'Remove mount'
          m.arg_name '<ctid> <mountpoint>'
          m.command %i(del delete) do |c|
            c.action &Command.run(Container, :mount_delete)
          end
        end

        ct.desc 'Recover container from errors'
        ct.command :recover do |r|
          r.desc 'Kill all container processes'
          r.arg_name '<ctid> [signal]'
          r.command :kill do |c|
            c.action &Command.run(Container, :recover_kill)
          end

          r.desc 'Check current container state'
          r.arg_name '<ctid>'
          r.command :state do |c|
            c.action &Command.run(Container, :recover_state)

            c.desc 'Ignore the manipulation lock mechanism'
            c.switch %i(lock), default_value: true
          end

          r.desc 'Clean up leftover cgroups and network interfaces'
          r.arg_name '<ctid>'
          r.command :cleanup do |c|
            c.desc 'Force the cleanup even on an unstopped container'
            c.switch %i(f force), negatable: false

            c.desc 'Cleanup only cgroups'
            c.switch %i(cgroups), negatable: false

            c.desc 'Cleanup only network interfaces'
            c.switch %i(network-interfaces), negatable: false

            c.action &Command.run(Container, :recover_cleanup)
          end
        end
      end

      desc 'Key chain management for container sends'
      command :send do |m|
        m.desc 'Manage local node identity'
        m.command :key do |k|
          k.desc 'Generate a new public/private key pair'
          k.command :gen do |c|
            c.desc 'Key type'
            c.flag %i(t type), must_match: %w(rsa ecdsa ed25519)

            c.desc 'Key bit size'
            c.flag %i(b bits), type: Integer, arg_name: 'n'

            c.desc 'Overwrite existing key'
            c.switch %i(f force), negatable: false

            c.action &Command.run(Send, :key_gen)
          end

          k.desc 'Print path to public/private key'
          k.arg_name '[public | private]'
          k.command :path do |c|
            c.action &Command.run(Send, :key_path)
          end
        end
      end

      desc 'Key chain management for receiving containers'
      command :receive do |m|
        m.desc 'Manage keys authorized to send containers to this node'
        m.command 'authorized-keys' do |a|
          a.desc 'List authorized keys'
          a.command %i(ls list) do |c|
            c.action &Command.run(Receive, :authorized_keys_list)
          end

          a.desc 'Authorize a new key'
          a.command :add do |c|
            c.action &Command.run(Receive, :authorized_keys_add)
          end

          a.desc 'Remove authorized key by index'
          a.arg_name '<index>'
          a.command %i(del delete) do |c|
            c.action &Command.run(Receive, :authorized_keys_delete)
          end

          a.desc 'Replace authorized keys'
          a.command :set do |c|
            c.action &Command.run(Receive, :authorized_keys_set)
          end
        end
      end

      desc 'Manage image repositories'
      command %i(repo repository) do |r|
        r.desc 'List repositories'
        r.arg_name '[repository...]'
        r.command %i(ls list) do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(Repository, :list)
        end

        r.desc 'Show information about a repository'
        r.arg_name '<repository>'
        r.command :show do |c|
          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(Repository, :show)
        end

        r.desc 'Add a new repository'
        r.arg_name '<repository> <url>'
        r.command :add do |c|
          c.action &Command.run(Repository, :add)
        end

        r.desc 'Remove a repository'
        r.arg_name '<repository>'
        r.command :del do |c|
          c.action &Command.run(Repository, :delete)
        end

        r.desc 'Enable a repository'
        r.arg_name '<repository>'
        r.command :enable do |c|
          c.action &Command.run(Repository, :enable)
        end

        r.desc 'Disable a repository'
        r.arg_name '<repository>'
        r.command :disable do |c|
          c.action &Command.run(Repository, :disable)
        end

        r.desc 'Configure repository'
        r.command :set do |set|
          set.desc 'Change repository URL'
          set.arg_name '<repository> <url>'
          set.command :url do |c|
            c.action &Command.run(Repository, :set_url)
          end

          set_attr(set, Repository, 'repository')
        end

        r.desc 'Clear configuration options'
        r.command :unset do |unset|
          unset_attr(unset, Repository, 'repository')
        end

        r.desc 'List repository assets (datasets, files, directories)'
        r.arg_name '<repository>'
        assets(r, Repository)

        r.desc 'Browse repository images'
        r.command :images do |t|
          t.desc 'List available images'
          t.arg_name '<repository>'
          t.command %i(ls list) do |c|
            c.desc 'Select parameters to output'
            c.flag %i(o output), arg_name: 'parameters'

            c.desc 'Do not show header'
            c.switch %i(H hide-header), negatable: false

            c.desc 'List available parameters'
            c.switch %i(L list), negatable: false

            c.desc 'Sort by parameter(s)'
            c.flag %i(s sort)

            c.desc 'Filter by vendor'
            c.flag :vendor, arg_name: 'vendor'

            c.desc 'Filter by variant'
            c.flag :variant, arg_name: 'variant'

            c.desc 'Filter by architecture'
            c.flag :arch, arg_name: 'arch'

            c.desc 'Filter by distribution'
            c.flag :distribution, arg_name: 'distribution'

            c.desc 'Filter by distribution version'
            c.flag :version, arg_name: 'version'

            c.desc 'Filter by version tag'
            c.flag :tag, arg_name: 'tag'

            c.desc 'Filter locally cached images'
            c.switch :cached, negatable: false

            c.desc 'Filter locally uncached images'
            c.switch :uncached, negatable: false

            c.action &Command.run(Repository, :image_list)
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

      desc 'Check if osctld is running'
      arg_name '[wait]'
      command :ping do |c|
        c.action &Command.run(Self, :ping)
      end

      desc 'Configure the system after it was upgraded'
      command :activate do |c|
        c.desc 'Regenerate system files'
        c.switch :system, default_value: true

        c.desc 'Ensure all containers are tracked by LXCFS'
        c.switch :lxcfs, default_value: true

        c.action &Command.run(Self, :activate)
      end

      desc 'Export all pools and stop all containers'
      command :shutdown do |c|
        c.desc 'Do not ask for confirmation, shutdown immediately'
        c.switch %i(f force), negatable: false

        c.action &Command.run(Self, :shutdown)
      end

      command :debug do |dbg|
        dbg.command 'locks' do |locks|
          locks.command :ls do |c|
            c.switch %i(v verbose), negatable: false
            c.action &Command.run(Debug, :locks_ls)
          end

          locks.arg_name '<id>'
          locks.command :show do |c|
            c.action &Command.run(Debug, :locks_show)
          end
        end

        dbg.command 'threads' do |threads|
          threads.command :ls do |c|
            c.action &Command.run(Debug, :threads_ls)
          end
        end

        dbg.command 'ugids' do |ugids|
          ugids.arg_name '[all|taken|free]'
          ugids.command :ls do |c|
            c.action &Command.run(Debug, :ugids_ls)
          end
        end
      end

      command 'gen-completion' do |g|
        g.command :bash do |c|
          c.action &Command.run(GenCompletion, :bash)
        end
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

    def cg_params(cmd, handler, arg_name)
      cmd.desc 'Manage CGroup parameters'
      cmd.command :cgparams do |p|
        p.desc 'List configured parameters'
        p.arg_name "<#{arg_name}>"
        p.command %i(ls list) do |c|
          c.desc 'Filter by CGroup subsystem (comma separated)'
          c.flag %i(S subsystem), arg_name: 'cgroup_subsys'

          c.desc 'Show all parameters from parent groups up to <name>'
          c.switch %i(a all), negatable: false

          c.desc 'Select parameters to output'
          c.flag %i(o output), arg_name: 'parameters'

          c.desc 'Do not show header'
          c.switch %i(H hide-header), negatable: false

          c.desc 'List available parameters'
          c.switch %i(L list), negatable: false

          c.action &Command.run(handler, :cgparam_list)
        end

        p.desc 'Configure parameters'
        p.arg_name "<#{arg_name}> <parameter> <value...>"
        p.command :set do |c|
          c.desc 'Append new values, do not overwrite previous values'
          c.switch %i(a append), negatable: false

          c.action &Command.run(handler, :cgparam_set)
        end

        p.desc 'Remove configured parameter'
        p.arg_name "<#{arg_name}> <parameter>"
        p.command :unset do |c|
          c.action &Command.run(handler, :cgparam_unset)
        end

        p.desc 'Reapply configured parameters'
        p.arg_name "<#{arg_name}>"
        p.command :apply do |c|
          c.action &Command.run(handler, :cgparam_apply)
        end

        p.desc 'Replace configured parameters by a new set'
        p.arg_name "<#{arg_name}>"
        p.command :replace do |c|
          c.action &Command.run(handler, :cgparam_replace)
        end
      end
    end

    def set_limits(set, handler, arg_name)
      set.desc 'Set CPU limit'
      set.arg_name "<#{arg_name}> <limit>"
      set.command 'cpu-limit' do |c|
        c.desc 'Length of period for CFS bandwidth control, in microseconds'
        c.flag %i(p period), type: Integer, default_value: 100*1000, arg_name: 'msec'

        c.action &Command.run(handler, :set_cpu_limit)
      end

      set.desc 'Set memory/swap limits'
      set.arg_name "<#{arg_name}> <memory> [swap]"
      set.command :memory do |c|
        c.action &Command.run(handler, :set_memory)
      end
    end

    def unset_limits(unset, handler, arg_name)
      unset.desc 'Unset CPU limit'
      unset.arg_name "<#{arg_name}>"
      unset.command 'cpu-limit' do |c|
        c.action &Command.run(handler, :unset_cpu_limit)
      end

      unset.desc 'Unset memory/swap limits'
      unset.arg_name "<#{arg_name}>"
      unset.command :memory do |c|
        c.action &Command.run(handler, :unset_memory)
      end
    end

    def set_attr(set, handler, arg_name)
      set.desc 'Set user attribute'
      set.arg_name "<#{arg_name}> <attribute> <value>"
      set.command :attr do |c|
        c.action &Command.run(handler, :set_attr)
      end
    end

    def unset_attr(unset, handler, arg_name)
      unset.desc 'Unset user attribute'
      unset.arg_name "<#{arg_name}> <attribute>"
      unset.command :attr do |c|
        c.action &Command.run(handler, :unset_attr)
      end
    end

    def devices(cmd, handler, arg_name)
      cmd.desc 'Manage devices'
      cmd.command :devices do |dev|
        dev.desc 'List allowed devices'
        dev.arg_name "<#{arg_name}>"
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
        dev.arg_name "<#{arg_name}> block|char <major> <minor> <mode> [device]"
        dev.command :add do |c|
          c.desc 'Should subgroups and containers inherit the device?'
          c.switch %i(i inherit), default_value: true

          c.desc 'Grant access to the device to all parent groups'
          c.switch %i(p parents)

          c.action &Command.run(handler, :device_add)
        end

        dev.desc 'Revoke access to device'
        dev.arg_name "<#{arg_name}> block|char <major> <minor>"
        dev.command %i(del delete) do |c|
          c.desc 'Remove device from all child groups and containers'
          c.switch %i(r recursive), negatable: false

          c.action &Command.run(handler, :device_delete)
        end

        dev.desc 'Change device access mode'
        dev.arg_name "<#{arg_name}> block|char <major> <minor> <mode>|-"
        dev.command :chmod do |c|
          c.desc "Extend the parents' device access if necessary"
          c.switch %i(p parents)

          c.desc 'Change device access mode in all child groups and containers that use it'
          c.switch %i(r recursive), negatable: false

          c.action &Command.run(handler, :device_chmod)
        end

        dev.desc 'Promote an inherited device, declaring an explicit requirement'
        dev.arg_name "<#{arg_name}> block|char <major> <minor>"
        dev.command :promote do |c|
          c.action &Command.run(handler, :device_promote)
        end

        dev.desc 'Inherit a promoted device'
        dev.arg_name "<#{arg_name}> block|char <major> <minor>"
        dev.command :inherit do |c|
          c.action &Command.run(handler, :device_inherit)
        end

        dev.desc 'Set inheritance'
        dev.command :set do |set|
          set.desc 'Let child groups and containers inherit specified device'
          set.arg_name "<#{arg_name}> block|char <major> <minor>"
          set.command :inherit do |c|
            c.action &Command.run(handler, :device_set_inherit)
          end
        end

        dev.desc 'Unset inheritance'
        dev.command :unset do |unset|
          unset.desc 'Prevent child groups and containers from inheriting specified device'
          unset.arg_name "<#{arg_name}> block|char <major> <minor>"
          unset.command :inherit do |c|
            c.action &Command.run(handler, :device_unset_inherit)
          end
        end

        dev.desc 'Replace configured devices by a new set'
        dev.arg_name "<#{arg_name}>"
        dev.command :replace do |c|
          c.action &Command.run(handler, :device_replace)
        end
      end
    end
  end
end
