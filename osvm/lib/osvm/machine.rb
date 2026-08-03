require 'digest'
require 'fileutils'
require 'timeout'

module OsVm
  class Machine
    SHELL_INDEX_KEY = :osvm_machine_shell_index
    KERNEL_FAILURE_PATTERN = Regexp.union(
      /BUG: unable to handle/,
      /BUG: kernel NULL pointer dereference/,
      /kernel BUG at/,
      /Oops:/,
      /general protection fault/,
      /Kernel panic - not syncing:/
    ).freeze

    # Owns all wait and signal operations for one QEMU child. A nonblocking
    # wait is always performed before pending signals are sent. If the child
    # exits between that wait and Process.kill, it remains this process's
    # unreaped zombie, so its PID cannot be reused for an unrelated process.
    class QemuReaper
      POLL_INTERVAL = 0.01

      def initialize(pid, &on_exit)
        @pid = pid
        @on_exit = on_exit
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @signals = []
        @reaped = false
        @started = false
        @start = Queue.new
        @thread = Thread.new do
          @start.pop
          run
        end
      end

      def start
        activate = @mutex.synchronize do
          next false if @started

          @started = true
          true
        end
        @start << true if activate
        self
      end

      # Request a signal from the sole child owner.
      # @return [Boolean] true when Process.kill was attempted, false when the
      #   child had already been reaped
      def signal(signal)
        start
        response = Queue.new
        queued = @mutex.synchronize do
          next false if @reaped

          @signals << [signal, response]
          @condition.signal
          true
        end
        return false unless queued

        result = response.pop
        raise result if result.is_a?(Exception)

        result
      end

      def join(timeout = nil)
        start
        @thread.join(timeout) && self
      end

      protected

      attr_reader :pid

      def run
        @on_exit.call(reap)
      ensure
        mark_reaped
      end

      def reap
        status = nil

        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            status = waited.last
            mark_reaped
            break
          end

          deliver_signals
          @mutex.synchronize do
            @condition.wait(@mutex, POLL_INTERVAL) if @signals.empty? && !@reaped
          end
        end

        status
      rescue Errno::ECHILD
        # No signal may be sent once ownership can no longer be proven.
        mark_reaped
        nil
      end

      def deliver_signals
        pending = @mutex.synchronize do
          next [] if @reaped

          @signals.shift(@signals.length)
        end

        pending.each do |signal, response|
          result = begin
            Process.kill(signal, pid)
            true
          rescue Errno::ESRCH
            false
          rescue StandardError => e
            e
          end
          response << result
        end
      end

      def mark_reaped
        pending = @mutex.synchronize do
          @reaped = true
          @signals.shift(@signals.length)
        end
        pending.each { |entry| entry.last << false }
      end
    end

    def self.with_shell(index)
      original_index = Thread.current[SHELL_INDEX_KEY]
      Thread.current[SHELL_INDEX_KEY] = index
      yield
    ensure
      Thread.current[SHELL_INDEX_KEY] = original_index
    end

    # @return [String]
    attr_reader :name

    # Kernel parameters passed to {#start}
    # @return [Array<String>]
    attr_reader :start_kernel_params

    # @param name [String]
    # @param config [MachineConfig]
    # @param tmpdir [String]
    # @param sockdir [String]
    # @param default_timeout [Integer]
    # @param hash_base [String]
    # @param interactive_console [Boolean]
    def initialize(name, config, tmpdir, sockdir, default_timeout: 900, hash_base: '', interactive_console: false)
      @name = name
      @config = config
      @tmpdir = tmpdir
      @sockdir = sockdir
      @default_timeout = default_timeout || 900
      @hash_base = hash_base
      @interactive_console = interactive_console
      @start_kernel_params = []
      @running = false
      @shared_dir = SharedDir.new(self)
      @shared_filesystems = {
        shared_dir.fs_name => shared_dir.host_path
      }.merge(config.shared_filesystems)
      @virtiofsd_pids = []
      @mutex = Mutex.new
      @start_mutex = Mutex.new
      @shared_dir_mutex = Mutex.new
      @shared_dir_mounted = false
      @kernel_failure = nil
      @kernel_failure_detected_at = nil
      @allowed_kernel_failure_patterns = []
      @console_output = ''
      @console_scan_buffer = ''

      FileUtils.mkdir_p(tmpdir)
      FileUtils.mkdir_p(sockdir)
      @log = MachineLog.new(File.join(tmpdir, "#{name}-log.log"))
      named_shells = {}
      worker_shell_count = config.test_shells - config.shell_names.length
      @shell_instances = Array.new(config.test_shells) do |i|
        shell_name = i >= worker_shell_count ? config.shell_names[i - worker_shell_count] : nil
        shell = Shell.new(self, i, shell_socket_path(i), shell_log_path(i), default_timeout:, name: shell_name)
        named_shells[shell_name] = shell if shell_name
        shell
      end
      @shell_collection = ShellCollection.new(self, named_shells)
    end

    def finalize
      log.close
      shell_instances.each(&:finalize)
    end

    # Start the machine
    # @param kernel_params [Array<String>]
    # @param wait_for_boot [Boolean]
    # @return [Machine]
    def start(kernel_params: [], wait_for_boot: false, deadline: nil, timeout_message: nil)
      timeout_message ||= "Timeout while starting machine #{name}"

      with_deadline(deadline, timeout_message) do
        @start_mutex.synchronize do
          if running?
            unless start_kernel_params == kernel_params
              raise 'Machine already started with different kernel parameters'
            end

            self.wait_for_boot(deadline:, timeout_message:) if wait_for_boot
            return self
          end

          qemu_write = nil
          started_qemu_pid = nil
          started_qemu_reaper = nil

          startup = proc do
            # virtiofsd cannot be relaunched right away, it needs some time settle
            # for unknown reasons, so we ensure there's a 5 second gap between stop
            # and start of this machine
            if @stopped_at
              diff = Time.now - @stopped_at
              delay = 5
              if diff <= delay
                sleep_with_deadline(
                  [delay - diff, delay].min,
                  deadline,
                  timeout_message
                )
              end
            end

            log.start
            prepare_disks

            shell_instances.each(&:prepare)

            shared_dir.setup
            @shared_dir_mounted = false
            start_virtiofs
            sleep_with_deadline(1, deadline, timeout_message)

            qemu_kwargs = {}

            unless @interactive_console
              # Rollback must always own both ends of a prepared pipe. Defer the
              # asynchronous deadline until the descriptors are recorded.
              Thread.handle_interrupt(TimeoutError => :never) do
                @qemu_read, qemu_write = IO.pipe
              end

              qemu_kwargs = {
                in: :close,
                out: qemu_write,
                err: qemu_write
              }
            end

            @start_kernel_params = kernel_params
            reset_kernel_failure

            # Keep QEMU creation, PID publication, pipe/console handoff and
            # reaper ownership indivisible with respect to the asynchronous
            # deadline. Publish running before starting the reaper: an
            # immediately exiting QEMU may otherwise clear the state before
            # this thread incorrectly republishes it as live.
            Thread.handle_interrupt(TimeoutError => :never) do
              started_qemu_pid = Process.spawn(
                *qemu_command(kernel_params:),
                **qemu_kwargs
              )
              @qemu_pid = started_qemu_pid
              started_qemu_reaper = run_qemu_reaper(started_qemu_pid)
              @qemu_reaper = started_qemu_reaper
              qemu_write&.close
              qemu_write = nil
              @running = true
              run_console_thread unless @interactive_console
              started_qemu_reaper&.start
            end

            self.wait_for_boot(deadline:, timeout_message:) if wait_for_boot
            self
          end

          # Mask asynchronous startup timeouts across the exception-to-rollback
          # handoff. The startup body explicitly enables them, while rollback
          # keeps every exact process, thread and descriptor under ownership
          # until cleanup and stopped-state publication are complete.
          Thread.handle_interrupt(TimeoutError => :never) do
            Thread.handle_interrupt(TimeoutError => :immediate, &startup)
          rescue StandardError
            rollback_start(
              qemu_pid: started_qemu_pid,
              qemu_reaper: started_qemu_reaper,
              qemu_write:
            )
            raise
          end
        end
      end
    end

    # Block until the machine stops
    def join(timeout: @default_timeout)
      reaper = qemu_reaper
      wait_for_reaper(reaper, timeout:) if reaper
      raise_if_kernel_failed!
      nil
    end

    # Stop the machine
    # @param timeout [Integer]
    # @return [Machine]
    def stop(timeout: @default_timeout)
      reaper = qemu_reaper
      return self unless reaper

      log.stop
      begin
        execute(poweroff_command)
      rescue MachineShellClosed
        # The shell logs the failed command.
      end

      if reaper && !wait_for_reaper(reaper, timeout:)
        raise UnrecoverableTimeoutError, "Timeout while stopping machine #{name}"
      end

      raise_if_kernel_failed!
      self
    end

    # Kill the machine
    # @param signal ['TERM', 'KILL']
    # @return [Machine]
    def kill(signal: 'TERM')
      reaper = qemu_reaper
      unless reaper && running?
        log.kill('NONE')
        return self
      end

      log.kill(signal)

      begin
        reaper.signal(signal)
      rescue Errno::ESRCH
        warn "Unable to kill machine #{name} using SIG#{signal}"
      end

      if signal == 'KILL'
        reaper.join
        return self
      elsif reaper.join(60)
        return self
      end

      log.kill('KILL')

      begin
        reaper.signal('KILL')
      rescue Errno::ESRCH
        warn "Unable to kill machine #{name} using SIGKILL"
      end

      reaper.join
      self
    end

    # Destroy the machine
    # @return [Machine]
    def destroy
      log.destroy
      shared_dir.destroy
      destroy_disks
      self
    end

    # Destroy file-backed disks
    #
    # Disks are destroyed automatically or when {#destroy} is called.
    # {#destroy_disks} can be used to reset storage between machine runs.
    #
    # @return [Machine]
    def destroy_disks
      config.disks.each do |disk|
        next if disk.type != 'file' || !disk.create

        FileUtils.rm_f(disk_path(disk.device))
      end

      self
    end

    # Cleanup machine state
    # @return [Machine]
    def cleanup
      shell_instances.each(&:cleanup)

      shared_filesystems.each_key do |fs_name|
        File.unlink(virtiofs_socket_path(fs_name))
      rescue Errno::ENOENT
        # ignore
      end

      self
    end

    # @return [Boolean]
    def running?
      @running
    end

    # @return [Boolean]
    def booted?
      current_shell.up?
    end

    # @return [Boolean]
    def can_execute?
      shell_instances.any?(&:up?)
    end

    # Wait until the system has booted
    # @param timeout [Integer]
    def wait_for_boot(timeout: @default_timeout, deadline: nil, timeout_message: nil)
      options = { timeout: }
      options[:deadline] = deadline if deadline
      options[:timeout_message] = timeout_message if timeout_message
      current_shell.wait(**options)
    end

    # Execute a command
    # @param cmd [String]
    # @param timeout [Integer]
    # @raise [MachineShellClosed]
    # @return [Array<Integer, String>] exit status and output
    def execute(cmd, timeout: @default_timeout, shell: nil, deadline: nil, timeout_message: nil)
      options = { timeout: }
      options[:deadline] = deadline if deadline
      options[:timeout_message] = timeout_message if timeout_message
      command_shell(shell).execute(cmd, **options)
    end

    # Execute command and check that it succeeds
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def succeeds(cmd, timeout: @default_timeout, shell: nil)
      command_shell(shell).succeeds(cmd, timeout:)
    end

    # Execute a command repeatedly until it succeeds or all attempts are used
    # @param cmd [String]
    # @param attempts [Integer]
    # @param retry_delay [Numeric]
    # @param timeout [Integer] timeout for each attempt
    # @return [Array<Integer, String>]
    def succeeds_with_retries(cmd, attempts:, retry_delay: 1, timeout: @default_timeout, shell: nil)
      command_shell(shell).succeeds_with_retries(cmd, attempts:, retry_delay:, timeout:)
    end

    # Execute command and check that it fails
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def fails(cmd, timeout: @default_timeout, shell: nil)
      command_shell(shell).fails(cmd, timeout:)
    end

    # Execute a command repeatedly until it fails or all attempts are used
    # @param cmd [String]
    # @param attempts [Integer]
    # @param retry_delay [Numeric]
    # @param timeout [Integer] timeout for each attempt
    # @return [Array<Integer, String>]
    def fails_with_retries(cmd, attempts:, retry_delay: 1, timeout: @default_timeout, shell: nil)
      command_shell(shell).fails_with_retries(cmd, attempts:, retry_delay:, timeout:)
    end

    # Execute all commands and check that they all succeed
    # @param cmds [String]
    # @return [Array<Array<[Integer, String]>>]
    def all_succeed(*cmds, shell: nil)
      command_shell(shell).all_succeed(*cmds)
    end

    # Execute all commands and check that they all fail
    # @param cmds [String]
    # @return [Array<Array<[Integer, String]>>]
    def all_fail(*cmds, shell: nil)
      command_shell(shell).all_fail(*cmds)
    end

    # Wait until command succeeds
    # @return [Array<Integer, String>]
    def wait_until_succeeds(cmd, timeout: @default_timeout, shell: nil)
      command_shell(shell).wait_until_succeeds(cmd, timeout:)
    end

    # Wait until command fails
    # @return [Array<Integer, String>]
    def wait_until_fails(cmd, timeout: @default_timeout, shell: nil)
      command_shell(shell).wait_until_fails(cmd, timeout:)
    end

    # Wait until network is operational, including DNS
    # @return [Machine]
    def wait_until_online(timeout: 20 * 60)
      timeout_message = 'Timeout occurred while waiting for network to become online'
      deadline = monotonic_deadline(timeout)

      remaining_time!(deadline, timeout_message)
      start(deadline:, timeout_message:) unless running?
      wait_for_boot(
        timeout: remaining_time!(deadline, timeout_message),
        deadline:,
        timeout_message:
      )

      loop do
        status, = execute(
          'curl --head --max-time 10 https://check-online.vpsadminos.org',
          timeout: remaining_time!(deadline, timeout_message),
          deadline:,
          timeout_message:
        )
        remaining_time!(deadline, timeout_message)

        return self if status == 0

        sleep_with_deadline(1, deadline, timeout_message)
      end
    end

    # Wait until the machine shuts down
    # @param timeout [Integer]
    # @return [Machine]
    def wait_for_shutdown(timeout: @default_timeout)
      t1 = Time.now

      loop do
        raise_if_kernel_failed!
        return self unless running?

        if t1 + timeout < Time.now
          raise TimeoutError, 'Timeout occurred while waiting for shutdown'
        end

        sleep(1)
      end
    end

    # Wait for a system service to start
    # @param name [String]
    # @return [Machine]
    def wait_for_service(name)
      cmd = service_check_command(name)
      raise NotImplementedError, "#{self.class} does not implement service checks" if cmd.nil?

      wait_until_succeeds(cmd)
      self
    end

    # Allow matching fatal kernel console output only while the block runs.
    # Other kernel failure signatures remain fatal.
    # @param pattern [Regexp]
    def allow_kernel_failure(pattern)
      raise ArgumentError, 'pattern must be a Regexp' unless pattern.is_a?(Regexp)

      @mutex.synchronize { @allowed_kernel_failure_patterns << pattern }
      yield
    ensure
      if pattern.is_a?(Regexp)
        @mutex.synchronize do
          i = @allowed_kernel_failure_patterns.rindex(pattern)
          @allowed_kernel_failure_patterns.delete_at(i) if i
        end
      end
    end

    def kernel_failed?
      @mutex.synchronize { !@kernel_failure.nil? }
    end

    def raise_if_kernel_failed!
      failure = @mutex.synchronize { @kernel_failure&.dup }
      return self unless failure

      raise KernelFailure.new(
        machine_name: name,
        console_line: failure.fetch(:line),
        console_log_path:
      )
    end

    def kill_after_kernel_failure(drain_timeout: 1)
      detected_at = @mutex.synchronize { @kernel_failure_detected_at }

      if detected_at
        remaining = drain_timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - detected_at)
        sleep(remaining) if remaining > 0
      end

      kill(signal: 'KILL')
    end

    # Return text captured from the machine's console so far
    # @return [String]
    def console_output
      @mutex.synchronize { (@console_output || '').dup }
    end

    # Wait for text to appear in console output
    # @param regex [Regexp]
    # @return [Machine]
    def wait_for_console_text(regex, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      log_started_at = log.console_wait_begin(regex)

      loop do
        raise_if_kernel_failed!

        if regex =~ console_output
          log.console_wait_end(true, nil, log_started_at)
          return self
        end

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          log.console_wait_end(false, 'timeout', log_started_at)
          raise TimeoutError, "Timeout occurred while waiting for #{regex.inspect} on the console"
        elsif !running?
          log.console_wait_end(false, 'machine not running', log_started_at)
          raise Error, 'Machine is not running'
        end

        sleep(1)
      end

      self
    end

    # Create a directory inside the machine
    # @param path [String] path within the machine
    # @return [Machine]
    def mkdir(path)
      succeeds("mkdir \"#{path}\"")
      self
    end

    # Create a directory inside the machine
    # @param path [String] path within the machine
    # @return [Machine]
    def mkdir_p(path)
      succeeds("mkdir -p \"#{path}\"")
      self
    end

    # Push file from the host to the machine
    # @param src [String] file on the host
    # @param dst [String] file within the machine
    # @param preserve [Boolean]
    # @param mkpath [Boolean]
    # @return [Machine]
    def push_file(src, dst, preserve: false, mkpath: false)
      mkdir_p(File.dirname(dst)) if mkpath
      shared_dir.push_file(src, dst, preserve:)
      self
    end

    # Pull file from the machine to the host
    # @param src [String] file within the machine
    # @return [String] path to the file on the host
    def pull_file(src, preserve: false)
      shared_dir.pull_file(src, preserve:)
    end

    # @return [ShellCollection]
    def shells
      @shell_collection
    end

    def inspect
      "#<#{self.class.name}:#{object_id} name=#{name}>"
    end

    protected

    attr_reader :config, :tmpdir, :sockdir, :qemu_pid, :qemu_read, :qemu_reaper,
                :console_thread, :shell_instances, :log, :virtiofsd_pids, :shared_dir,
                :hash_base, :shared_filesystems

    def monotonic_deadline(timeout)
      monotonic_now + timeout
    end

    def remaining_time!(deadline, timeout_message)
      remaining = deadline - monotonic_now
      raise TimeoutError, timeout_message if remaining <= 0

      remaining
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def with_deadline(deadline, timeout_message, &block)
      return block.call unless deadline

      ::Timeout.timeout(
        remaining_time!(deadline, timeout_message),
        TimeoutError,
        timeout_message,
        &block
      )
    end

    def sleep_with_deadline(duration, deadline, timeout_message)
      return sleep(duration) unless deadline

      sleep([duration, remaining_time!(deadline, timeout_message)].min)
      remaining_time!(deadline, timeout_message)
    end

    def qemu_command(kernel_params: [])
      raise NotImplementedError, "#{self.class} must implement #qemu_command"
    end

    def service_check_command(_name)
      nil
    end

    def poweroff_command
      'poweroff -f'
    end

    def base_kernel_params(kernel_params)
      [
        'console=ttyS0',
        "init=#{config.toplevel}/init"
      ] + config.kernel_params + kernel_params
    end

    def qemu_boot_options(kernel_params)
      if config.boot_mode == 'direct'
        [
          '-kernel', config.kernel,
          '-initrd', config.initrd,
          '-append', base_kernel_params(kernel_params).join(' ')
        ]
      else
        ret = []
        ret += ['-boot', "order=#{config.boot_order}"] if config.boot_order
        ret
      end
    end

    def qemu_boot_media_options
      return [] if config.iso.nil?

      ['-cdrom', config.iso]
    end

    def qemu_shell_options
      ret = ['-device', 'virtio-serial']

      shell_instances.each do |shell|
        ret += shell.qemu_options
      end

      ret
    end

    def qemu_disk_options
      ret = []

      config.disks.each_with_index do |disk, i|
        ret << '-drive' << "id=disk#{i},file=#{disk_path(disk.device)},if=none,format=raw"
        ret << '-device' << "ide-hd,drive=disk#{i},bus=ahci.#{i}"
      end

      ret
    end

    def qemu_virtiofs_options
      ret = []

      shared_filesystems.each_with_index do |fs, i|
        name, = fs
        ret << '-chardev' << "socket,id=char#{i},path=#{virtiofs_socket_path(name)}"
        ret << '-device' << "vhost-user-fs-pci,queue-size=1024,chardev=char#{i},tag=#{name}"
      end

      if ret.any? && !custom_qemu_numa_memory_backend?
        ret << '-object' << "memory-backend-file,id=m0,size=#{config.memory}M,mem-path=/dev/shm,share=on"
        ret << '-numa' << 'node,memdev=m0'
      end

      ret
    end

    def custom_qemu_numa_memory_backend?
      opts = config.extra_qemu_options
      has_memory_backend = false
      has_numa_memdev = false

      opts.each_cons(2) do |arg, value|
        if arg == '-object' && value.start_with?('memory-backend-')
          has_memory_backend = true
        elsif arg == '-numa' && value.start_with?('node,') && value.include?('memdev=')
          has_numa_memdev = true
        end
      end

      has_memory_backend && has_numa_memdev
    end

    def start_virtiofs
      shared_filesystems.each do |name, path|
        f = File.open(virtiofs_log_path(name), 'w')

        begin
          # If the deadline fires as spawn returns, publish the child PID before
          # delivering it so startup rollback cannot lose ownership.
          Thread.handle_interrupt(TimeoutError => :never) do
            virtiofsd_pids << Process.spawn(
              File.join(config.virtiofsd, 'bin/virtiofsd'),
              '--socket-path', virtiofs_socket_path(name),
              '--shared-dir', path,
              '--cache', 'auto',
              in: :close,
              out: f,
              err: f
            )
          end
        ensure
          f.close
        end
      end
    end

    def rollback_start(qemu_pid:, qemu_reaper:, qemu_write:)
      begin
        qemu_write&.close
      rescue IOError
        # The spawn handoff may already have closed this exact descriptor.
      end

      if qemu_pid
        if qemu_reaper
          qemu_reaper.signal('KILL')
          qemu_reaper.join
        else
          terminate_unreaped_child(qemu_pid, 'KILL')
        end
      end
    ensure
      begin
        # A completed reaper has already run these operations. Every step is
        # deliberately idempotent so rollback can repeat them after join.
        cleanup_runtime_resources
      ensure
        mark_runtime_stopped
      end
    end

    def stop_virtiofs
      virtiofsd_pids.delete_if do |pid|
        Process.kill('TERM', pid)
        false
      rescue Errno::ESRCH
        true
      end

      virtiofsd_pids.delete_if do |pid|
        Process.wait(pid)
        true
      end
    end

    def run_qemu_reaper(pid)
      QemuReaper.new(pid) do |status|
        log.exit(status.exitstatus) if status
      ensure
        begin
          cleanup_runtime_resources
        ensure
          mark_runtime_stopped
        end
      end
    end

    # Before a reaper exists, this thread is the sole child owner. Poll before
    # signaling; after a live poll an exit remains an unreaped zombie until the
    # final wait, which prevents PID reuse across the signal operation.
    def terminate_unreaped_child(pid, signal)
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return waited.last if waited

      begin
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        # The child may have exited after the nonblocking wait.
      end

      Process.waitpid2(pid).last
    rescue Errno::ECHILD
      nil
    end

    def cleanup_runtime_resources
      cleanup_error = nil
      cleanup_steps = [
        lambda do
          @qemu_read&.close
        rescue IOError
          # ignore
        ensure
          @qemu_read = nil
        end,
        lambda do
          if @console_thread
            console_thread.join
            @console_thread = nil
          end
        end,
        -> { shell_instances.each(&:close) },
        -> { stop_virtiofs },
        -> { cleanup }
      ]

      cleanup_steps.each do |step|
        step.call
      rescue StandardError => e
        cleanup_error ||= e
      end

      raise cleanup_error if cleanup_error
    end

    def mark_runtime_stopped
      @qemu_pid = nil
      @qemu_reaper = nil
      @running = false
      @stopped_at = Time.now
    end

    def wait_for_reaper(reaper, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        raise_if_kernel_failed!
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if remaining <= 0

        if reaper.join([remaining, 1].min)
          raise_if_kernel_failed!
          return true
        end
      end
    end

    def run_console_thread
      console_read = qemu_read

      @console_thread = Thread.new do
        console_log = File.open(console_log_path, 'w')

        begin
          loop do
            rs = console_read.wait_readable
            next unless rs

            data = read_nonblock(console_read)
            append_console_output(data)

            console_log.write(data)
            console_log.flush
          end
        rescue EOFError
        rescue IOError
          # pass
        ensure
          append_console_output('', flush: true)
          console_log.close unless console_log.closed?
        end
      end
    end

    def reset_kernel_failure
      @mutex.synchronize do
        @kernel_failure = nil
        @kernel_failure_detected_at = nil
        @console_output = ''
        @console_scan_buffer = ''
      end
    end

    def append_console_output(data, flush: false)
      events = @mutex.synchronize do
        @console_output << data
        @console_scan_buffer << data

        lines = @console_scan_buffer.split("\n", -1)
        @console_scan_buffer = lines.pop || ''

        if flush && !@console_scan_buffer.empty?
          lines << @console_scan_buffer
          @console_scan_buffer = ''
        end

        lines.filter_map do |raw_line|
          line = raw_line.delete_suffix("\r")
          next unless KERNEL_FAILURE_PATTERN.match?(line)

          expected = @allowed_kernel_failure_patterns.any? { |pattern| pattern.match?(line) }

          unless expected || @kernel_failure
            @kernel_failure = { line: }
            @kernel_failure_detected_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          { line:, expected: }
        end
      end

      events.each { |event| log.kernel_failure(event.fetch(:line), expected: event.fetch(:expected)) }
    end

    def prepare_disks
      config.disks.each do |disk|
        next if disk.type != 'file' || !disk.create || File.exist?(disk_path(disk.device))

        `truncate -s#{disk.size} #{disk_path(disk.device)}`
      end
    end

    def shell_chardev_id(index)
      shell_for(index).chardev_id
    end

    def shell_socket_path(index = 0)
      suffix = index == 0 ? 'shell' : "shell#{index}"
      socket_path("#{name}-#{suffix}.sock")
    end

    def shell_log_path(index = 0)
      suffix = index == 0 ? 'shell' : "shell#{index}"
      File.join(tmpdir, "#{name}-#{suffix}.log")
    end

    def console_log_path
      File.join(tmpdir, "#{name}-console.log")
    end

    def disk_path(path)
      resolved = path.gsub('{machine}', name)

      if resolved.start_with?('/')
        resolved
      else
        File.join(tmpdir, resolved)
      end
    end

    def virtiofs_socket_path(mount_name)
      socket_path("#{name}-fs-#{mount_name}.sock")
    end

    def virtiofs_log_path(mount_name)
      File.join(tmpdir, "#{name}-fs-#{mount_name}.log")
    end

    def socket_path(socket)
      @socket_hash ||= Digest::SHA256.hexdigest([hash_base, name].join)[0..7]
      File.join(sockdir, "#{@socket_hash}-#{socket}")
    end

    def current_shell_index
      index = Thread.current[SHELL_INDEX_KEY] || 0
      validate_shell_index(index)
      index
    end

    def current_shell
      shell_for(current_shell_index)
    end

    def command_shell(name)
      name.nil? ? current_shell : shells.fetch(name)
    end

    def shell_for(index)
      validate_shell_index(index)
      @shell_instances[index]
    end

    def validate_shell_index(index)
      return if index.is_a?(Integer) && index >= 0 && index < config.test_shells

      raise ArgumentError, "invalid shell index #{index.inspect}"
    end

    def mount_shared_dir_once
      return if @shared_dir_mounted

      @shared_dir_mutex.synchronize do
        return if @shared_dir_mounted

        shared_dir.mount
        @shared_dir_mounted = true
      end
    end

    def read_nonblock(io)
      io.read_nonblock(4096)
    rescue IO::WaitReadable
      ''
    end
  end
end
