require 'base64'
require 'shellwords'
require 'socket'
require 'timeout'

module OsVm
  class Shell
    # @return [Machine]
    attr_reader :machine

    # @return [Integer]
    attr_reader :index

    # @return [String, nil]
    attr_reader :name

    # @return [String]
    attr_reader :socket_path

    # @param machine [Machine]
    # @param index [Integer]
    # @param name [String, nil]
    # @param socket_path [String]
    # @param log_path [String]
    # @param default_timeout [Integer]
    def initialize(machine, index, socket_path, log_path, default_timeout:, name: nil)
      @machine = machine
      @index = index
      @name = name
      @socket_path = socket_path
      @default_timeout = default_timeout
      @log = ShellLog.new(log_path, shell_index: index, shell_name: name)
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
      # Do not let an asynchronous startup deadline split UNIXServer creation
      # from recording the descriptor which rollback has to close.
      Thread.handle_interrupt(TimeoutError => :never) do
        @server = UNIXServer.new(socket_path)
      end
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
    def wait(timeout: @default_timeout, deadline: nil, timeout_message: nil)
      raise "machine #{machine.name} is not running" unless machine.running?
      return if up?

      timeout_message ||= 'Timeout occurred while waiting for shell'
      deadline = effective_deadline(timeout, deadline)

      with_deadline(deadline, timeout_message) do
        buffer = ''

        loop do
          remaining = remaining_time!(deadline, timeout_message)

          reset if io&.closed?
          if io.nil?
            accept(
              timeout: remaining,
              deadline:,
              timeout_message:
            )
          end

          remaining = remaining_time!(deadline, timeout_message)
          rs = io.wait_readable([1, remaining].min)
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
    end

    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>] exit status and output
    def execute(cmd, timeout: @default_timeout, deadline: nil, timeout_message: nil)
      timeout_message ||= "Timeout occurred while running command '#{cmd}'"
      deadline = effective_deadline(timeout, deadline)

      with_deadline(deadline, timeout_message) do
        unless machine.running?
          machine.start(deadline:, timeout_message:)
        end

        wait(
          timeout: remaining_time!(deadline, timeout_message),
          deadline:,
          timeout_message:
        )

        mutex.synchronize do
          wait(
            timeout: remaining_time!(deadline, timeout_message),
            deadline:,
            timeout_message:
          )
          execute_command(
            cmd,
            timeout: remaining_time!(deadline, timeout_message),
            deadline:,
            timeout_message:
          )
        end
      end
    end

    # Execute command and check that it succeeds
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def succeeds(cmd, timeout: @default_timeout)
      status, output = execute(cmd, timeout:)

      if status != 0
        raise CommandFailed, "Command '#{cmd}' failed with status #{status}. Output:\n #{output}"
      end

      [status, output]
    end

    # Execute a command repeatedly until it succeeds or all attempts are used
    # @param cmd [String]
    # @param attempts [Integer]
    # @param retry_delay [Numeric]
    # @param timeout [Integer] timeout for each attempt
    # @return [Array<Integer, String>]
    def succeeds_with_retries(cmd, attempts:, retry_delay: 1, timeout: @default_timeout)
      expect_with_retries(cmd, attempts:, retry_delay:, timeout:, success: true)
    end

    # Execute command and check that it fails
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def fails(cmd, timeout: @default_timeout)
      status, output = execute(cmd, timeout:)

      if status == 0
        raise CommandSucceeded, "Command '#{cmd}' succeeds with status #{status}. Output:\n #{output}"
      end

      [status, output]
    end

    # Execute a command repeatedly until it fails or all attempts are used
    # @param cmd [String]
    # @param attempts [Integer]
    # @param retry_delay [Numeric]
    # @param timeout [Integer] timeout for each attempt
    # @return [Array<Integer, String>]
    def fails_with_retries(cmd, attempts:, retry_delay: 1, timeout: @default_timeout)
      expect_with_retries(cmd, attempts:, retry_delay:, timeout:, success: false)
    end

    # Execute all commands and check that they all succeed
    # @param cmds [String]
    # @return [Array<Array<[Integer, String]>>]
    def all_succeed(*cmds)
      cmds.map { |cmd| succeeds(cmd) }
    end

    # Execute all commands and check that they all fail
    # @param cmds [String]
    # @return [Array<Array<[Integer, String]>>]
    def all_fail(*cmds)
      cmds.map { |cmd| fails(cmd) }
    end

    # Wait until command succeeds
    # @return [Array<Integer, String>]
    def wait_until_succeeds(cmd, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        status, output = execute(cmd, timeout: cur_timeout)
        return [status, output] if status == 0

        cur_timeout = timeout - (Time.now - t1)
        raise TimeoutError, "Timeout occurred while running command '#{cmd}'" if cur_timeout <= 0

        sleep(1)
      end
    end

    # Wait until command fails
    # @return [Array<Integer, String>]
    def wait_until_fails(cmd, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        status, output = execute(cmd, timeout: cur_timeout)
        return [status, output] if status != 0

        cur_timeout = timeout - (Time.now - t1)
        raise TimeoutError, "Timeout occurred while running command '#{cmd}'" if cur_timeout <= 0

        sleep(1)
      end
    end

    protected

    attr_reader :server, :io, :log, :mutex

    def expect_with_retries(cmd, attempts:, retry_delay:, timeout:, success:)
      unless attempts.is_a?(Integer) && attempts > 0
        raise ArgumentError, 'attempts must be a positive integer'
      end

      status = output = nil

      attempts.times do |attempt|
        status, output = execute(cmd, timeout:)
        matches = success ? (status == 0) : (status != 0)
        return [status, output] if matches

        sleep(retry_delay) unless attempt + 1 == attempts
      end

      if success
        raise CommandFailed, "Command '#{cmd}' failed with status #{status}. Output:\n #{output}"
      end

      raise CommandSucceeded, "Command '#{cmd}' succeeds with status #{status}. Output:\n #{output}"
    end

    def accept(timeout: @default_timeout, deadline: nil, timeout_message: nil)
      raise "machine #{machine.name} is not running" unless machine.running?
      return io unless io.nil?

      timeout_message ||= 'Timeout occurred while waiting for shell connection'
      deadline = effective_deadline(timeout, deadline)

      with_deadline(deadline, timeout_message) do
        loop do
          remaining = remaining_time!(deadline, timeout_message)
          raise Error, 'Machine is not running' unless machine.running?

          rs = server.wait_readable([1, remaining].min)
          next unless rs

          begin
            @io = server.accept_nonblock
            return io
          rescue IO::WaitReadable, Errno::EINTR
            next
          end
        end
      end
    end

    def execute_command(cmd, timeout:, deadline: nil, timeout_message: nil)
      timeout_message ||= "Timeout occurred while running command '#{cmd}'"
      deadline = effective_deadline(timeout, deadline)
      remaining = remaining_time!(deadline, timeout_message)
      protocol_reserve = [1.0, remaining * 0.1].min
      guest_timeout = remaining - protocol_reserve
      vm_command = "set -euo pipefail; #{cmd}"
      timeout_command = "timeout #{format_timeout(guest_timeout)}"

      # For unknown reason, the first character written to the shell is cut. Sometimes
      # more characters are lost. We therefore prefix the executed command with whitespace
      # which can be lost.
      workaround = ' ' * 10
      log_started_at = log.execute_begin(cmd)
      protocol_started = true
      replies_consumed = false
      output = nil

      io.write("#{workaround}#{timeout_command} bash -c #{Shellwords.escape(vm_command)} 2>&1 | (base64 -w 0; echo)\n")

      begin
        raw_output = read_output(
          timeout: remaining_time!(deadline, timeout_message),
          deadline:,
          timeout_message:,
          command: vm_command
        )
      rescue MachineShellClosed
        log.execute_end(-1, '[machine shell closed]', log_started_at)
        raise
      end

      output = Base64.decode64(raw_output)

      io.write("#{workaround}echo ${PIPESTATUS[0]}\n")

      begin
        status = read_output(
          timeout: remaining_time!(deadline, timeout_message),
          deadline:,
          timeout_message:,
          command: 'echo ${PIPESTATUS[0]}'
        ).strip.to_i
        replies_consumed = true
      rescue MachineShellClosed
        log.execute_end(-1, output, log_started_at)
        raise
      end

      if status == 124
        log.execute_end(-1, output, log_started_at)
        raise TimeoutError, "#{timeout_message}, output: #{output.inspect}"
      end

      log.execute_end(status, output, log_started_at)
      [status, output]
    rescue TimeoutError => e
      # A command and its output/status replies form one stream protocol
      # transaction. Once any part of the command may have reached the guest,
      # a deadline before both replies are consumed leaves that stream
      # desynchronized. Close it and make the timeout unrecoverable so polling
      # callers cannot send a second command over ambiguous bytes.
      if protocol_started && !replies_consumed
        reset
        log.execute_end(-1, output || '[shell protocol timeout]', log_started_at) if log_started_at
        raise if e.is_a?(UnrecoverableTimeoutError)

        raise UnrecoverableTimeoutError, e.message
      end

      raise
    end

    def read_output(timeout:, command:, deadline: nil, timeout_message: nil)
      timeout_message ||= "Timeout occurred while running command '#{command}'"
      deadline = effective_deadline(timeout, deadline)
      buffer = ''

      loop do
        remaining = remaining_time!(
          deadline,
          "#{timeout_message}, buffer contents: #{buffer.inspect}",
          error_class: UnrecoverableTimeoutError
        )

        rs = io.wait_readable([1, remaining].min)
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

    def effective_deadline(timeout, outer_deadline)
      local_deadline = monotonic_now + timeout
      outer_deadline ? [local_deadline, outer_deadline].min : local_deadline
    end

    def remaining_time!(deadline, timeout_message, error_class: TimeoutError)
      remaining = deadline - monotonic_now
      raise error_class, timeout_message if remaining <= 0

      remaining
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def with_deadline(deadline, timeout_message, &)
      ::Timeout.timeout(
        remaining_time!(deadline, timeout_message),
        TimeoutError,
        timeout_message,
        &
      )
    end

    def format_timeout(timeout)
      format('%.9f', timeout).sub(/\.?0+\z/, '')
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
