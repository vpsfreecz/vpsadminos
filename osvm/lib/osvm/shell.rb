require 'base64'
require 'shellwords'
require 'socket'

module OsVm
  class Shell
    # @return [Machine]
    attr_reader :machine

    # @return [Integer]
    attr_reader :index

    # @return [String]
    attr_reader :socket_path

    # @param machine [Machine]
    # @param index [Integer]
    # @param socket_path [String]
    # @param log_path [String]
    # @param default_timeout [Integer]
    def initialize(machine, index, socket_path, log_path, default_timeout:)
      @machine = machine
      @index = index
      @socket_path = socket_path
      @default_timeout = default_timeout
      @log = ShellLog.new(log_path)
      @mutex = Mutex.new
      @up = false
      @server = nil
      @io = nil
    end

    def prepare
      File.unlink(socket_path)
    rescue Errno::ENOENT
      # ignore
    ensure
      @server = UNIXServer.new(socket_path)
    end

    def qemu_options
      [
        '-chardev', "socket,id=#{chardev_id},path=#{socket_path}",
        '-device', "virtconsole,chardev=#{chardev_id}"
      ]
    end

    def chardev_id
      index == 0 ? 'shell' : "shell#{index}"
    end

    def up?
      @up
    end

    def close
      begin
        server&.close
      rescue IOError
        # ignore
      ensure
        @server = nil
      end

      begin
        io&.close
      rescue IOError
        # ignore
      ensure
        @io = nil
      end

      @up = false
    end

    def cleanup
      File.unlink(socket_path)
    rescue Errno::ENOENT
      # ignore
    end

    def finalize
      log.close
    end

    # @param timeout [Integer]
    # @return [void]
    def wait(timeout: @default_timeout)
      raise "machine #{machine.name} is not running" unless machine.running?
      return if up?

      t1 = Time.now
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          raise TimeoutError, 'Timeout occurred while waiting for shell'
        end

        reset if io&.closed?
        accept(timeout: t1 + timeout - Time.now) if io.nil?

        rs = io.wait_readable(1)
        next unless rs

        begin
          buffer << read_nonblock(io)
        rescue EOFError
          reset
          buffer = ''
          next
        end

        next unless buffer.include?("test-shell-ready\n")

        @up = true
        machine.__send__(:mount_shared_dir_once)
        return
      end
    end

    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>] exit status and output
    def execute(cmd, timeout: @default_timeout)
      machine.start unless machine.running?
      wait

      mutex.synchronize do
        wait
        execute_command(cmd, timeout:)
      end
    end

    protected

    attr_reader :server, :io, :log, :mutex

    def accept(timeout: @default_timeout)
      raise "machine #{machine.name} is not running" unless machine.running?
      return io unless io.nil?

      t1 = Time.now

      loop do
        if t1 + timeout < Time.now
          raise TimeoutError, 'Timeout occurred while waiting for shell connection'
        elsif !machine.running?
          raise Error, 'Machine is not running'
        end

        rs = server.wait_readable(1)
        next unless rs

        begin
          @io = server.accept_nonblock
          return io
        rescue IO::WaitReadable, Errno::EINTR
          next
        end
      end
    end

    def execute_command(cmd, timeout:)
      real_timeout = [timeout, 5].max
      vm_command = "set -euo pipefail; #{cmd}"
      timeout_command = "timeout #{real_timeout}"

      # For unknown reason, the first character written to the shell is cut. Sometimes
      # more characters are lost. We therefore prefix the executed command with whitespace
      # which can be lost.
      workaround = ' ' * 10

      io.write("#{workaround}#{timeout_command} bash -c #{Shellwords.escape(vm_command)} 2>&1 | (base64 -w 0; echo)\n")
      log_started_at = log.execute_begin(cmd)

      begin
        raw_output = read_output(timeout: real_timeout + 5, command: vm_command)
      rescue MachineShellClosed
        log.execute_end(-1, '[machine shell closed]', log_started_at)
        raise
      end

      output = Base64.decode64(raw_output)

      io.write("#{workaround}echo ${PIPESTATUS[0]}\n")

      begin
        status = read_output(timeout: 60, command: 'echo ${PIPESTATUS[0]}').strip.to_i
      rescue MachineShellClosed
        log.execute_end(-1, output, log_started_at)
        raise
      end

      if timeout && status == 124
        log.execute_end(-1, output, log_started_at)
        raise TimeoutError, "Timeout occurred while running command '#{cmd}', " \
                            "output: #{output.inspect}"
      end

      log.execute_end(status, output, log_started_at)
      [status, output]
    end

    def read_output(timeout:, command:)
      t1 = Time.now
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          raise UnrecoverableTimeoutError, "Timeout occurred while running command '#{command}', " \
                                           "buffer contents: #{buffer.inspect}"
        end

        rs = io.wait_readable(1)
        next unless rs

        begin
          buffer << read_nonblock(io)
        rescue EOFError
          reset
          raise MachineShellClosed
        end

        break if buffer.end_with?("\n")
      end

      buffer
    end

    def reset
      @up = false

      return if io.nil?

      io.close unless io.closed?
    rescue IOError
      # ignore
    ensure
      @io = nil
    end

    def read_nonblock(io)
      io.read_nonblock(4096)
    rescue IO::WaitReadable
      ''
    end
  end
end
