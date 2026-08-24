require 'base64'
require 'json'
require 'libosctl'
require 'lxc'
require 'io/console'

module OsCtld
  # Represents a container's tty.
  #
  # Each tty has its own thread that passes data between the tty and connected
  # clients. Clients can be connected even if the tty is not available, i.e.
  # the container can be stopped.
  class Console::TTY
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    attr_reader :ct, :n

    def initialize(ct, n)
      @ct = ct
      @n = n
      @mutex = Mutex.new
      @clients = []
      @wake_r, @wake_w = IO.pipe
      @opened = false
    end

    def start
      @thread = Thread.new do
        catch(:stop) do
          loop do
            clients, select_rs, selected_tty_in, selected_tty_out = watch_ios

            rs, = IO.select(select_rs)

            rs.each do |io|
              if clients.include?(io)
                data = client_read(io)
                next if data.nil? || selected_tty_in.nil?

                tty_write(selected_tty_in, data)

              elsif io == selected_tty_out
                data = tty_read(selected_tty_out)
                next if data.nil?

                clients.each do |c|
                  c.write(data)
                  c.flush
                rescue SystemCallError
                  remove_client(c)
                end

              elsif io == @wake_r
                reason = @wake_r.readline.strip
                throw(:stop) if reason == 'stop'
                next
              end
            end
          end
        end

        sync { @clients.each(&:close) }
      ensure
        pid, ios, run_id, process_id = sync do
          values = [
            tty_pid,
            [tty_in_io, tty_out_io],
            tty_run_id,
            tty_process_id
          ]
          @opened = false
          self.tty_pid = nil
          self.tty_in_io = nil
          self.tty_out_io = nil
          self.tty_run_conf = nil
          self.tty_run_id = nil
          self.tty_process_id = nil
          values
        end
        close_tty_ios(ios)
        wait_tty_pid(pid)
        finish_lifecycle_attachment(run_id, process_id)
      end
    end

    def open
      log(:info, ct, "Opening TTY #{n}")

      in_r, in_w = IO.pipe
      out_r, out_w = IO.pipe
      gate_r, gate_w = IO.pipe
      run_id = ct.lifecycle.active_run_id
      raise 'managed lifecycle run not found for TTY' unless run_id

      pid = Process.fork do
        gate_w.close
        $stdin.reopen(in_r)
        $stdout.reopen(out_w)
        $stderr.reopen(out_w)

        in_w.close
        out_r.close

        @wake_r.close
        @wake_w.close

        SwitchUser.close_fds(except: [
                               0, 1, 2,
                               in_r, out_w, gate_r
                             ])

        Process.setproctitle("osctld: #{ct.pool.name}:#{ct.id} tty#{n}")

        exit(false) unless gate_r.gets&.strip == 'ready'
        gate_r.close

        SwitchUser.switch_to(
          ct.user.sysusername,
          ct.user.ugid,
          ct.user.homedir,
          ct.entry_cgroup_path
        )

        lxc_ct = LXC::Container.new(ct.id, ct.lxc_home)
        fd = lxc_ct.console_fd(n)
        rows, cols = fd.winsize

        buf = ''

        begin
          loop do
            rs, = IO.select([$stdin, fd])

            rs.each do |io|
              case io
              when $stdin
                buf << $stdin.read_nonblock(4096)

                while (i = buf.index("\n"))
                  cmd = JSON.parse(buf[0..i], symbolize_names: true)

                  if cmd[:keys]
                    fd.write(Base64.strict_decode64(cmd[:keys]))
                    fd.flush
                  end

                  if cmd[:rows] && cmd[:cols]
                    new_rows = cmd[:rows].to_i
                    new_cols = cmd[:cols].to_i

                    if new_rows > 0 && new_cols > 0 \
                      && (new_rows != rows || new_cols != cols)
                      fd.winsize = [cmd[:rows], cmd[:cols]]
                    end
                  end

                  buf = buf[i + 1..]
                end

              when fd
                $stdout.write(fd.read_nonblock(4096))
                $stdout.flush
              end
            end
          end
        rescue IOError
          exit
        end
      end

      gate_r.close
      in_r.close
      out_w.close

      process_id = Daemon.get.with_lifecycle_admission do
        ct.lifecycle.register_attachment(run_id, pid:)
      end
      unless process_id
        gate_w.close
        wait_tty_pid(pid)
        pid = nil
        raise 'container stopped before TTY attachment'
      end

      CGroup.mkpath_all(
        ct.entry_cgroup_path.split('/'),
        chown: ct.user.ugid
      )
      gate_w.puts('ready')
      gate_w.close
      run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
        conf.run_id == run_id
      end
      sync do
        @opened = true
        self.tty_pid = pid
        self.tty_in_io = in_w
        self.tty_out_io = out_r
        self.tty_run_conf = run_conf
        self.tty_run_id = run_id
        self.tty_process_id = process_id
      end
    rescue StandardError
      gate_w&.close unless gate_w&.closed?
      close_tty_ios([in_w, out_r])
      wait_tty_pid(pid)
      finish_lifecycle_attachment(run_id, process_id) \
        if run_id && process_id
      raise
    end

    def add_client(socket)
      log(:info, ct, "Connecting client to TTY #{n}")

      sync do
        @clients << socket

        if opened?
          wake
        elsif ct.runtime_state == :running
          open
          wake
        end
      end
    end

    def close
      wake(:stop)
      @thread.join if @thread
    end

    protected

    attr_accessor :tty_pid, :tty_in_io, :tty_out_io, :tty_run_conf,
                  :tty_run_id, :tty_process_id

    def opened?
      @opened
    end

    def wake(reason = '')
      @wake_w.puts(reason.to_s)
    end

    def watch_ios
      clients, selected_tty_in, selected_tty_out =
        sync { [@clients.clone, tty_in_io, tty_out_io] }

      ret = clients + [@wake_r]
      ret << selected_tty_out if selected_tty_out
      [clients, ret, selected_tty_in, selected_tty_out]
    end

    def tty_read(io)
      io.read_nonblock(4096)
    rescue IOError, Errno::ECONNRESET => e
      log(:info, ct, "Closing TTY #{n} (#{e.class}: #{e.message})")

      closed_run_conf = nil
      closed_run_id = nil
      closed_process_id = nil
      closed_pid = nil
      closed_ios = []

      sync do
        next unless tty_out_io.equal?(io)

        @opened = false
        closed_pid = tty_pid
        closed_ios = [tty_in_io, tty_out_io]
        closed_run_conf = tty_run_conf
        closed_run_id = tty_run_id
        closed_process_id = tty_process_id
        self.tty_pid = nil
        self.tty_in_io = nil
        self.tty_out_io = nil
        self.tty_run_conf = nil
        self.tty_run_id = nil
        self.tty_process_id = nil
      end

      close_tty_ios(closed_ios)
      wait_tty_pid(closed_pid) if closed_process_id
      finish_lifecycle_attachment(closed_run_id, closed_process_id)
      on_close(closed_run_conf)
      nil
    end

    def tty_write(io, data)
      io.write(data)
      io.flush
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    end

    def client_read(io)
      io.read_nonblock(4096)
    rescue IOError, Errno::ECONNRESET
      remove_client(io)
      nil
    end

    def remove_client(io)
      log(:info, ct, "Disconnecting client from TTY #{n}")
      sync { @clients.delete(io) }
    end

    def on_close(_run_conf); end

    def finish_lifecycle_attachment(run_id, process_id)
      return unless run_id && process_id

      effect_id = ct.lifecycle.finish_process(run_id, process_id)
      return unless effect_id

      run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
        conf.run_id == run_id
      end
      if run_conf
        require 'osctld/container/lifecycle_finalizer'
        Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id)
      else
        ct.lifecycle.fail_cleanup(
          run_id,
          effect_id,
          'exact run configuration is missing'
        )
      end
    end

    def close_tty_ios(ios)
      ios.compact.uniq.each do |io|
        io.close
      rescue IOError
        nil
      end
    end

    def wait_tty_pid(pid)
      Process.wait(pid) if pid
    rescue Errno::ECHILD => e
      log(:warn, ct, "Error occurred when closing TTY #{n}: #{e.message}")
    end

    def sync(&)
      if @mutex.owned?
        yield
      else
        @mutex.synchronize(&)
      end
    end
  end
end
