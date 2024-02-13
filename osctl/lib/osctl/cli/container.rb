require 'highline'
require 'io/console'
require 'ipaddress'
require 'libosctl'
require 'tempfile'
require 'osctl/cli/command'
require 'osctl/cli/cgroup_params'
require 'osctl/cli/zfs_properties'
require 'osctl/cli/devices'
require 'osctl/cli/assets'

module OsCtl::Cli
  class Container < Command
    include CGroupParams
    include Devices
    include Assets
    include Attributes

    FIELDS = %i[
      pool
      id
      user
      group
      dataset
      rootfs
      boot_dataset
      boot_rootfs
      lxc_path
      lxc_dir
      group_path
      distribution
      version
      state
      init_pid
      cpu_package_inuse
      cpu_package_set
      cpu_limit
      memory_limit
      swap_limit
      autostart
      autostart_priority
      autostart_delay
      ephemeral
      hostname
      hostname_readout
      dns_resolvers
      nesting
      seccomp_profile
      init_cmd
      raw_lxc
      loadavg
    ] + CGroupParams::CGPARAM_STATS

    FILTERS = %i[
      pool
      user
      group
      distribution
      version
      state
    ]

    DEFAULT_FIELDS = %i[
      pool
      id
      user
      group
      distribution
      version
      state
      init_pid
      memory
      cpu_us
    ]

    PRLIMIT_FIELDS = %i[
      name
      soft
      hard
    ]

    DATASET_FIELDS = %i[
      name
      dataset
    ]

    MOUNT_FIELDS = %i[
      fs
      dataset
      mountpoint
      type
      opts
      automount
      temporary
    ]

    def list
      c = osctld_open
      cg_init_subsystems(c)

      cgparams = cg_list_raw_cgroup_params
      zfsprops = ZfsProperties.new
      keyring = KernelKeyring.new

      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: FIELDS + cgparams + zfsprops.list_property_names + keyring.list_param_names,
        default_params: DEFAULT_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      cmd_opts = {}
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && param_selector.parse_option(opts[:sort]),
        opts: {
          memory_limit: {
            align: 'right',
            display: proc do |v|
              if v.nil? || gopts[:parsable] || gopts[:json]
                v
              else
                humanize_data(v)
              end
            end
          },
          swap_limit: {
            align: 'right',
            display: proc do |v|
              if v.nil? || gopts[:parsable] || gopts[:json]
                v
              else
                humanize_data(v)
              end
            end
          }
        }
      }

      FILTERS.each do |v|
        [gopts, opts].each do |options|
          next unless options[v]

          cmd_opts[v] = options[v].split(',')
        end
      end

      if opts[:ephemeral]
        cmd_opts[:ephemeral] = true
      elsif opts[:persistent]
        cmd_opts[:ephemeral] = false
      end

      cmd_opts[:ids] = args if args.count > 0
      fmt_opts[:header] = false if opts['hide-header']

      cols = param_selector.parse_option(opts[:output])
      cols = zfsprops.validate_property_names(cols)

      fmt_opts[:cols] = cols

      if cols.include?(:hostname_readout)
        cmd_opts[:read_hostname] = true
      end

      cts = cg_add_stats(
        c.cmd_data!(:ct_list, **cmd_opts),
        ->(ct) { ct[:group_path] },
        cols,
        gopts[:parsable]
      )

      add_loadavgs(cts)

      cg_add_raw_cgroup_params(
        cts,
        ->(ct) { ct[:group_path] },
        cols & cgparams.map(&:to_sym)
      )

      zfsprops.add_container_values(cts, cols, precise: gopts[:parsable])
      keyring.add_container_values(cts, cols, precise: gopts[:parsable])

      format_output(cts, **fmt_opts)
    end

    def tree
      require_args!('pool')
      Tree.print(
        args[0],
        parsable: gopts[:parsable],
        color: gopts[:color],
        containers: true
      )
    end

    def show
      c = osctld_open
      cg_init_subsystems(c)

      cgparams = cg_list_raw_cgroup_params
      zfsprops = ZfsProperties.new
      keyring = KernelKeyring.new

      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: FIELDS + cgparams + zfsprops.list_property_names + keyring.list_param_names,
        default_params: DEFAULT_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('id')

      cols = param_selector.parse_option(opts[:output])
      cols = zfsprops.validate_property_names(cols)

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool]
      }

      if cols.include?(:hostname_readout)
        cmd_opts[:read_hostname] = true
      end

      ct = c.cmd_data!(:ct_show, **cmd_opts)

      cg_add_stats(ct, ct[:group_path], cols, gopts[:parsable])
      c.close

      add_loadavg(ct)

      cg_add_raw_cgroup_params(
        ct,
        ct[:group_path],
        cols & cgparams.map(&:to_sym)
      )

      zfsprops.add_container_values(ct, cols, precise: gopts[:parsable])
      keyring.add_container_values(ct, cols, precise: gopts[:parsable])

      format_output(ct, cols:, header: !opts['hide-header'], opts: {
        memory_limit: {
          align: 'right',
          display: proc do |v|
            if v.nil? || gopts[:parsable] || gopts[:json]
              v
            else
              humanize_data(v)
            end
          end
        },
        swap_limit: {
          align: 'right',
          display: proc do |v|
            if v.nil? || gopts[:parsable] || gopts[:json]
              v
            else
              humanize_data(v)
            end
          end
        }
      })
    end

    def create
      require_args!('id')

      if opts['skip-image']
        create_empty
      else
        create_with_remote_image
      end
    end

    def delete
      require_args!('id')

      osctld_fmt(:ct_delete, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        force: opts[:force]
      })
    end

    def reinstall
      require_args!('id')

      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        repository: opts[:repository],
        remove_snapshots: opts['remove-snapshots']
      }

      if opts['from-file']
        cmd_opts.update(
          type: :image,
          path: File.absolute_path(opts['from-file'])
        )
      else
        cmd_opts.update(
          type: :remote,
          image: repo_image_attrs(defaults: false)
        )
      end

      osctld_fmt(:ct_reinstall, cmd_opts:)
    end

    def mount
      require_args!('id')
      osctld_fmt(:ct_mount, cmd_opts: { id: args[0], pool: gopts[:pool] })
    end

    def start
      require_args!('id')

      if opts[:foreground] && opts[:attach]
        raise GLI::BadCommandLine, 'use either --foreground or --attach'
      end

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        wait: get_ct_wait(opts[:wait]),
        queue: opts[:queue],
        priority: opts[:priority],
        debug: opts[:debug]
      }

      if opts[:foreground]
        open_console(args[0], gopts[:pool], 0, gopts[:json]) do |sock|
          sock.close if osctld_resp(:ct_start, **cmd_opts).error?
        end

        return
      end

      osctld_fmt(:ct_start, cmd_opts:)

      return unless opts[:attach]

      puts 'Attaching'
      attach
    end

    def stop
      require_args!('id')

      if opts[:kill] && opts['dont-kill']
        raise GLI::BadCommandLine, '--kill and --dont-kill cannot be used together'

      elsif opts[:kill]
        m = :kill

      elsif opts['dont-kill']
        m = :shutdown_or_fail

      else
        m = :shutdown_or_kill
      end

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        timeout: opts[:timeout],
        method: m,
        message: opts[:message]
      }

      return osctld_fmt(:ct_stop, cmd_opts:) unless opts[:foreground]

      open_console(args[0], gopts[:pool], 0, gopts[:json]) do |sock|
        sock.close if osctld_resp(:ct_stop, **cmd_opts).error?
      end
    end

    def restart
      require_args!('id')

      if opts[:kill] && opts['dont-kill']
        raise GLI::BadCommandLine, '--kill and --dont-kill cannot be used together'

      elsif (opts[:kill] || opts['dont-kill']) && opts[:reboot]
        raise GLI::BadCommandLine, '--kill and --dont-kill cannot be used with --reboot'

      elsif opts[:kill]
        m = :kill

      elsif opts['dont-kill']
        m = :shutdown_or_fail

      else
        m = :shutdown_or_kill
      end

      if opts[:foreground] && opts[:attach]
        raise GLI::BadCommandLine, 'use either --foreground or --attach'
      end

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        wait: get_ct_wait(opts[:wait]),
        reboot: opts[:reboot],
        stop_timeout: opts[:timeout],
        stop_method: m,
        message: opts[:message]
      }

      if opts[:foreground]
        open_console(args[0], gopts[:pool], 0, gopts[:json]) do |sock|
          sock.close if osctld_resp(:ct_restart, **cmd_opts).error?
        end

        return
      end

      osctld_fmt(:ct_restart, cmd_opts:)

      return unless opts[:attach]

      puts 'Attaching'
      attach
    end

    def console
      require_args!('id')

      open_console(args[0], gopts[:pool], opts[:tty], gopts[:json])
    end

    def attach
      require_args!('id')

      cmd = osctld_call(
        :ct_attach,
        id: args[0],
        pool: gopts[:pool],
        user_shell: opts['user-shell']
      )

      handle_ct_attach(cmd)
    end

    def exec
      require_args!('id', 'command', strict: false)

      c = osctld_open
      cont = c.cmd_data!(
        :ct_exec,
        id: args[0],
        pool: gopts[:pool],
        cmd: args[1..-1],
        run: opts['run-container'],
        network: opts['network']
      )

      if cont != 'continue'
        warn "exec not available: invalid response '#{cont}'"
        exit(false)
      end

      handle_exec_io(c)
    end

    def runscript
      require_args!('id', 'script', strict: false)

      c = osctld_open
      cont = c.cmd_data!(
        :ct_runscript,
        id: args[0],
        pool: gopts[:pool],
        script: args[1] == '-' ? nil : File.realpath(args[1]),
        arguments: args[2..-1],
        run: opts['run-container'],
        network: opts['network']
      )

      if cont != 'continue'
        warn "runscript not available: invalid response '#{cont}'"
        exit(false)
      end

      handle_exec_io(c)
    end

    def wall
      msg = opts[:message] || STDIN.read

      osctld_fmt(
        :ct_wall,
        cmd_opts: {
          ids: args.empty? ? nil : args,
          message: msg,
          banner: !opts['hide-banner']
        }
      )
    end

    def su
      require_args!('id')

      cmd = osctld_call(:ct_su, id: args[0], pool: gopts[:pool])
      handle_ct_attach(cmd)
    end

    def set_autostart
      require_args!('id')

      set(:autostart) do
        {
          priority: opts[:priority],
          delay: opts[:delay]
        }
      end
    end

    def unset_autostart
      require_args!('id')
      unset(:autostart)
    end

    def set_ephemeral
      require_args!('id')
      set(:ephemeral) { true }
    end

    def unset_ephemeral
      require_args!('id')
      unset(:ephemeral)
    end

    def set_hostname
      require_args!('id', 'hostname')

      set(:hostname) do |args|
        args[0] || (raise 'expected hostname')
      end
    end

    def unset_hostname
      require_args!('id')
      unset(:hostname)
    end

    def set_dns_resolver
      set(:dns_resolvers) do |args|
        raise GLI::BadCommandLine, 'expected at least one address' if args.empty?

        args
      end
    end

    def unset_dns_resolver
      require_args!('id')
      unset(:dns_resolvers)
    end

    def set_nesting
      require_args!('id')

      set(:nesting) do |_args|
        true
      end
    end

    def unset_nesting
      require_args!('id')
      unset(:nesting)
    end

    def set_distribution
      set(:distribution) do |args|
        if args.count < 2 || args.count > 3
          raise GLI::BadCommandLine, 'expected <distribution> <version> [arch]'
        end

        {
          name: args[0],
          version: args[1],
          arch: args[2]
        }
      end
    end

    def set_image_config
      require_args!('id')

      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        repository: opts[:repository],
        image: repo_image_attrs(defaults: false)
      }

      if opts['from-file']
        cmd_opts.update(
          type: :image,
          path: File.absolute_path(opts['from-file'])
        )
      else
        cmd_opts.update(
          type: :remote
        )
      end

      osctld_fmt(:ct_set_image_config, cmd_opts:)
    end

    def set_cpu_package
      require_args!('id', 'cpu-package')

      set(:cpu_package) do |args|
        str = args[0]

        if %w[auto none].include?(str)
          str
        elsif /^\d+$/ =~ str
          pkg_id = str.to_i

          topology = OsCtl::Lib::CpuTopology.new

          unless topology.packages.has_key?(pkg_id)
            warn "Warning: CPU package #{pkg_id.inspect} does not exist on this system"
            warn "Available CPU packages: #{topology.packages.keys.join(', ')}"
          end

          pkg_id
        else
          raise GLI::BadCommandLine, 'CPU package must be a number or auto/none'
        end
      end
    end

    def unset_cpu_package
      require_args!('id')
      unset(:cpu_package)
    end

    def set_seccomp_profile
      require_args!('id', 'profile')

      set(:seccomp_profile) do |args|
        if args.count != 1
          raise GLI::BadCommandLine, 'expected <profile>'

        elsif !File.exist?(args[0])
          raise GLI::BadCommandLine, "file '#{args[0]}' does not exist"

        else
          File.absolute_path(args[0])
        end
      end
    end

    def unset_seccomp_profile
      require_args!('id')
      unset(:seccomp_profile)
    end

    def set_init_cmd
      set(:init_cmd) { |args| args }
    end

    def unset_init_cmd
      unset(:init_cmd)
    end

    def set_start_menu
      require_args!('id')

      set(:start_menu) do
        {
          timeout: opts[:timeout]
        }
      end
    end

    def unset_start_menu
      require_args!('id')
      unset(:start_menu)
    end

    def set_raw_lxc
      require_args!('id')
      set(:raw_lxc) { |_args| STDIN.read }
    end

    def unset_raw_lxc
      require_args!('id')
      unset(:raw_lxc)
    end

    def set_cpu_limit
      require_args!('id', 'limit')
      do_set_cpu_limit(:ct_cgparam_set, id: args[0], pool: gopts[:pool])
    end

    def unset_cpu_limit
      require_args!('id')
      do_unset_cpu_limit(:ct_cgparam_unset, id: args[0], pool: gopts[:pool])
    end

    def set_memory_limit
      require_args!('id', 'memory', optional: %w[swap])
      do_set_memory(
        :ct_cgparam_set,
        :ct_cgparam_unset,
        id: args[0],
        pool: gopts[:pool]
      )
    end

    def unset_memory_limit
      require_args!('id')
      do_unset_memory(:ct_cgparam_unset, id: args[0], pool: gopts[:pool])
    end

    def set_attr
      require_args!('id', 'attribute', 'value')
      do_set_attr(
        :ct_set,
        { id: args[0], pool: gopts[:pool] },
        args[1],
        args[2]
      )
    end

    def unset_attr
      require_args!('id', 'attribute')
      do_unset_attr(
        :ct_unset,
        { id: args[0], pool: gopts[:pool] },
        args[1]
      )
    end

    def copy
      require_args!('id', 'new-id')

      if args[1].include?(':')
        target_pool, target_id = args[1].split(':')
      else
        target_pool = opts[:pool]
        target_id = args[1]
      end

      cmd_opts = {
        pool: gopts[:pool],
        id: args[0],
        target_pool:,
        target_id:,
        consistent: opts[:consistent],
        network_interfaces: opts['network-interfaces']
      }

      cmd_opts[:target_user] = opts[:user] if opts[:user]
      cmd_opts[:target_group] = opts[:group] if opts[:group]
      cmd_opts[:target_dataset] = opts[:dataset] if opts[:dataset]

      osctld_fmt(:ct_copy, cmd_opts:)
    end

    def move
      require_args!('id', 'new-id')

      if args[1].include?(':')
        target_pool, target_id = args[1].split(':')
      else
        target_pool = opts[:pool]
        target_id = args[1]
      end

      cmd_opts = {
        pool: gopts[:pool],
        id: args[0],
        target_pool:,
        target_id:
      }

      cmd_opts[:target_user] = opts[:user] if opts[:user]
      cmd_opts[:target_group] = opts[:group] if opts[:group]
      cmd_opts[:target_dataset] = opts[:dataset] if opts[:dataset]

      osctld_fmt(:ct_move, cmd_opts:)
    end

    def chown
      require_args!('id', 'user')
      osctld_fmt(:ct_chown, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        user: args[1]
      })
    end

    def chgrp
      require_args!('id', 'group')
      osctld_fmt(:ct_chgrp, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        group: args[1],
        missing_devices: opts['missing-devices']
      })
    end

    def boot
      require_args!('id')

      if opts[:foreground] && opts[:attach]
        raise GLI::BadCommandLine, 'use either --foreground or --attach'
      end

      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        repository: opts[:repository],
        force: opts[:force],
        mount_root: opts['mount-root-dataset'],
        zfs_properties: Hash[opts['zfs-property'].map do |v|
          k, v = v.split('=')
          raise GLI::BadCommandLine, "invalid ZFS property '#{v}'" if v.nil?

          [k, v]
        end],
        wait: get_ct_wait(opts[:wait]),
        queue: opts[:queue],
        priority: opts[:priority],
        debug: opts[:debug]
      }

      if opts['from-file']
        cmd_opts.update(
          type: :image,
          path: File.absolute_path(opts['from-file'])
        )
      else
        cmd_opts.update(
          type: :remote,
          image: repo_image_attrs(defaults: false)
        )
      end

      if opts[:foreground]
        open_console(args[0], gopts[:pool], 0, gopts[:json]) do |sock|
          sock.close if osctld_resp(:ct_boot, **cmd_opts).error?
        end

        return
      end

      osctld_fmt(:ct_boot, cmd_opts:)

      return unless opts[:attach]

      puts 'Attaching'
      attach
    end

    def config_reload
      require_args!('id')
      osctld_fmt(:ct_cfg_reload, cmd_opts: {
        id: args[0],
        pool: gopts[:pool]
      })
    end

    def config_replace
      require_args!('id')
      osctld_fmt(:ct_cfg_replace, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        config: STDIN.read
      })
    end

    def passwd
      require_args!('id', 'user', optional: %w[password])

      if args[2]
        password = args[2]

      else
        cli = HighLine.new
        password = cli.ask('Password: ') { |q| q.echo = false }.strip
      end

      osctld_fmt(:ct_passwd, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        user: args[1],
        password:
      })
    end

    def export
      require_args!('id', 'file')

      osctld_fmt(:ct_export, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        file: File.expand_path(args[1]),
        consistent: opts[:consistent],
        compression: opts[:compression]
      })
    end

    def import
      require_args!('file')

      file = File.expand_path(args[0])
      raise "#{file}: not found" unless File.exist?(file)

      cmd_opts = { file: }

      %w[as-id as-user as-group dataset missing-devices].each do |v|
        cmd_opts[v.sub('-', '_').to_sym] = opts[v] if opts[v]
      end

      osctld_fmt(:ct_import, cmd_opts:)
    end

    def log_cat
      require_args!('id')

      ct = osctld_call(:ct_show, id: args[0], pool: gopts[:pool])

      File.open(ct[:log_file]) do |f|
        puts f.readline until f.eof?
      end
    end

    def log_path
      require_args!('id')

      ct = osctld_call(:ct_show, id: args[0], pool: gopts[:pool])
      puts ct[:log_file]
    end

    def reconfigure
      require_args!('id')
      osctld_fmt(:ct_reconfigure, cmd_opts: { id: args[0], pool: gopts[:pool] })
    end

    def freeze
      require_args!('id')
      osctld_fmt(:ct_freeze, cmd_opts: { id: args[0], pool: gopts[:pool] })
    end

    def unfreeze
      require_args!('id')
      osctld_fmt(:ct_unfreeze, cmd_opts: { id: args[0], pool: gopts[:pool] })
    end

    def bisect
      c = osctld_open
      cg_init_subsystems(c)

      cgparams = cg_list_raw_cgroup_params.map(&:to_sym)

      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: FIELDS + cgparams,
        default_params: DEFAULT_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      cmd_opts = {
        state: 'running'
      }

      FILTERS.each do |v|
        [gopts, opts].each do |options|
          next unless options[v]

          cmd_opts[v] = options[v].split(',')
        end
      end

      if opts[:ephemeral]
        cmd_opts[:ephemeral] = true
      elsif opts[:persistent]
        cmd_opts[:ephemeral] = false
      end

      cmd_opts[:ids] = args if args.count > 0

      cts = c.cmd_data!(:ct_list, **cmd_opts)

      if opts[:exclude]
        exclude_ctids = opts[:exclude].split(',').map do |v|
          if v.index(':')
            pool, id = v.split(':')
            [pool, id]
          else
            [nil, v]
          end
        end

        cts.reject! do |ct|
          exclude_ctids.detect do |ex_pool, ex_id|
            (ex_pool.nil? || ct[:pool] == ex_pool) && ct[:id] == ex_id
          end
        end
      end

      cols = param_selector.parse_option(opts[:output])

      cg_add_stats(
        cts,
        ->(ct) { ct[:group_path] },
        cols,
        gopts[:parsable]
      )

      add_loadavgs(cts)

      cg_add_raw_cgroup_params(
        cts,
        ->(ct) { ct[:group_path] },
        cols & cgparams
      )

      if opts[:sort]
        sort_cols = param_selector.parse_option(opts[:sort])

        sort_cols.each do |c|
          unless all_fields.include?(c)
            raise GLI::BadCommandLine, "unknown sort parameter '#{c}'"
          end
        end

        cts.sort! do |a, b|
          a_vals = sort_cols.map { |c| a[c] }
          b_vals = sort_cols.map { |c| b[c] }
          cmp = a_vals <=> b_vals
          next(cmp) if cmp

          next(-1) if [nil, false].detect { |v| a_vals.include?(v) }
          next(1) if [nil, false].detect { |v| b_vals.include?(v) }

          0
        end
      end

      bis = Bisect.new(
        cts,
        suspend_action: opts[:action].to_sym,
        cols:
      )
      bis.run
    end

    def pid
      require_args!('pid|-', strict: false)

      finder = PidFinder.new(header: !opts['hide-header'])

      if args[0] == '-'
        finder.find(STDIN.readline.strip.to_i) until STDIN.eof?

      else
        args.each { |pid| finder.find(pid.to_i) }
      end
    end

    def assets
      require_args!('id')

      print_assets(:ct_assets, id: args[0], pool: gopts[:pool])
    end

    def open_console(ctid, pool, tty, raw, &)
      if raw
        open_console_raw(ctid, pool, tty)

      else
        open_console_tty(ctid, pool, tty, &)
      end
    end

    def open_console_tty(ctid, pool, tty)
      c = osctld_open
      c.cmd_response!(:ct_console, id: ctid, pool:, tty:)

      puts 'Press Ctrl+a q to detach the console'
      puts

      state = `stty -g`
      `stty raw -echo -icanon -isig`

      pid = Process.fork do
        console = OsCtl::Console.new(c.socket, STDIN, STDOUT)

        Signal.trap('WINCH') do
          console.resize(*STDIN.winsize)
        end

        console.open
      end

      yield(c) if block_given?

      Process.wait(pid)

      `stty #{state}`
      puts
    end

    def open_console_raw(ctid, pool, tty)
      c = osctld_open
      c.cmd_response!(:ct_console, id: ctid, pool:, tty:)

      console = OsCtl::Console.new(c.socket, STDIN, STDOUT, raw: true)

      Signal.trap('TERM') do
        console.close
      end

      console.open
    end

    def cgparam_list
      require_args!('id', strict: false)

      do_cgparam_list(:ct_cgparam_list, id: args[0], pool: gopts[:pool])
    end

    def cgparam_set
      require_args!('id', 'parameter', 'value', strict: false)
      do_cgparam_set(:ct_cgparam_set, id: args[0], pool: gopts[:pool])
    end

    def cgparam_unset
      require_args!('id', 'parameter')
      do_cgparam_unset(:ct_cgparam_unset, id: args[0], pool: gopts[:pool])
    end

    def cgparam_apply
      require_args!('id')
      do_cgparam_apply(:ct_cgparam_apply, id: args[0], pool: gopts[:pool])
    end

    def cgparam_replace
      require_args!('name')
      do_cgparam_replace(:ct_cgparam_replace, id: args[0], pool: gopts[:pool])
    end

    def device_list
      require_args!('id')
      do_device_list(:ct_device_list, id: args[0], pool: gopts[:pool])
    end

    def device_add
      require_args!('id', 'type', 'major', 'minor', 'mode', optional: %w[device])
      do_device_add(:ct_device_add, id: args[0], pool: gopts[:pool])
    end

    def device_delete
      require_args!('id', 'type', 'major', 'minor')
      do_device_delete(:ct_device_delete, id: args[0], pool: gopts[:pool])
    end

    def device_chmod
      require_args!('id', 'type', 'major', 'minor', 'mode')
      do_device_chmod(:ct_device_chmod, id: args[0], pool: gopts[:pool])
    end

    def device_promote
      require_args!('id', 'type', 'major', 'minor')
      do_device_chmod(:ct_device_promote, id: args[0], pool: gopts[:pool])
    end

    def device_inherit
      require_args!('id', 'type', 'major', 'minor')
      do_device_inherit(:ct_device_inherit, id: args[0], pool: gopts[:pool])
    end

    def device_set_inherit
      require_args!('id', 'type', 'major', 'minor')
      do_device_set_inherit(:ct_device_set_inherit, id: args[0], pool: gopts[:pool])
    end

    def device_unset_inherit
      require_args!('id', 'type', 'major', 'minor')
      do_device_unset_inherit(:ct_device_unset_inherit, id: args[0], pool: gopts[:pool])
    end

    def device_replace
      require_args!('id')
      do_device_replace(:ct_device_replace, id: args[0], pool: gopts[:pool])
    end

    def prlimit_list
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: PRLIMIT_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('id', strict: false)

      cmd_opts = { id: args[0], pool: gopts[:pool] }
      fmt_opts = { layout: :columns }

      cmd_opts[:limits] = args[1..-1] if args.count > 1
      fmt_opts[:header] = false if opts['hide-header']

      fmt_opts[:cols] = param_selector.parse_option(opts[:output])

      data = osctld_call(:ct_prlimit_list, **cmd_opts)
      format_output(data.map { |k, v| v.merge(name: k) }, **fmt_opts)
    end

    def prlimit_set
      require_args!('id', 'limit', 'value', optional: %w[hard])

      soft, hard = args[2..3].map { |v| /^\d+$/ =~ v ? v.to_i : v }
      hard = soft if hard.nil?

      osctld_fmt(:ct_prlimit_set, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        soft:,
        hard:
      })
    end

    def prlimit_unset
      require_args!('id', 'limit')

      do_cgparam_unset(
        :ct_prlimit_unset,
        id: args[0],
        pool: gopts[:pool],
        name: args[1]
      )
    end

    def dataset_list
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: DATASET_FIELDS,
        default_params: DATASET_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('id', strict: false)
      props = args[1..-1]

      cmd_opts = { id: args[0], pool: gopts[:pool], properties: props }
      fmt_opts = { layout: :columns }

      fmt_opts[:header] = false if opts['hide-header']
      fmt_opts[:cols] = param_selector.parse_option(opts[:output])

      osctld_fmt(:ct_dataset_list, cmd_opts:, fmt_opts:)
    end

    def dataset_create
      require_args!('id', 'name', optional: %w[mountpoint])
      osctld_fmt(:ct_dataset_create, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        mount: opts[:mount],
        mountpoint: args[2]
      })
    end

    def dataset_delete
      require_args!('id', 'name')
      osctld_fmt(:ct_dataset_delete, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        recursive: opts[:recursive],
        unmount: opts[:unmount]
      })
    end

    def mount_list
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: MOUNT_FIELDS,
        default_params: MOUNT_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('id')

      cmd_opts = { id: args[0], pool: gopts[:pool] }
      fmt_opts = { layout: :columns }

      fmt_opts[:header] = false if opts['hide-header']
      fmt_opts[:cols] = param_selector.parse_option(opts[:output])

      osctld_fmt(:ct_mount_list, cmd_opts:, fmt_opts:)
    end

    def mount_create
      require_args!('id')

      osctld_fmt(:ct_mount_create, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        fs: opts[:fs],
        mountpoint: opts[:mountpoint],
        type: opts[:type],
        opts: opts[:opts],
        automount: opts[:automount]
      })
    end

    def mount_dataset
      require_args!('id', 'name', 'mountpoint')

      if opts[:ro] && opts[:rw]
        raise GLI::BadCommandLine, 'use either --ro or --rw, not both'

      elsif opts[:ro]
        mode = 'ro'

      elsif opts[:rw]
        mode = 'rw'

      else
        mode = 'rw'
      end

      osctld_fmt(:ct_mount_dataset, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        mountpoint: args[2],
        mode:,
        automount: opts[:automount]
      })
    end

    def mount_register
      require_args!('id', 'mountpoint')

      osctld_fmt(:ct_mount_register, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        fs: opts[:fs],
        mountpoint: args[1],
        type: opts[:type],
        opts: opts[:opts],
        lock: !opts['on-ct-start']
      })
    end

    def mount_activate
      require_args!('id', 'mountpoint')

      osctld_fmt(:ct_mount_activate, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        mountpoint: args[1]
      })
    end

    def mount_deactivate
      require_args!('id', 'mountpoint')

      osctld_fmt(:ct_mount_deactivate, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        mountpoint: args[1]
      })
    end

    def mount_delete
      require_args!('id', 'mountpoint')

      osctld_fmt(:ct_mount_delete, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        mountpoint: args[1]
      })
    end

    def recover_kill
      require_args!('id', optional: %w[signal])

      if args[0].index(':')
        pool, id = args[0].split(':')
      else
        pool = gopts[:pool]
        id = args[0]
      end

      if args[1]
        if args[1] =~ /^\d+$/
          signal = Signal.list.key(args[1].to_i)

          if signal.nil?
            raise GLI::BadCommandLine, "invalid signal '#{args[1]}'"
          end
        else
          name = args[1].upcase

          raise GLI::BadCommandLine, "invalid signal '#{args[1]}'" unless Signal.list.has_key?(name)

          signal = name

        end
      else
        signal = 'KILL'
      end

      pl = OsCtl::Lib::ProcessList.new do |p|
        ctid = p.ct_id

        next(false) if ctid.nil?

        if pool.nil?
          next(false) unless ctid[1] == id

          pool = ctid[0]

        end

        ctid[0] == pool && ctid[1] == id
      end

      if pl.empty?
        puts 'No processes found'
        return
      end

      out_cols, out_data = Ps::Columns.generate(
        pl,
        Ps::Columns::DEFAULT_ONE_CT,
        gopts[:parsable]
      )

      OsCtl::Lib::Cli::OutputFormatter.print(
        out_data,
        cols: out_cols,
        layout: :columns,
        header: true
      )

      puts
      STDOUT.write("Kill #{pl.length} processes with SIG#{signal}? [yes/NO]: ")
      STDOUT.flush

      if STDIN.readline.strip.downcase == 'yes'
        pl.each do |p|
          puts "kill -SIG#{signal} #{p.pid}"
          Process.kill(signal, p.pid)
        end
      else
        puts 'Aborted'
      end
    end

    def recover_state
      require_args!('id')

      osctld_fmt(:ct_recover_state, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        manipulation_lock: opts[:lock] ? nil : 'ignore'
      })
    end

    def recover_cleanup
      require_args!('id')

      cleanup = []
      cleanup << 'cgroups' if opts['cgroups']
      cleanup << 'netifs' if opts['network-interfaces']

      cleanup = 'all' if cleanup.empty?

      osctld_fmt(:ct_recover_cleanup, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        force: opts[:force],
        cleanup:
      })
    end

    protected

    def create_with_remote_image
      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        user: opts[:user],
        repository: opts[:repository]
      }

      %i[group dataset].each do |v|
        cmd_opts[v] = opts[v] if opts[v]
      end

      unless opts[:distribution]
        raise GLI::BadCommandLine, 'provide --distribution'
      end

      cmd_opts[:image] = repo_image_attrs

      osctld_fmt(:ct_create, cmd_opts:)
    end

    def create_empty
      if !opts[:distribution]
        raise GLI::BadCommandLine, 'provide --distribution'
      elsif !opts[:version]
        raise GLI::BadCommandLine, 'provide --version'
      elsif !opts[:arch]
        raise GLI::BadCommandLine, 'provide --arch'
      end

      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        user: opts[:user],
        distribution: opts[:distribution],
        version: opts[:version],
        arch: opts[:arch]
      }

      %i[group dataset].each do |v|
        cmd_opts[v] = opts[v] if opts[v]
      end

      osctld_fmt(:ct_create_empty, cmd_opts:)
    end

    def set(option)
      require_args!('id', strict: false)
      cmd_opts = { id: args[0], pool: gopts[:pool] }
      cmd_opts[option] = yield(args[1..-1])

      osctld_fmt(:ct_set, cmd_opts:)
    end

    def unset(option)
      require_args!('id', strict: false)
      cmd_opts = { id: args[0], pool: gopts[:pool] }
      cmd_opts[option] = block_given? ? yield(args[1..-1]) : true

      osctld_fmt(:ct_unset, cmd_opts:)
    end

    def repo_image_attrs(defaults: true)
      ret = {}

      if defaults
        ret[:vendor] ||= opts[:vendor] || 'default'
        ret[:variant] ||= opts[:variant] || 'default'
        ret[:arch] ||= opts[:arch] || `uname -m`.strip
        ret[:distribution] ||= opts[:distribution]
        ret[:version] ||= opts[:version] || 'stable'
      else
        ret[:vendor] ||= opts[:vendor]
        ret[:variant] ||= opts[:variant]
        ret[:arch] ||= opts[:arch]
        ret[:distribution] ||= opts[:distribution]
        ret[:version] ||= opts[:version]
      end

      ret
    end

    def add_loadavg(ct)
      if ct[:state] != 'running'
        ct[:loadavg] = nil
        return
      end

      begin
        lavgs = OsCtl::Lib::LoadAvgReader.read_for([ct])
      rescue SystemCallError => e
        warn "Unable to read container load averages: #{e.message} (#{e.class})"
        return
      end

      lavg = lavgs["#{ct[:pool]}:#{ct[:id]}"]
      ct[:loadavg] = lavg ? lavg.averages : nil
    end

    def add_loadavgs(cts)
      begin
        lavgs = OsCtl::Lib::LoadAvgReader.read_for(cts)
      rescue SystemCallError => e
        warn "Unable to read container load averages: #{e.message} (#{e.class})"
        return
      end

      cts.each do |ct|
        if ct[:state] != 'running'
          ct[:loadavg] = nil
          next
        end

        lavg = lavgs["#{ct[:pool]}:#{ct[:id]}"]
        ct[:loadavg] = lavg ? lavg.averages : nil
      end
    end

    def get_ct_wait(v)
      if v == 'infinity'
        return v
      elsif v.is_a?(::String) && /^\d+$/ !~ v
        raise GLI::BadCommandLine, 'invalid value for --wait'
      end

      v_i = v.to_i

      if v_i < 0
        raise GLI::BadCommandLine, 'invalid value for --wait'
      elsif v_i == 0
        false
      elsif opts[:foreground]
        false
      else
        v_i
      end
    end

    def handle_exec_io(c)
      r_in, w_in = IO.pipe
      r_out, w_out = IO.pipe
      r_err, w_err = IO.pipe

      c.send_io(r_in)
      c.send_io(w_out)
      c.send_io(w_err)

      r_in.close
      w_out.close
      w_err.close

      watch_ios = [STDIN, r_out, r_err, c.socket]

      loop do
        rs, ws, = IO.select(watch_ios)

        rs.each do |r|
          case r
          when r_out
            data = r.read_nonblock(4096)
            STDOUT.write(data)
            STDOUT.flush

          when r_err
            data = r.read_nonblock(4096)
            STDERR.write(data)
            STDERR.flush

          when STDIN
            begin
              data = r.read_nonblock(4096)
              w_in.write(data)
            rescue EOFError
              w_in.close
              watch_ios.delete(STDIN)
            end

          when c.socket
            r_out.close
            r_err.close

            handle_exec_response(c)
            return
          end
        end
      end
    rescue IOError
      handle_exec_response(c)
    end

    def handle_exec_response(c)
      resp = c.receive_resp

      if resp.error?
        raise(resp['message'] || 'exec failed')

      elsif resp[:exitstatus] && resp[:exitstatus] > 0
        raise GLI::CustomExit.new('executed command failed', resp[:exitstatus])
      end
    end

    def handle_ct_attach(cmd)
      f = Tempfile.create(['osctl-ct-attach-settings', '.json'], '/tmp')
      f.puts(cmd[:settings].to_json)
      f.close

      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(cmd[:cmd], f.path, '--', *cmd[:args])
      end

      Process.wait(pid)
    ensure
      begin
        f && File.unlink(f.path)
      rescue Errno::ENOENT
        # pass
      end
    end
  end
end
