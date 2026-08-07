require 'digest'
require 'fileutils'

module OsVm
  class Machine
    SHELL_INDEX_KEY = :osvm_machine_shell_index
    QEMU_REAP_INTERVAL = 0.1

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
      @qemu_mutex = Mutex.new
      @qemu_cv = ConditionVariable.new
      @shared_dir_mutex = Mutex.new
      @shared_dir_mounted = false

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
    def start(kernel_params: [], wait_for_boot: false)
      @start_mutex.synchronize do
        if running?
          unless start_kernel_params == kernel_params
            raise 'Machine already started with different kernel parameters'
          end

          self.wait_for_boot if wait_for_boot
          return self
        end

        # virtiofsd cannot be relaunched right away, it needs some time settle
        # for unknown reasons, so we ensure there's a 5 second gap between stop
        # and start of this machine
        if @stopped_at
          diff = Time.now - @stopped_at
          delay = 5
          sleep([delay - diff, delay].min) if diff <= delay
        end

        log.start
        prepare_disks

        shell_instances.each(&:prepare)

        shared_dir.setup
        @shared_dir_mounted = false
        start_virtiofs
        sleep(1)

        qemu_kwargs = {}

        unless @interactive_console
          @qemu_read, w = IO.pipe

          qemu_kwargs = {
            in: :close,
            out: w,
            err: w
          }
        end

        @start_kernel_params = kernel_params

        pid = Process.spawn(
          *qemu_command(kernel_params:),
          **qemu_kwargs
        )
        w.close unless @interactive_console

        qemu_mutex.synchronize do
          @qemu_pid = pid
          @running = true
          @qemu_reaper = run_qemu_reaper(pid)
        end

        run_console_thread unless @interactive_console

        self.wait_for_boot if wait_for_boot
        self
      end
    end

    # Block until the machine stops
    def join(timeout: @default_timeout)
      _pid, reaper, = qemu_state
      reaper&.join(timeout)
      nil
    end

    # Stop the machine
    # @param timeout [Integer]
    # @return [Machine]
    def stop(timeout: @default_timeout)
      log.stop
      begin
        execute(poweroff_command)
      rescue MachineShellClosed
        # The shell logs the failed command.
      end

      _pid, reaper, = qemu_state

      if reaper && reaper.join(timeout).nil?
        raise UnrecoverableTimeoutError, "Timeout while stopping machine #{name}"
      end

      self
    end

    # Kill the machine
    # @param signal ['TERM', 'KILL']
    # @return [Machine]
    def kill(signal: 'TERM')
      pid, reaper, running = qemu_state

      unless running
        log.kill('NONE')
        return self
      end

      if pid.nil?
        log.kill('NONE')
        reaper&.join
        return self
      end

      log.kill(signal)

      signal_qemu(signal, pid)

      if signal == 'KILL' || wait_for_qemu_exit(pid, 60)
        reaper&.join
        return self
      end

      log.kill('KILL')
      signal_qemu('KILL', pid)
      reaper&.join
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
      qemu_mutex.synchronize { @running }
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
    def wait_for_boot(timeout: @default_timeout)
      current_shell.wait(timeout:)
    end

    # Execute a command
    # @param cmd [String]
    # @param timeout [Integer]
    # @raise [MachineShellClosed]
    # @return [Array<Integer, String>] exit status and output
    def execute(cmd, timeout: @default_timeout, shell: nil)
      command_shell(shell).execute(cmd, timeout:)
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
    def wait_until_online(timeout: @default_timeout)
      wait_until_succeeds('curl --head https://check-online.vpsadminos.org', timeout:)
      self
    end

    # Wait until the machine shuts down
    # @param timeout [Integer]
    # @return [Machine]
    def wait_for_shutdown(timeout: @default_timeout)
      t1 = Time.now

      loop do
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
                :hash_base, :shared_filesystems, :qemu_mutex, :qemu_cv

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

        virtiofsd_pids << Process.spawn(
          File.join(config.virtiofsd, 'bin/virtiofsd'),
          '--socket-path', virtiofs_socket_path(name),
          '--shared-dir', path,
          '--cache', 'auto',
          in: :close,
          out: f,
          err: f
        )

        f.close
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
      Thread.new do
        status = wait_for_qemu(pid)

        begin
          log.exit(status)

          if @qemu_read
            @qemu_read.close
            @qemu_read = nil
          end

          if @console_thread
            console_thread.join
            @console_thread = nil
          end

          shell_instances.each(&:close)

          stop_virtiofs

          cleanup
        ensure
          qemu_mutex.synchronize do
            @qemu_reaper = nil if @qemu_reaper == Thread.current
            @running = false
            @stopped_at = Time.now
            qemu_cv.broadcast
          end
        end
      end
    end

    def wait_for_qemu(pid)
      loop do
        result = qemu_mutex.synchronize do
          ret = Process.wait2(pid, Process::WNOHANG)

          if ret
            @qemu_pid = nil if @qemu_pid == pid
            qemu_cv.broadcast
          end

          ret
        end

        return result.last if result

        sleep(QEMU_REAP_INTERVAL)
      end
    end

    def qemu_state
      qemu_mutex.synchronize { [@qemu_pid, @qemu_reaper, @running] }
    end

    def wait_for_qemu_exit(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      qemu_mutex.synchronize do
        while @qemu_pid == pid
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining <= 0

          qemu_cv.wait(qemu_mutex, remaining)
        end
      end

      true
    end

    def signal_qemu(signal, pid)
      qemu_mutex.synchronize do
        return unless @qemu_pid == pid

        Process.kill(signal, pid)
      end
    rescue Errno::ESRCH
      warn "Unable to kill machine #{name} using SIG#{signal}"
    end

    def run_console_thread
      @console_output = ''

      @console_thread = Thread.new do
        console_log = File.open(console_log_path, 'w')

        begin
          loop do
            rs = qemu_read.wait_readable
            next unless rs

            data = read_nonblock(qemu_read)
            @mutex.synchronize { @console_output << data }

            console_log.write(data)
            console_log.flush
          end
        rescue EOFError
          console_log.close
        rescue IOError
          # pass
        end
      end
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
