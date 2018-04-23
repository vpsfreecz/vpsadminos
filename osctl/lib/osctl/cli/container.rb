require 'highline'
require 'io/console'
require 'ipaddress'
require 'tempfile'

module OsCtl::Cli
  class Container < Command
    include CGroupParams
    include Devices
    include Assets

    FIELDS = %i(
      pool
      id
      user
      group
      dataset
      rootfs
      lxc_path
      lxc_dir
      group_path
      distribution
      version
      state
      init_pid
      autostart
      autostart_priority
      autostart_delay
      hostname
      dns_resolvers
      nesting
    ) + CGroupParams::CGPARAM_STATS

    FILTERS = %i(
      pool
      user
      group
      distribution
      version
      state
    )

    DEFAULT_FIELDS = %i(
      pool
      id
      user
      group
      distribution
      version
      state
      init_pid
      memory
      cpu_time
    )

    PRLIMIT_FIELDS = %i(
      name
      soft
      hard
    )

    DATASET_FIELDS = %i(
      name
      dataset
    )

    MOUNT_FIELDS = %i(
      fs
      dataset
      mountpoint
      type
      opts
      automount
      temporary
    )

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {}
      fmt_opts = {layout: :columns}

      FILTERS.each do |v|
        [gopts, opts].each do |options|
          next unless options[v]
          cmd_opts[v] = options[v].split(',')
        end
      end

      cmd_opts[:ids] = args if args.count > 0
      fmt_opts[:header] = false if opts['hide-header']
      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : DEFAULT_FIELDS

      c = osctld_open
      cts = cg_add_stats(
        c,
        c.cmd_data!(:ct_list, cmd_opts),
        lambda { |ct| ct[:group_path] },
        cols,
        gopts[:parsable]
      )

      format_output(cts, cols, fmt_opts)
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
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      require_args!('id')

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      c = osctld_open
      ct = c.cmd_data!(:ct_show, id: args[0], pool: gopts[:pool])

      cg_add_stats(c, ct, ct[:group_path], cols, gopts[:parsable])
      c.close

      format_output(ct, cols)
    end

    def create
      require_args!('id')

      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        user: opts[:user],
        no_template: opts['no-template'],
        repository: opts[:repository],
      }

      %i(group dataset distribution version arch vendor variant).each do |v|
        cmd_opts[v] = opts[v] if opts[v]
      end

      if !opts[:template] && !opts['from-archive'] && !opts['from-archive'] \
         && !opts[:distribution]
        raise GLI::BadCommandLine,
              'provide either --template, --distribution or one of --from-archive, '+
              '--from-stream'

      elsif opts[:template] && (opts['from-archive'] || opts['from-archive'])
        raise GLI::BadCommandLine,
              'provide either --template or one of --from-archive, --from-stream'

      elsif opts['from-archive'] && opts['from-stream']
        raise GLI::BadCommandLine,
              'provide either --from-archive or --from-stream, not both'
      end

      if opts[:template] || (!opts[:template] && !opts['from-archive'] && !opts['from-stream'])
        cmd_opts[:template] = {
          type: :remote,
          template: repo_template_attrs,
        }

      elsif opts['from-archive']
        cmd_opts[:template] = {
          type: :archive,
          path: File.absolute_path(opts['from-archive'])
        }

      elsif opts['from-stream']
        stdin = opts['from-stream'] == '-'
        cmd_opts[:template] = {
          type: :stream,
          path: stdin ? nil : File.absolute_path(opts['from-stream'])
        }
      end

      if cmd_opts[:template][:type] != :stream || cmd_opts[:stream][:path]
        osctld_fmt(:ct_create, cmd_opts)
        return
      end

      updates = Proc.new { |msg| puts msg unless gopts[:quiet] }
      c = osctld_open
      ret = c.cmd_data!(:ct_create, cmd_opts, &updates)

      error!('invalid response, stdin stream not available') if ret != 'continue'

      r_in, w_in = IO.pipe
      c.send_io(r_in)
      r_in.close
      w_in.write(STDIN.read(16*1024)) until STDIN.eof?
      w_in.close

      c.response!(&updates)
    end

    def delete
      require_args!('id')

      osctld_fmt(:ct_delete, id: args[0], pool: gopts[:pool])
    end

    def reinstall
      require_args!('id')

      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        repository: opts[:repository],
        remove_snapshots: opts['remove-snapshots'],
      }

      %i(distribution version arch vendor variant).each do |v|
        cmd_opts[v] = opts[v] if opts[v]
      end

      if opts[:template] && (opts['from-archive'] || opts['from-archive'])
        raise GLI::BadCommandLine,
              'provide either --template or one of --from-archive, --from-stream'

      elsif opts['from-archive'] && opts['from-stream']
        raise GLI::BadCommandLine,
              'provide either --from-archive or --from-stream, not both'
      end

      if opts[:template] || (!opts['from-archive'] && !opts['from-stream'])
        cmd_opts[:template] = {
          type: :remote,
          template: repo_template_attrs(defaults: false),
        }

      elsif opts['from-archive']
        cmd_opts[:template] = {
          type: :archive,
          path: File.absolute_path(opts['from-archive'])
        }

      elsif opts['from-stream']
        stdin = opts['from-stream'] == '-'
        cmd_opts[:template] = {
          type: :stream,
          path: stdin ? nil : File.absolute_path(opts['from-stream'])
        }
      end

      if !cmd_opts[:template] \
         || cmd_opts[:template][:type] != :stream \
         || cmd_opts[:stream][:path]
        osctld_fmt(:ct_reinstall, cmd_opts)
        return
      end

      updates = Proc.new { |msg| puts msg unless gopts[:quiet] }
      c = osctld_open
      ret = c.cmd_data!(:ct_reinstall, cmd_opts, &updates)

      error!('invalid response, stdin stream not available') if ret != 'continue'

      r_in, w_in = IO.pipe
      c.send_io(r_in)
      r_in.close
      w_in.write(STDIN.read(16*1024)) until STDIN.eof?
      w_in.close
