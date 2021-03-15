require 'fileutils'
require 'socket'
require 'thread'

module TestRunner
  class Machine
    TIMEOUT = 900

    attr_reader :name

    def initialize(name, config, tmpdir)
      @name = name
      @config = config
      @tmpdir = tmpdir
      @running = false
      @shell_up = false
      @mutex = Mutex.new

      FileUtils.mkdir_p(tmpdir)
      @log = MachineLog.new(File.join(tmpdir, "#{name}-log.log"))
    end

    def finalize
      log.close
    end

    def start
      if running?
        fail 'Machine already started'
      end

      log.start
      prepare_disks

      @shell_server = UNIXServer.new(shell_socket_path)
      @qemu = IO.popen("exec #{qemu_command.join(' ')} 2>&1", 'r+')
      @running = true

      run_console_thread

      @shell = @shell_server.accept
    end

    def stop
      log.stop
      execute('poweroff')
      cleanup
    end

    def kill
      log.kill

      begin
        Process.kill('TERM', qemu.pid) if qemu
      rescue Errno::ESRCH
        warn "Unable to kill machine #{name}"
      end

      cleanup
    end

    def destroy
      log.destroy
      destroy_disks
    end

    def running?
      @running
    end

    def booted?
      shell_up?
    end

    # Wait until the system has booted
    def wait_for_boot(timeout: TIMEOUT)
      wait_for_shell(timeout: timeout)
    end

    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def execute(cmd, timeout: TIMEOUT)
      start unless running?
      wait_for_shell
      t1 = Time.now
      shell.write("( #{cmd} ); echo '|!=EOF' $?\n")
      log.execute_begin(cmd)
      rx = /(.*)\|\!=EOF\s+(\d+)/m
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          log.execute_end(-1, buffer)
          fail "Timeout occured while running command '#{cmd}'"
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
    def succeeds(cmd, timeout: TIMEOUT)
      status, output = execute(cmd, timeout: timeout)

      if status != 0
        fail "Command '#{cmd}' failed with status #{status}. Output:\n #{output}"
      end

      return [status, output]
    end

    # Execute command and check that it fails
    # @param cmd [String]
    # @param timeout [Integer]
    # @return [Array<Integer, String>]
    def fails(cmd, timeout: TIMEOUT)
      status, output = execute(cmd, timeout: timeout)

      if status == 0
        fail "Command '#{cmd}' succeeds with status #{status}. Output:\n #{output}"
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
    def wait_until_succeeds(cmd, timeout: TIMEOUT)
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
    def wait_until_fails(cmd, timeout: TIMEOUT)
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
    def wait_until_online(timeout: TIMEOUT)
      wait_until_succeeds("curl https://vpsadminos.org", timeout: timeout)
    end

    # Wait until the machine shuts down
    def wait_for_shutdown(timeout: TIMEOUT)
      t1 = Time.now

      loop do
        unless running?
          cleanup
          return
        end

        if t1 + timeout < Time.now
          fail "Timeout occured while waiting for shutdown"
        end

        sleep(1)
      end
    end

    # Wait for runit system service to start
    # @param name [String]
    def wait_for_service(name)
      wait_until_succeeds("sv check #{name}")
    end

    # osctl command without `osctl`, output is returned as JSON
    # @return [Hash]
    def osctl_json(cmd)
      status, output = succeeds("osctl -j #{cmd}")
      JSON.parse(output, symbolize_names: true)
    end

    # Wait for zpool
    # @param name [String]
    def wait_for_zpool(name, timeout: TIMEOUT)
      wait_until_succeeds("zpool list #{name}", timeout: timeout)
    end

    # Wait for pool to be imported into osctld
    # @param name [String]
    def wait_for_osctl_pool(name, timeout: TIMEOUT)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        status, output = wait_until_succeeds(
          "osctl pool show -H -o state #{name}",
          timeout: cur_timeout,
        )

        return if output == 'active'

        cur_timeout = timeout - (Time.now - t1)
      end
    end

    protected
    attr_reader :config, :tmpdir, :qemu, :console_thread, :shell_server, :shell,
      :log

    def qemu_command
      kernel_params = [
        "console=ttyS0",
        "systemConfig=#{config[:toplevel]}",
      ] + config[:kernelParams]

      [
        "#{config[:qemu]}/bin/qemu-kvm",
        "-name", "os-test-#{name}",
        "-m", "#{config[:memory]}",
        "-smp", "cpus=#{config[:cpus]},cores=#{config[:cpu][:cores]},threads=#{config[:cpu][:threads]},sockets=#{config[:cpu][:sockets]}",
        "--no-reboot",
        "-device", "ahci,id=ahci",
        "-device", "virtio-net,netdev=net0",
        "-netdev", "user,id=net0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3",
        "-drive", "index=0,id=drive1,file=#{config[:squashfs]},readonly,media=cdrom,format=raw,if=virtio",
        "-chardev socket,id=shell,path=#{shell_socket_path}",
        "-device virtio-serial",
        "-device virtconsole,chardev=shell",
        "-kernel", config[:kernel],
        "-initrd", config[:initrd],
        "-append", "\"#{kernel_params.join(' ')}\"",
        "-nographic",
      ] + qemu_disk_options
    end

    def qemu_disk_options
      ret = []

      config[:disks].each_with_index do |disk, i|
        ret << "-drive id=disk#{i},file=#{disk_path(disk[:device])},if=none,format=raw"
        ret << "-device ide-drive,drive=disk#{i},bus=ahci.#{i}"
      end

      ret
    end

    def run_console_thread
      @console_thread = Thread.new do
        console_log = File.open(console_log_path, 'w')

        begin
          loop do
            rs, _ = IO.select([qemu])

            rs.each do |io|
              case io
              when qemu
                console_log.write(read_nonblock(qemu))
                console_log.flush
              end
            end
          end
        rescue EOFError
          console_log.close
          cleanup
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

    def wait_for_shell(timeout: TIMEOUT)
      return if shell_up?

      t1 = Time.now
      buffer = ''

      loop do
        if t1 + timeout < Time.now
          fail "Timeout occured while waiting for shell"
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
          return
        end
      end
    end

    def cleanup
      if console_thread && Thread.current != console_thread
        console_thread.join
        @console_thread = nil
      end

      @mutex.synchronize do
        if shell_server
          shell_server.close
          @shell_server = nil
        end

        if shell
          shell.close
          @shell = nil
        end

        File.unlink(shell_socket_path) if File.exist?(shell_socket_path)

        @running = false
        @shell_up = false
      end
    end

    def shell_socket_path
      File.join(tmpdir, "#{name}-shell.sock")
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
