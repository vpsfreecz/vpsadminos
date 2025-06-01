require 'base64'
require 'digest'
require 'fileutils'
require 'shellwords'
require 'socket'

module OsVm
  class Machine
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
    def initialize(name, config, tmpdir, sockdir, default_timeout: 600, hash_base: '', interactive_console: false)
      @name = name
      @config = config
      @tmpdir = tmpdir
      @sockdir = sockdir
      @default_timeout = default_timeout
      @hash_base = hash_base
      @interactive_console = interactive_console
      @start_kernel_params = []
      @running = false
      @shell_up = false
      @shared_dir = SharedDir.new(self)
      @shared_filesystems = {
        shared_dir.fs_name => shared_dir.host_path
      }.merge(config.shared_filesystems)
      @virtiofsd_pids = []
      @mutex = Mutex.new

      FileUtils.mkdir_p(tmpdir)
      FileUtils.mkdir_p(sockdir)
      @log = MachineLog.new(File.join(tmpdir, "#{name}-log.log"))
    end

    def finalize
      log.close
    end

    # Start the machine
    # @param kernel_params [Array<String>]
    # @return [Machine]
    def start(kernel_params: [])
      if running?
        raise 'Machine already started'
      end

      log.start
      prepare_disks

      # Clear-out left-over socket
      begin
        File.unlink(shell_socket_path)
      rescue Errno::ENOENT
        # ignore
      end

      @shell_server = UNIXServer.new(shell_socket_path)

      shared_dir.setup
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

      @qemu_pid = Process.spawn(
        *qemu_command(kernel_params:),
        **qemu_kwargs
      )
      w.close unless @interactive_console
      run_qemu_reaper(qemu_pid)

      @running = true

      run_console_thread unless @interactive_console

      @shell = @shell_server.accept
      self
    end

    # Block until the machine stops
    def join(timeout: @default_timeout)
      qemu_reaper.join(timeout)
      nil
    end

    # Stop the machine
    # @param timeout [Integer]
    # @return [Machine]
    def stop(timeout: @default_timeout)
      log.stop
      execute('poweroff -f')

      if qemu_reaper.join(timeout).nil?
        raise UnrecoverableTimeoutError, "Timeout while stopping machine #{name}"
      end

      self
    end

    # Kill the machine
    # @return [Machine]
    def kill
      unless running?
        log.kill('NONE')
        return
      end

      log.kill('TERM')

      begin
        Process.kill('TERM', qemu_pid)
      rescue Errno::ESRCH
        warn "Unable to kill machine #{name} using SIGTERM"
      end

      return if qemu_reaper.join(60)

      log.kill('KILL')

      begin
        Process.kill('KILL', qemu_pid)
      rescue Errno::ESRCH
        warn "Unable to kill machine #{name} using SIGKILL"
      end

      qemu_reaper.join
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
        next if disk.type != 'file'

        path = disk_path(disk.device)
        FileUtils.rm_f(path)
      end

      self
    end

    # Cleanup machine state
    # @return [Machine]
    def cleanup
      begin
        File.unlink(shell_socket_path)
      rescue Errno::ENOENT
        # ignore
      end

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
      shell_up?
    end

    # Wait until the system has booted
    # @param timeout [Integer]
    def wait_for_boot(timeout: @default_timeout)
      wait_for_shell(timeout:)
    end

    # Execute a command
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>] exit status and output
    def execute(cmd, timeout: @default_timeout)
      start unless running?
      wait_for_shell

      real_timeout = [timeout, 5].max
      vm_command = "set -euo pipefail; #{cmd}"
      timeout_command = "timeout #{real_timeout}"

      # For unknown reason, the first character written to the shell is cut. Sometimes
      # more characters are lost. We therefore prefix the executed command with whitespace
      # which can be lost.
      workaround = ' ' * 10

      shell.write("#{workaround}#{timeout_command} bash -c #{Shellwords.escape(vm_command)} 2>&1 | (base64 -w 0; echo)\n")
      log.execute_begin(cmd)

      output = Base64.decode64(read_shell_output(timeout: real_timeout + 5, command: vm_command))

      shell.write("#{workaround}echo ${PIPESTATUS[0]}\n")
      status = read_shell_output(timeout: 60, command: 'echo ${PIPESTATUS[0]}').strip.to_i

      if timeout && status == 124
        log.execute_end(-1, output)
        raise TimeoutError, "Timeout occured while running command '#{cmd}', " \
                            "output: #{output.inspect}"
      end

      log.execute_end(status, output)
      [status, output]
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
        raise TimeoutError, "Timeout occured while running command '#{cmd}'" if cur_timeout <= 0

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
        raise TimeoutError, "Timeout occured while running command '#{cmd}'" if cur_timeout <= 0

        sleep(1)
      end
    end

    # Wait until network is operational, including DNS
    # @return [Machine]
    def wait_until_online(timeout: @default_timeout)
      wait_until_succeeds('curl --head https://vpsadminos.org', timeout:)
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
          raise TimeoutError, 'Timeout occured while waiting for shutdown'
        end

        sleep(1)
      end
    end

    # Wait for runit system service to start
    # @param name [String]
    # @return [Machine]
    def wait_for_service(name)
      wait_until_succeeds("sv check #{name}")
      self
    end

    # osctl command without `osctl`, output is returned as JSON
    # @param cmd [String]
    # @return [Hash]
    def osctl_json(cmd)
      status, output = succeeds("osctl -j #{cmd}")
      JSON.parse(output, symbolize_names: true)
    end

    # Wait for zpool
    # @param name [String]
    # @param timeout [Integer]
    # @return [Machine]
    def wait_for_zpool(name, timeout: @default_timeout)
      wait_until_succeeds("zpool list #{name}", timeout:)
      self
    end

    # Wait for pool to be imported into osctld
    # @param name [String]
    # @param timeout [Integer]
    # @return [Machine]
    def wait_for_osctl_pool(name, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        status, output = wait_until_succeeds(
          "osctl pool show -H -o state #{name}",
          timeout: cur_timeout
        )

        return self if output.strip == 'active'

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          raise TimeoutError, "Timeout occured while waiting for pool #{name.inspect} to become active"
        end

        sleep(1)
      end
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
      shared_dir.push_file(src, dst)
      self
    end

    # Pull file from the machine to the host
    # @param src [String] file within the machine
    # @return [String] path to the file on the host
    def pull_file(src, preserve: false)
      shared_dir.pull_file(src, preserve:)
    end

    def inspect
      "#<#{self.class.name}:#{object_id} name=#{name}>"
    end

    protected

    attr_reader :config, :tmpdir, :sockdir, :qemu_pid, :qemu_read, :qemu_reaper,
                :console_thread, :shell_server, :shell, :log, :virtiofsd_pids, :shared_dir,
                :hash_base, :shared_filesystems

    def qemu_command(kernel_params: [])
      all_kernel_params = [
        'console=ttyS0',
        "init=#{config.toplevel}/init"
      ] + config.kernel_params + kernel_params

      [
        "#{config.qemu}/bin/qemu-kvm",
        '-name', "os-vm-#{name}",
        '-m', config.memory.to_s,
        '-cpu', 'host',
        '-smp', "cpus=#{config.cpus},cores=#{config.cpu.cores},threads=#{config.cpu.threads},sockets=#{config.cpu.sockets}",
        '--no-reboot',
        '-device', 'ahci,id=ahci'
      ] + config.network.qemu_options + [
        '-drive', "index=0,id=drive1,file=#{config.squashfs},readonly=on,media=cdrom,format=raw,if=virtio",
        '-chardev', "socket,id=shell,path=#{shell_socket_path}",
        '-device', 'virtio-serial',
        '-device', 'virtconsole,chardev=shell',
        '-kernel', config.kernel,
        '-initrd', config.initrd,
        '-append', all_kernel_params.join(' '),
        '-nographic'
      ] + qemu_disk_options + qemu_virtiofs_options + config.extra_qemu_options
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

      if ret.any?
        ret << '-object' << "memory-backend-file,id=m0,size=#{config.memory}M,mem-path=/dev/shm,share=on"
        ret << '-numa' << 'node,memdev=m0'
      end

      ret
    end

    def start_virtiofs
      shared_filesystems.each do |name, path|
        f = File.open(virtiofs_log_path(name), 'w')

        virtiofsd_pids << Process.spawn(
          File.join(config.virtiofsd, 'bin/virtiofsd'),
          '--socket-path', virtiofs_socket_path(name),
          '--shared-dir', path,
          '--cache', 'never',
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
      @qemu_reaper = Thread.new do
        Process.wait(pid)
        log.exit($?.exitstatus)

        @qemu_pid = nil

        if @qemu_read
          @qemu_read.close
          @qemu_read = nil
        end

        if @console_thread
          console_thread.join
          @console_thread = nil
        end

        shell_server.close
        @shell_server = nil

        if shell
          shell.close
          @shell = nil
        end

        stop_virtiofs

        cleanup

        @qemu_reaper = nil
        @shell_up = false
        @running = false
      end
    end

    def run_console_thread
      @console_thread = Thread.new do
        console_log = File.open(console_log_path, 'w')

        begin
          loop do
            rs = qemu_read.wait_readable
            next unless rs

            console_log.write(read_nonblock(qemu_read))
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
        if disk.type != 'file' || !disk.create || File.exist?(disk_path(disk.device))
          next
        end

        `truncate -s#{disk.size} #{disk_path(disk.device)}`
      end
    end

    def wait_for_shell(timeout: @default_timeout)
      raise "machine #{name} is not running" unless running?
      return if shell_up?

      t1 = Time.now
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          raise TimeoutError, 'Timeout occured while waiting for shell'
        end

        rs = shell.wait_readable(1)
        next unless rs

        buffer << read_nonblock(shell)
        next unless buffer.include?("test-shell-ready\n")

        @shell_up = true
        shared_dir.mount
        return
      end
    end

    def shell_socket_path
      socket_path("#{name}-shell.sock")
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

    def shell_up?
      @shell_up
    end

    def read_shell_output(timeout:, command:)
      t1 = Time.now
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          raise UnrecoverableTimeoutError, "Timeout occured while running command '#{command}', " \
                                           "buffer contents: #{buffer.inspect}"
        end

        rs = shell.wait_readable(1)
        next unless rs

        buffer << read_nonblock(shell)
        break if buffer.end_with?("\n")
      end

      buffer
    end

    def read_nonblock(io)
      io.read_nonblock(4096)
    rescue IO::WaitReadable
      ''
    end
  end
end