tt
      c.response!(&updates)
    end

    def start
      require_args!('id')
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      return osctld_fmt(:ct_start, cmd_opts) unless opts[:foreground]

      open_console(args[0], gopts[:pool], 0, gopts[:json]) do |sock|
        sock.close if osctld_resp(:ct_start, cmd_opts).error?
      end
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
      }

      return osctld_fmt(:ct_stop, cmd_opts) unless opts[:foreground]

      open_console(args[0], gopts[:pool], 0, gopts[:json]) do |sock|
        sock.close if osctld_resp(:ct_stop, cmd_opts).error?
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

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        reboot: opts[:reboot],
        stop_timeout: opts[:timeout],
        stop_method: m,
      }

      return osctld_fmt(:ct_restart, cmd_opts) unless opts[:foreground]

      open_console(args[0], gopts[:pool], 0, gopts[:json]) do |sock|
        sock.close if osctld_resp(:ct_restart, cmd_opts).error?
      end
    end

    def console
      require_args!('id')

      open_console(args[0], gopts[:pool], opts[:tty], gopts[:json])
    end

    def attach
      require_args!('id')

      shell = osctld_call(
        :ct_attach,
        id: args[0],
        pool: gopts[:pool],
        user_shell: opts['user-shell']
      )

      pid = Process.fork do
        shell[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*shell[:cmd])
      end

      Process.wait(pid)
    end

    def exec
      require_args!('id', 'command')

      c = osctld_open
      cont = c.cmd_data!(
        :ct_exec,
        id: args[0],
        pool: gopts[:pool],
        cmd: args[1..-1]
      )

      if cont != 'continue'
        warn "exec not available: invalid response '#{cont}'"
        exit(false)
      end

      r_in, w_in = IO.pipe
      r_out, w_out = IO.pipe
      r_err, w_err = IO.pipe

      c.send_io(r_in)
      c.send_io(w_out)
      c.send_io(w_err)

      r_in.close
      w_out.close
      w_err.close

      loop do
        rs, ws, = IO.select([STDIN, r_out, r_err, c.socket])

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
            data = r.read_nonblock(4096)
            w_in.write(data)

          when c.socket
            r_out.close
            r_err.close

            c.receive
            return
          end
        end
      end
    end

    def su
      require_args!('id')

      cmd = osctld_call(:ct_su, id: args[0], pool: gopts[:pool])
      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*cmd[:cmd])
      end

      Process.wait(pid)
    end

    def set_autostart
      set(:autostart) do
        {
          priority: opts[:priority],
          delay: opts[:delay],
        }
      end
    end

    def unset_autostart
      unset(:autostart)
    end

    def set_hostname
      set(:hostname) do |args|
        args[0] || (fail 'expected hostname')
      end
    end

    def unset_hostname
      unset(:hostname)
    end

    def set_dns_resolver
      set(:dns_resolvers) do |args|
        raise GLI::BadCommandLine, 'expected at least one address' if args.empty?
        args
      end
    end

    def unset_dns_resolver
      unset(:dns_resolvers)
    end

    def set_nesting
      set(:nesting) do |args|
        case args[0]
        when 'enabled'
          true
        when 'disabled'
          false
        else
          raise GLI::BadCommandLine, 'expected enabled/disabled'
        end
      end
    end

    def set_distribution
      set(:distribution) do |args|
        raise GLI::BadCommandLine, 'expected <distribution> <version>' if args.count != 2

        {
          name: args[0],
          version: args[1],
        }
      end
    end

    def set_cpu_limit
      require_args!('id', 'limit')
      do_set_cpu_limit(:ct_cgparam_set, id: args[0], pool: gopts[:pool])
    end

    def unset_cpu_limit
      require_args!('id')
      do_unset_cpu_limit(:ct_cgparam_unset, id: args[0], pool: gopts[:pool])
    end

    def set_memory
      require_args!('id', 'memory')
      do_set_memory(
        :ct_cgparam_set,
        :ct_cgparam_unset,
        id: args[0],
        pool: gopts[:pool]
      )
    end

    def unset_memory
      require_args!('id')
      do_unset_memory(:ct_cgparam_unset, id: args[0], pool: gopts[:pool])
    end

    def chown
      require_args!('id', 'user')
      osctld_fmt(:ct_chown, id: args[0], pool: gopts[:pool], user: args[1])
    end

    def chgrp
      require_args!('id', 'group')
      osctld_fmt(
        :ct_chgrp,
        id: args[0],
        pool: gopts[:pool],
        group: args[1],
        missing_devices: opts['missing-devices']
      )
    end

    def passwd
      require_args!('id', 'user')

      if args[2]
        password = args[2]

      else
        cli = HighLine.new
        password = cli.ask('Password: ') { |q| q.echo = false }.strip
      end

      osctld_fmt(
        :ct_passwd,
        id: args[0],
        pool: gopts[:pool],
        user: args[1],
        password: password
      )
    end

    def export
      require_args!('id', 'file')

      osctld_fmt(
        :ct_export,
        id: args[0],
        pool: gopts[:pool],
        file: File.expand_path(args[1]),
        consistent: opts[:consistent],
        compression: opts[:compression]
      )
    end

    def import
      require_args!('file')

      file = File.expand_path(args[0])
      fail "#{file}: not found" unless File.exist?(file)

      cmd_opts = {file: file}

      %w(as-id as-user as-group dataset missing-devices).each do |v|
        cmd_opts[v.sub('-', '_').to_sym] = opts[v] if opts[v]
      end

      osctld_fmt(:ct_import, cmd_opts)
    end

    def cd
      require_args!('id')

      ct = osctld_call(:ct_show, id: args[0], pool: gopts[:pool])

      if opts[:runtime]
        raise "container not running" unless ct[:init_pid]
        path = File.join('/proc/', ct[:init_pid].to_s, 'root', '/')

      elsif opts[:lxc]
        path = ct[:lxc_dir]

      else
        path = ct[:rootfs]
      end

      file = Tempfile.new('osctl-rcfile')
      file.write(<<-END
        export PS1="(CT #{ct[:id]}) $PS1"
        cd "#{path}"
        END
      )
      file.close

      puts "Spawning a new shell, exit when done"
      pid = Process.spawn(ENV['SHELL'] || 'bash', '--rcfile', file.path)
      Process.wait(pid)

      file.unlink
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
      osctld_fmt(:ct_reconfigure, id: args[0], pool: gopts[:pool])
    end

    def pid
      require_args!('pid|-')

      finder = PidFinder.new(header: !opts['hide-header'])

      if args[0] == '-'
        finder.find(STDIN.readline.strip) until STDIN.eof?

      else
        args.each { |pid| finder.find(pid) }
      end
    end

    def assets
      require_args!('id')

      print_assets(:ct_assets, id: args[0], pool: gopts[:pool])
    end

    def open_console(ctid, pool, tty, raw, &block)
      if raw
        open_console_raw(ctid, pool, tty)

      else
        open_console_tty(ctid, pool, tty, &block)
      end
    end

    def open_console_tty(ctid, pool, tty)
      c = osctld_open
      c.cmd_response!(:ct_console, id: ctid, pool: pool, tty: tty)

      puts "Press Ctrl+a q to detach the console"
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
      c.cmd_response!(:ct_console, id: ctid, pool: pool, tty: tty)

      console = OsCtl::Console.new(c.socket, STDIN, STDOUT, raw: true)

      Signal.trap('TERM') do
        console.close
      end

      console.open
    end

    def cgparam_list
      require_args!('id')

      do_cgparam_list(:ct_cgparam_list, id: args[0], pool: gopts[:pool])
    end

    def cgparam_set
      require_args!('id', 'parameter', 'value')
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

    def device_list
      require_args!('id')
      do_device_list(:ct_device_list, id: args[0], pool: gopts[:pool])
    end

    def device_add
      require_args!('id', 'type', 'major', 'minor', 'mode')
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

    def prlimit_list
      if opts[:list]
        puts PRLIMIT_FIELDS.join("\n")
        return
      end

      require_args!('id')

      cmd_opts = {id: args[0], pool: gopts[:pool]}
      fmt_opts = {layout: :columns}

      cmd_opts[:limits] = args[1..-1] if args.count > 1
      fmt_opts[:header] = false if opts['hide-header']

      if opts[:output]
        cols = opts[:output].split(',').map(&:to_sym)

      else
        cols = PRLIMIT_FIELDS
      end

      osctld_fmt(:ct_prlimit_list, cmd_opts, cols, fmt_opts)
    end

    def prlimit_set
      require_args!('id', 'limit', 'value')

      soft, hard = args[2..3].map { |v| /^\d+$/ =~ v ? v.to_i : v }
      hard = soft if hard.nil?

      osctld_fmt(
        :ct_prlimit_set,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        soft: soft,
        hard: hard
      )
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
      if opts[:list]
        puts DATASET_FIELDS.join("\n")
        return
      end

      require_args!('id')
      props = args[1..-1]

      cmd_opts = {id: args[0], pool: gopts[:pool], properties: props}
      fmt_opts = {layout: :columns}

      fmt_opts[:header] = false if opts['hide-header']

      if opts[:output]
        cols = (opts[:output].split(',') + props).map(&:to_sym)

      else
        cols = nil
      end

      osctld_fmt(:ct_dataset_list, cmd_opts, cols, fmt_opts)
    end

    def dataset_create
      require_args!('id', 'name')
      osctld_fmt(
        :ct_dataset_create,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        mount: opts[:mount],
        mountpoint: args[2]
      )
    end

    def dataset_delete
      require_args!('id', 'name')
      osctld_fmt(
        :ct_dataset_delete,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        recursive: opts[:recursive],
        unmount: opts[:unmount]
      )
    end

    def mount_list
      if opts[:list]
        puts MOUNT_FIELDS.join("\n")
        return
      end

      require_args!('id')

      cmd_opts = {id: args[0], pool: gopts[:pool]}
      fmt_opts = {layout: :columns}

      fmt_opts[:header] = false if opts['hide-header']

      if opts[:output]
        cols = opts[:output].split(',').map(&:to_sym)

      else
        cols = MOUNT_FIELDS
      end

      osctld_fmt(:ct_mount_list, cmd_opts, cols, fmt_opts)
    end

    def mount_create
      require_args!('id')

      osctld_fmt(
        :ct_mount_create,
        id: args[0],
        pool: gopts[:pool],
        fs: opts[:fs],
        mountpoint: opts[:mountpoint],
        type: opts[:type],
        opts: opts[:opts],
        automount: opts[:automount],
      )
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

      osctld_fmt(
        :ct_mount_dataset,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        mountpoint: args[2],
        mode: mode,
        automount: opts[:automount],
      )
    end

    def mount_register
      require_args!('id', 'mountpoint')

      osctld_fmt(
        :ct_mount_register,
        id: args[0],
        pool: gopts[:pool],
        fs: opts[:fs],
        mountpoint: args[1],
        type: opts[:type],
        opts: opts[:opts],
        lock: !opts['on-ct-start'],
      )
    end

    def mount_activate
      require_args!('id', 'mountpoint')

      osctld_fmt(
        :ct_mount_activate,
        id: args[0],
        pool: gopts[:pool],
        mountpoint: args[1]
      )
    end

    def mount_deactivate
      require_args!('id', 'mountpoint')

      osctld_fmt(
        :ct_mount_deactivate,
        id: args[0],
        pool: gopts[:pool],
        mountpoint: args[1]
      )
    end

    def mount_delete
      require_args!('id', 'mountpoint')

      osctld_fmt(
        :ct_mount_delete,
        id: args[0],
        pool: gopts[:pool],
        mountpoint: args[1]
      )
    end

    protected
    def set(option)
      require_args!('id')
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      cmd_opts[option] = yield(args[1..-1])

      osctld_fmt(:ct_set, cmd_opts)
    end

    def unset(option)
      require_args!('id')
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      cmd_opts[option] = block_given? ? yield(args[1..-1]) : true

      osctld_fmt(:ct_unset, cmd_opts)
    end

    def repo_template_attrs(defaults: true)
      ret = {}

      if opts[:template]
        parts = opts[:template].split('-')

        if parts.count < 1
          raise GLI::BadCommandLine,
                'the template has to be described at least by <distribution>'
        end

        dist, ver, arch, vendor, variant = parts

        ret = {
          vendor: vendor,
          variant: variant,
          arch: arch,
          distribution: dist,
          version: ver,
        }
      end

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
  end
end
