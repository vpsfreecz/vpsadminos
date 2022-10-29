require 'digest'
require 'fileutils'
require 'socket'
require 'thread'

module OsVm
  class Machine
    attr_reader :name

    def initialize(name, config, tmpdir, sockdir, default_timeout: 900, hash_base: '')
      @name = name
      @config = config
      @tmpdir = tmpdir
      @sockdir = sockdir
      @default_timeout = default_timeout || 900
      @hash_base = hash_base
      @running = false
      @shell_up = false
      @shared_dir = SharedDir.new(self)
      @shared_filesystems = {
        shared_dir.fs_name => shared_dir.host_path,
      }.merge(config.fetch(:shared_filesystems, {}))
      @can_use_virtiofs = Process.uid == 0
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
        fail 'Machine already started'
      end

      log.start
      prepare_disks

      @shell_server = UNIXServer.new(shell_socket_path)

      if can_use_virtiofs?
        shared_dir.setup
        start_virtiofs
        sleep(1)
      end

      @qemu_read, w = IO.pipe
      @qemu_pid = Process.spawn(
        *qemu_command(kernel_params: kernel_params),
        in: :close,
        out: w,
        err: w,
      )
      w.close
      run_qemu_reaper(qemu_pid)

      @running = true

      run_console_thread

      @shell = @shell_server.accept
      self
    end

    # Stop the machine
    # @param timeout [Integer]
    # @return [Machine]
    def stop(timeout: @default_timeout)
      log.stop
      execute('poweroff -f')

      if qemu_reaper.join(timeout).nil?
        raise TimeoutError, "Timeout while stopping machine #{name}"
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

    # Cleanup machine state
    # @return [Machine]
    def cleanup
      begin
        File.unlink(shell_socket_path)
      rescue Errno::ENOENT
      end

      shared_filesystems.each_key do |fs_name|
        begin
          File.unlink(virtiofs_socket_path(fs_name))
        rescue Errno::ENOENT
        end
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
      wait_for_shell(timeout: timeout)
    end

    # Execute a command
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>] exit status and output
    def execute(cmd, timeout: @default_timeout)
      start unless running?
      wait_for_shell
      t1 = Time.now

      # It is a bit of a mystery why this write is needed. The shell just
      # sometimes swallows the first character, which would be a '(', and then
      # it complains about a syntax error. So we first write a character that
      # it can harmlessly swallow.
      shell.write("\n")

      shell.write("( #{cmd} ); echo '|!=EOF' $?\n")
      log.execute_begin(cmd)
      rx = /(.*)\|\!=EOF\s+(\d+)/m
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          log.execute_end(-1, buffer)
          raise TimeoutError, "Timeout occured while running command '#{cmd}'"
        end

        rs, _ = IO.select([shell], [], [], 1)
        next if rs.nil?

        rs.each do |io|
          case io
          when shell
            buffer << read_nonblock(shell)
          end
        end

        if rx =~ buffer
          status = $2.to_i
          output = $1.strip

          log.execute_end(status, output)
          return [status, output]
        end
      end
    end

    # Execute command and check that it succeeds
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def succeeds(cmd, timeout: @default_timeout)
      status, output = execute(cmd, timeout: timeout)

      if status != 0
        raise CommandFailed, "Command '#{cmd}' failed with status #{status}. Output:\n #{output}"
      end

      return [status, output]
    end

    # Execute command and check that it fails
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def fails(cmd, timeout: @default_timeout)
      status, output = execute(cmd, timeout: timeout)

      if status == 0
        raise CommandSucceeded, "Command '#{cmd}' succeeds with status #{status}. Output:\n #{output}"
      end

      return [status, output]
    end

    # Execute all commands and check that they all succeed
    # @param cmds [String]
    # @return [Array<Array<[Integer, String]>>]
    def all_succeed(*cmds)
      ret = []

      cmds.each do |cmd|
        ret << succeeds(cmd)
      end

      ret
    end

    # Execute all commands and check that they all fail
    # @param cmds [String]
    # @return [Array<Array<[Integer, String]>>]
    def all_fail(*cmds)
      ret = []

      cmds.each do |cmd|
        ret << fails(cmd)
      end

      ret
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
        sleep(1)
      end
    end

    # Wait until network is operational, including DNS
    # @return [Machine]
    def wait_until_online(timeout: @default_timeout)
      wait_until_succeeds("curl --head https://vpsadminos.org", timeout: timeout)
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
          raise TimeoutError, "Timeout occured while waiting for shutdown"
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
      wait_until_succeeds("zpool list #{name}", timeout: timeout)
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
          timeout: cur_timeout,
        )

        return self if output == 'active'

        cur_timeout = timeout - (Time.now - t1)
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
      unless can_use_virtiofs?
        fail "#{$0} must be run as root for push_file() to work"
      end

      mkdir_p(File.dirname(dst)) if mkpath
      shared_dir.push_file(src, dst)
      self
    end

    # Pull file from the machine to the host
    # @param src [String] file within the machine
    # @return [String] path to the file on the host
    def pull_file(src, preserve: false)
      unless can_use_virtiofs?
        fail "#{$0} must be run as root for pull_file() to work"
      end

      shared_dir.pull_file(src, preserve: preserve)
    end

    def inspect
      "#<#{self.class.name}:#{self.object_id} name=#{name}>"
    end

    protected
    attr_reader :config, :tmpdir, :sockdir, :qemu_pid, :qemu_read, :qemu_reaper,
      :console_thread, :shell_server, :shell, :log, :virtiofsd_pids, :shared_dir,
      :hash_base, :shared_filesystems

    def qemu_command(kernel_params: [])
      all_kernel_params = [
        "console=ttyS0",
        "init=#{config[:toplevel]}/init",
      ] + config[:kernelParams] + kernel_params

      [
        "#{config[:qemu]}/bin/qemu-kvm",
        "-name", "os-vm-#{name}",
        "-m", "#{config[:memory]}",
        "-cpu", "host",
        "-smp", "cpus=#{config[:cpus]},cores=#{config[:cpu][:cores]},threads=#{config[:cpu][:threads]},sockets=#{config[:cpu][:sockets]}",
        "--no-reboot",
        "-device", "ahci,id=ahci",
        "-device", "virtio-net,netdev=net0",
        "-netdev", "user,id=net0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3",
        "-drive", "index=0,id=drive1,file=#{config[:squashfs]},readonly=on,media=cdrom,format=raw,if=virtio",
        "-chardev", "socket,id=shell,path=#{shell_socket_path}",
        "-device", "virtio-serial",
        "-device", "virtconsole,chardev=shell",
        "-kernel", config[:kernel],
        "-initrd", config[:initrd],
        "-append", "#{all_kernel_params.join(' ')}",
        "-nographic",
      ] + qemu_disk_options + qemu_virtiofs_options
    end

    def qemu_disk_options
      ret = []

      config[:disks].each_with_index do |disk, i|
        ret << "-drive" << "id=disk#{i},file=#{disk_path(disk[:device])},if=none,format=raw"
        ret << "-device" << "ide-hd,drive=disk#{i},bus=ahci.#{i}"
      end

      ret
    end

    def qemu_virtiofs_options
      ret = []
      return ret unless can_use_virtiofs?

      shared_filesystems.each_with_index do |fs, i|
        name, _ = fs
        ret << "-chardev" << "socket,id=char#{i},path=#{virtiofs_socket_path(name)}"
        ret << "-device" << "vhost-user-fs-pci,queue-size=1024,chardev=char#{i},tag=#{name}"
      end

      if ret.any?
        ret << "-object" << "memory-backend-file,id=m0,size=#{config[:memory]}M,mem-path=/dev/shm,share=on"
        ret << "-numa" << "node,memdev=m0"
      end

      ret
    end

    def start_virtiofs
      shared_filesystems.each do |name, path|
        f = File.open(virtiofs_log_path(name), 'w')

        virtiofsd_pids << Process.spawn(
          File.join(config[:qemu], 'libexec/virtiofsd'),
          "--socket-path=#{virtiofs_socket_path(name)}",
          "-o", "source=#{path}",
          "-o", "cache=none",
          in: :close,
          out: f,
          err: f,
        )

        f.close
      end
    end

    def stop_virtiofs
      virtiofsd_pids.delete_if do |pid|
        begin
          Process.kill('TERM', pid)
          false
        rescue Errno::ESRCH
          true
        end
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
        @qemu_read.close
        @qemu_read = nil

        console_thread.join
        @console_thread = nil

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
            rs, _ = IO.select([qemu_read])

            rs.each do |io|
              case io
              when qemu_read
                console_log.write(read_nonblock(qemu_read))
                console_log.flush
              end
            end
          end
        rescue EOFError
          console_log.close
        end
      end
    end

    def prepare_disks
      config[:disks].each do |disk|
        next if disk[:type] != 'file' || File.exist?(disk_path(disk[:device]))

        `truncate -s#{disk[:size]} #{disk_path(disk[:device])}`
      end
    end

    def destroy_disks
      config[:disks].each do |disk|
        next if disk[:type] != 'file'

        path = disk_path(disk[:device])
        File.unlink(path) if File.exist?(path)
      end
    end

    def wait_for_shell(timeout: @default_timeout)
      fail "machine #{name} is not running" unless running?
      return if shell_up?

      t1 = Time.now
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          raise TimeoutError, "Timeout occured while waiting for shell"
        end

        rs, _ = IO.select([shell], [], [], 1)
        next if rs.nil?

        rs.each do |io|
          case io
          when shell
            buffer << read_nonblock(shell)
          end
        end

        if buffer.include?("test-shell-ready\r\n")
          @shell_up = true
          succeeds("stty -F /dev/hvc0 -echo")
          shared_dir.mount if can_use_virtiofs?
          return
        end
      end
    end

    def shell_socket_path
      socket_path("#{name}-shell.sock")
    end

    def console_log_path
      File.join(tmpdir, "#{name}-console.log")
    end

    def disk_path(path)
      if path.start_with?('/')
        path
      else
        File.join(tmpdir, path)
      end
    end

    def can_use_virtiofs?
      @can_use_virtiofs
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

    def read_nonblock(io)
      io.read_nonblock(4096)

    rescue IO::WaitReadable
      ''
    end
  end
end
