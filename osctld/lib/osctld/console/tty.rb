require 'base64'
require 'json'
require 'libosctl'
require 'lxc'
require 'thread'
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
        pid = nil

        catch(:stop) do
          loop do
            clients, select_rs = watch_ios

            rs, = IO.select(select_rs)

            rs.each do |io|
              if clients.include?(io)
                data = client_read(io)
                next if data.nil? || tty_in_io.nil?

                tty_write(tty_in_io, data)

              elsif io == tty_out_io
                data = tty_read(tty_out_io)
                next if data.nil?

                clients.each do |c|
                  begin
                    c.write(data)
                    c.flush

                  rescue SystemCallError
                    remove_client(c)
                  end
                end

              elsif io == @wake_r
                reason = @wake_r.readline.strip
                throw(:stop) if reason == 'stop'
                next
              end
            end
          end
        end

        sync { @clients.each { |c| c.close } }

        # TODO: why is this happening?
        begin
          Process.wait(tty_pid) if tty_pid
        rescue Errno::ECHILD => e
          log(:warn, ct, "Error occurred when closing tty0: #{e.message}")
        end
      end
    end

    def open
      sync { @opened = true }

      log(:info, ct, "Opening TTY #{n}")

      in_r, in_w = IO.pipe
      out_r, out_w = IO.pipe

      pid = Process.fork do
        STDIN.reopen(in_r)
        STDOUT.reopen(out_w)
        STDERR.reopen(out_w)

        in_w.close
        out_r.close

        @wake_r.close
        @wake_w.close

        Process.setproctitle("osctld: #{ct.pool.name}:#{ct.id} tty#{n}")

        SwitchUser.switch_to(
          ct.user.sysusername,
          ct.user.ugid,
          ct.user.homedir,
          ct.cgroup_path
        )

        lxc_ct = LXC::Container.new(ct.id, ct.lxc_home)
        fd = lxc_ct.console_fd(n)
        rows, cols = fd.winsize

        buf = ''

        begin
          loop do
            rs, = IO.select([STDIN, fd])

            rs.each do |io|
              case io
              when STDIN
                buf << STDIN.read_nonblock(4096)

                while i = buf.index("\n")
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

                  buf = buf[i+1..-1]
                end

              when fd
                STDOUT.write(fd.read_nonblock(4096))
                STDOUT.flush
              end
            end
          end

        rescue IOError
          exit
        end
      end

      in_r.close
      out_w.close

      sync do
        self.tty_pid = pid
        self.tty_in_io = in_w
        self.tty_out_io = out_r
      end
    end

    def add_client(socket)
      log(:info, ct, "Connecting client to TTY #{n}")

      sync do
        @clients << socket

        if opened?
          wake
        elsif ct.state == :running
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
    attr_accessor :tty_pid, :tty_in_io, :tty_out_io

    def opened?
      @opened
    end

    def wake(reason = '')
      @wake_w.puts(reason.to_s)
    end

    def watch_ios
      clients = sync { @clients.clone }

      ret = clients + [@wake_r]
      ret << tty_out_io if tty_out_io
      [clients, ret]
    end

    def tty_read(io)
      io.read_nonblock(4096)

    rescue IOError
      log(:info, ct, "Closing TTY #{n}")

      sync do
        @opened = false
        self.tty_pid = nil
        self.tty_in_io = nil
        self.tty_out_io = nil
      end

      on_close
      nil
    end

    def tty_write(io, data)
      io.write(data)
      io.flush
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

    def on_close

    end

    def sync
      if @mutex.owned?
        yield
      else
        @mutex.synchronize { yield }
      end
    end
  end
end
