require 'libosctl'
require 'json'
require 'io/wait'
require 'tmpdir'
require 'osctld/switch_user'

module OsCtld
  # Namespace handles belong to one container run, not a reusable PID. Never
  # follow tenant mount paths or use the tenant's potentially replaced /sys.
  class Container::NfsCancellation
    include OsCtl::Lib::Utils::Log

    NS_GET_USERNS = 0xb701
    NS_GET_PARENT = 0xb702
    PF_EXITING = 0x00000004
    WORKER_TIMEOUT = 30
    MAX_WORKER_OUTPUT = 65_536

    class WorkerTimeout < StandardError; end

    def initialize(ct, proc_root: '/proc')
      # Run identity is immutable. Never acquire the container lock while
      # holding @mutex: Container#stopped closes this object under that lock.
      @ident = ct.ident.dup.freeze
      @payload = File.join('/', ct.cgroup_path, "lxc.payload.#{ct.id}").freeze
      @payload_prefix = "#{@payload}/".freeze
      @proc_root = proc_root
      @mutex = Mutex.new
      @owner = nil
      @netns = {}
      @init_proc = nil
      @exit_cancelled = false
      @closed = false
    end

    def capture(pid)
      return if pid.nil?

      @mutex.synchronize do
        return if @closed

        with_process(pid) do |path, dir|
          next unless member?(path)

          File.open(File.join(path, 'ns/user')) do |userns|
            next if same_namespace?(userns, File.stat(File.join(@proc_root, 'self/ns/user')))
            next if @owner && !same_namespace?(userns, @owner.stat)

            @owner ||= userns.dup
            capture_netns(path)
            retain_init(path, dir)
          end
        end
      end
      nil
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end

    # The caller must quiesce tenant work before requesting terminal abort.
    # Retained handles remain usable even after init's /proc entry disappears.
    def abort
      @mutex.synchronize { abort_locked }
    end

    # PID1 can block in exit_files(), before LXC emits STOPPING. A retained
    # proc directory identifies the original task even if its PID is reused.
    def abort_if_exiting
      @mutex.synchronize do
        return 0 if @exit_cancelled || !@init_proc

        path = File.join(@proc_root, 'self/fd', @init_proc.fileno.to_s)
        return 0 unless init_exiting?(path)

        count = abort_locked
        @exit_cancelled = true
        count
      end
    end

    def close
      @mutex.synchronize do
        @closed = true
        @netns.each_value(&:close)
        @netns.clear
        @owner&.close
        @owner = nil
        @init_proc&.close
        @init_proc = nil
      end
    end

    def log_type
      "nfs-cancel=#{@ident}"
    end

    protected

    def with_process(pid)
      File.open(File.join(@proc_root, pid.to_s)) do |dir|
        yield File.join(@proc_root, 'self/fd', dir.fileno.to_s), dir
      end
    end

    def abort_locked
      return 0 unless @owner

      cancel_in_worker
    end

    def retain_init(path, dir)
      return if @init_proc

      nspid = File.foreach(File.join(path, 'status')).find { |line| line.start_with?('NSpid:') }
      return unless nspid&.split&.last == '1'

      @init_proc = dir.dup
    end

    def init_exiting?(path)
      # The group leader can call pthread_exit while another init thread
      # keeps the namespace alive. Require every remaining thread to exit.
      Dir.children(File.join(path, 'task')).all? do |tid|
        stat = File.read(File.join(path, 'task', tid, 'stat'))
        fields = stat[(stat.rindex(')') + 1)..].split
        # stat field 9 is flags; the fields array starts at field 3 (state).
        Integer(fields.fetch(6)).anybits?(PF_EXITING)
      rescue Errno::ENOENT, Errno::ESRCH
        true
      end
    rescue Errno::ENOENT, Errno::ESRCH
      # Init vanished before we sampled PF_EXITING; its retained namespaces
      # may still be held by the LXC monitor or detached mounts.
      true
    end

    def member?(path)
      File.foreach(File.join(path, 'cgroup')).any? do |line|
        _id, controllers, cgroup = line.strip.split(':', 3)
        next false unless controllers == '' || controllers&.split(',')&.include?('freezer')

        cgroup == @payload || cgroup&.start_with?(@payload_prefix)
      end
    end

    def same_namespace?(io, stat)
      actual = io.stat
      actual.dev == stat.dev && actual.ino == stat.ino
    end

    def owned_network_namespace?(netns)
      owner = IO.for_fd(netns.ioctl(NS_GET_USERNS))
      begin
        loop do
          return true if same_namespace?(owner, @owner.stat)

          parent = IO.for_fd(owner.ioctl(NS_GET_PARENT))
          owner.close
          owner = parent
        end
      rescue Errno::EPERM
        false
      ensure
        owner.close
      end
    end

    def capture_netns(path)
      File.open(File.join(path, 'ns/net')) do |netns|
        next unless owned_network_namespace?(netns)

        stat = netns.stat
        @netns[[stat.dev, stat.ino]] ||= netns.dup
      end
    end

    def capture_descendants
      Dir.foreach(@proc_root) do |entry|
        next unless /\A[0-9]+\z/.match?(entry)

        begin
          with_process(entry) do |path|
            # setns() is per-thread. The group leader need not use the
            # network namespace containing another thread's NFS client.
            Dir.children(File.join(path, 'task')).each do |tid|
              thread_path = File.join(path, 'task', tid)
              begin
                capture_netns(thread_path) if member?(thread_path)
              rescue Errno::ENOENT, Errno::ESRCH
                next
              end
            end
          end
        rescue Errno::ENOENT, Errno::ESRCH
          next
        end
      end
    end

    def cancel_in_worker
      reader, writer = IO.pipe
      pid = SwitchUser.fork(keep_fds: [writer, @owner, *@netns.values].compact) do
        Process.setproctitle("osctld: #{@ident} NFS cancellation")
        # Bound the process/thread scan with the same deadline as sysfs work.
        # Newly discovered handles need live only until this worker exits.
        capture_descendants
        writer.puts(JSON.generate(count: cancel_namespaces))
        exit!(true)
      rescue StandardError => e
        writer.puts(JSON.generate(error: "#{e.class}: #{e.message}"))
        exit!
      end
      writer.close
      deadline = monotonic_time + WORKER_TIMEOUT
      output = read_worker_output(reader, deadline)
      status = wait_for_worker(pid, deadline)
      pid = nil
      result = JSON.parse(output, symbolize_names: true)
      raise "NFS cancellation failed: #{result[:error]}" unless status.success?

      result.fetch(:count)
    ensure
      reader&.close
      writer&.close unless writer&.closed?
      terminate_worker(pid) if pid
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def worker_time_left(deadline)
      left = deadline - monotonic_time
      raise WorkerTimeout, 'NFS cancellation worker timed out' unless left > 0

      left
    end

    def read_worker_output(reader, deadline)
      output = +''
      loop do
        left = worker_time_left(deadline)
        chunk = reader.read_nonblock(4096, exception: false)
        case chunk
        when nil
          return output
        when :wait_readable
          reader.wait_readable(left)
        else
          output << chunk
          raise 'NFS cancellation worker output is too large' if output.bytesize > MAX_WORKER_OUTPUT
        end
      end
    end

    def wait_for_worker(pid, deadline)
      loop do
        result = Process.wait2(pid, Process::WNOHANG)
        return result.last if result

        sleep([worker_time_left(deadline), 0.05].min)
      end
    end

    def terminate_worker(pid)
      # An unreaped child keeps its PID reserved. Never signal a reaped PID.
      return if Process.wait2(pid, Process::WNOHANG)

      Process.kill('KILL', pid)
      # A broken kernel path might remain uninterruptible. Reap asynchronously
      # rather than turn the error/timeout path into another unbounded wait.
      Process.detach(pid)
    rescue Errno::ECHILD
      nil
    end

    def cancel_namespaces
      sys = OsCtl::Lib::Sys.new
      sys.unshare_ns(OsCtl::Lib::Sys::CLONE_NEWNS)
      sys.make_rslave('/')
      count = 0

      Dir.mktmpdir('nfs-cancel-', '/run/osctl') do |mountpoint|
        @netns.each_value do |netns|
          sys.setns_io(netns, OsCtl::Lib::Sys::CLONE_NEWNET)
          sys.mount_sysfs(mountpoint)
          begin
            count += cancel_namespace(File.join(mountpoint, 'fs/nfs'), subtree: root_network_namespace?(netns))
          ensure
            sys.unmount(mountpoint)
          end
        end
      end
      count
    end

    def root_network_namespace?(netns)
      owner = IO.for_fd(netns.ioctl(NS_GET_USERNS))
      same_namespace?(owner, @owner.stat)
    ensure
      owner&.close
    end

    def cancel_namespace(path, subtree: false)
      return 0 unless Dir.exist?(path)

      tree_control = File.join(path, 'net/nfs_client/shutdown_tree')
      if subtree && File.exist?(tree_control)
        # Only select the authenticated run owner, never an ancestor reached
        # through an inherited host namespace or a tenant-controlled path.
        File.open(tree_control, File::WRONLY) { |f| f.write("1\n") }
        return 1
      end

      control = File.join(path, 'net/nfs_client/shutdown')
      if File.exist?(control)
        # Sticky shutdown covers initializing mounts and future RPC clients.
        File.open(control, File::WRONLY) { |f| f.write("1\n") }
        return 1
      end

      # Older kernels still enforce soft mounts and lack the admission barrier.
      cancel_filesystems(path)
    end

    def cancel_filesystems(path)
      return 0 unless Dir.exist?(path)

      count = 0
      Dir.children(path).each do |name|
        next unless /\A(?:[0-9]+:[0-9]+|server-[0-9]+)\z/.match?(name)

        begin
          File.open(File.join(path, name, 'shutdown'), File::WRONLY) { |f| f.write("1\n") }
          count += 1
        rescue Errno::ENOENT
          next
        end
      end
      count
    end
  end
end
