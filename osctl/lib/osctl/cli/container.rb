require 'ipaddress'
require 'tempfile'

module OsCtl::Cli
  class Container < Command
    include CGroupParams

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
      hostname
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

    MOUNT_FIELDS = %i(
      fs
      mountpoint
      type
      opts
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

      OutputFormatter.print(cts, cols, fmt_opts)
    end

    def show
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      raise "missing argument" unless args[0]

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      c = osctld_open
      ct = c.cmd_data!(:ct_show, id: args[0], pool: gopts[:pool])

      cg_add_stats(c, ct, ct[:group_path], cols, gopts[:parsable])
      c.close

      OutputFormatter.print(ct, cols)
    end

    def create
      raise "missing argument" unless args[0]

      cmd_opts = {
        id: args[0],
        pool: opts[:pool] || gopts[:pool],
        user: opts[:user],
        template: File.absolute_path(opts[:template]),
      }

      cmd_opts[:group] = opts[:group] if opts[:group]

      osctld_fmt(:ct_create, cmd_opts)
    end

    def delete
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_delete, id: args[0], pool: gopts[:pool])
    end

    def start
      raise "missing argument" unless args[0]
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      return osctld_fmt(:ct_start, cmd_opts) unless opts[:foreground]

      open_console(args[0], gopts[:pool], 0) do |sock|
        sock.close if osctld_resp(:ct_start, cmd_opts).error?
      end
    end

    def stop
      raise "missing argument" unless args[0]
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      return osctld_fmt(:ct_stop, cmd_opts) unless opts[:foreground]

      open_console(args[0], gopts[:pool], 0) do |sock|
        sock.close if osctld_resp(:ct_stop, cmd_opts).error?
      end
    end

    def restart
      raise "missing argument" unless args[0]
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      return osctld_fmt(:ct_restart, cmd_opts) unless opts[:foreground]

      open_console(args[0], gopts[:pool], 0) do |sock|
        sock.close if osctld_resp(:ct_restart, cmd_opts).error?
      end
    end

    def console
      raise "missing argument" unless args[0]

      open_console(args[0], gopts[:pool], opts[:tty])
    end

    def attach
      raise "missing argument" unless args[0]

      cmd = osctld_call(:ct_attach, id: args[0], pool: gopts[:pool])

      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*cmd[:cmd])
      end

      Process.wait(pid)
    end

    def exec
      raise "missing argument" unless args[0]
      raise "missing command to execute" if args.count < 2

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
      raise "missing argument" unless args[0]

      cmd = osctld_call(:ct_su, id: args[0], pool: gopts[:pool])
      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*cmd[:cmd])
      end

      Process.wait(pid)
    end

    def set_hostname
      set(:hostname) do |args|
        args[0] || (fail 'expected hostname')
      end
    end

    def unset_hostname
      unset(:hostname)
    end

    def set_nesting
      set(:nesting) do |args|
        case args[0]
        when 'enabled'
          true
        when 'disabled'
          false
        else
          fail 'expected enabled/disabled'
        end
      end
    end

    def cd
      raise "missing argument" unless args[0]

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
      raise "missing argument" unless args[0]

      ct = osctld_call(:ct_show, id: args[0], pool: gopts[:pool])

      File.open(ct[:log_file]) do |f|
        puts f.readline until f.eof?
      end
    end

    def log_path
      raise "missing argument" unless args[0]

      ct = osctld_call(:ct_show, id: args[0], pool: gopts[:pool])
      puts ct[:log_file]
    end

    def assets
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_assets, id: args[0], pool: gopts[:pool])
    end

    def open_console(ctid, pool, tty)
      c = osctld_open
      c.cmd_response!(:ct_console, id: ctid, pool: pool, tty: tty)

      puts "Press Ctrl+a q to detach the console"
      puts

      state = `stty -g`
      `stty raw -echo -icanon -isig`

      pid = Process.fork do
        OsCtl::Console.open(c.socket, STDIN, STDOUT)
      end

      yield(c) if block_given?

      Process.wait(pid)

      `stty #{state}`
      puts
    end

    def cgparam_list
      raise "missing argument" unless args[0]

      do_cgparam_list(:ct_cgparam_list, id: args[0], pool: gopts[:pool])
    end

    def cgparam_set
      raise "missing container name" unless args[0]
      raise "missing parameter name" unless args[1]
      raise "missing parameter value" unless args[2]

      do_cgparam_set(:ct_cgparam_set, id: args[0], pool: gopts[:pool])
    end

    def cgparam_unset
      raise "missing container name" unless args[0]
      raise "missing parameter name" unless args[1]

      do_cgparam_unset(:ct_cgparam_unset, id: args[0], pool: gopts[:pool])
    end

    def cgparam_apply
      raise "missing container name" unless args[0]

      do_cgparam_apply(:ct_cgparam_apply, id: args[0], pool: gopts[:pool])
    end

    def prlimit_list
      raise "missing argument" unless args[0]

      if opts[:list]
        puts PRLIMIT_FIELDS.join("\n")
        return
      end

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
      raise "missing container name" unless args[0]
      raise "missing limit name" unless args[1]
      raise "missing limit value" unless args[2]

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
      raise "missing container name" unless args[0]
      raise "missing limit name" unless args[1]

      do_cgparam_unset(
        :ct_prlimit_unset,
        id: args[0],
        pool: gopts[:pool],
        name: args[1]
      )
    end

    def mount_list
      raise "missing container id" unless args[0]

      if opts[:list]
        puts MOUNT_FIELDS.join("\n")
        return
      end

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
      raise "missing container id" unless args[0]

      osctld_fmt(
        :ct_mount_create,
        id: args[0],
        pool: gopts[:pool],
        fs: opts[:fs],
        mountpoint: opts[:mountpoint],
        type: opts[:type],
        opts: opts[:opts],
      )
    end

    def mount_delete
      raise "missing container id" unless args[0]
      raise "missing mountpoint" unless args[1]

      osctld_fmt(
        :ct_mount_delete,
        id: args[0],
        pool: gopts[:pool],
        mountpoint: args[1]
      )
    end

    protected
    def set(option)
      raise "missing argument" unless args[0]
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      cmd_opts[option] = yield(args[1..-1])

      osctld_fmt(:ct_set, cmd_opts)
    end

    def unset(option)
      raise "missing argument" unless args[0]
      cmd_opts = {id: args[0], pool: gopts[:pool]}
      cmd_opts[option] = block_given? ? yield(args[1..-1]) : true

      osctld_fmt(:ct_unset, cmd_opts)
    end
  end
end
