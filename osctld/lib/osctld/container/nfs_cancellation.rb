require 'libosctl'
require 'json'
require 'io/wait'
require 'tmpdir'
require 'osctld/switch_user'
require 'osctld/container/nfs_cancellation_state'

module OsCtld
  # The original namespace root belongs to a run, never to a reusable PID.
  # Only the authenticated pre-mount hook may establish that root.
  class Container::NfsCancellation
    include OsCtl::Lib::Utils::Log

    NS_GET_USERNS = 0xb701
    NS_GET_NSTYPE = 0xb703
    PF_EXITING = 0x00000004
    WORKER_TIMEOUT = 30
    MAX_WORKER_OUTPUT = 65_536
    TREE_CONTROL = '/sys/fs/nfs/net/nfs_client/shutdown_tree'.freeze

    class WorkerTimeout < StandardError; end

    def initialize(ct, run_id:, proc_root: '/proc', state_root: Container::NfsCancellationState::ROOT)
      @ident = ct.ident.dup.freeze
      @payload = File.join('/', ct.cgroup_path, "lxc.payload.#{ct.id}").freeze
      @payload_prefix = "#{@payload}/".freeze
      @proc_root = proc_root
      @mutex = OsCtl::Lib::Mutex.new
      @state = Container::NfsCancellationState.new(run_id, @payload, root: state_root)
      @owner = nil
      @netns = nil
      @init_proc = nil
      @init_identity = nil
      @terminal = false
      @completed = false
      @closed = false
      @worker = nil
      @retry_at = 0
      restore
    end

    def capture(pid, trusted: false, deadline: nil)
      return if pid.nil?

      @mutex.synchronize(lock_wait(deadline)) do
        return if @closed || @invalid_state
        return unless @owner || trusted

        with_process(pid) do |path, dir|
          next unless member?(path)

          File.open(File.join(path, 'ns/user')) do |userns|
            next if initial_user_namespace?(userns)
            next if @owner && !same_namespace?(userns, @owner.stat)

            unless @owner
              File.open(File.join(path, 'ns/net')) do |netns|
                next unless root_network_namespace?(netns, userns)

                @state.pin(userns, netns, deadline:)
                @owner = userns.dup
                @netns = netns.dup
              end
            end
            next unless @owner

            retain_init(path, dir, deadline:)
            # The hook is a child of the future init. Capture its identity
            # before tenant code can change namespaces or enter exit_files().
            capture_parent_init(path, deadline:) if trusted && !@init_identity
          end
        end
      end
      nil
    rescue StandardError => e
      log(:warn, "Unable to retain NFS cancellation namespaces: #{e.message}")
      nil
    end

    # Cancellation is optional. Never wait longer than the caller's head start,
    # and never hold the object mutex while waiting for a worker.
    def abort(wait: 0, deadline: nil)
      return 0 unless supported?

      deadline ||= monotonic_time + wait
      task = @mutex.synchronize(lock_wait(deadline)) do
        return 0 if @closed || @completed || @invalid_state

        unless @owner && @netns
          unless @unavailable_logged
            log(:warn, 'NFS cancellation unavailable: original run namespaces were not retained')
            @unavailable_logged = true
          end
          return 0
        end

        @terminal = true
        @state.update({ 'terminal' => true }, deadline:)
        if @worker&.alive?
          @worker
        elsif monotonic_time >= @retry_at
          owner = @owner.dup
          netns = @netns.dup
          @worker = Thread.new { perform_cancellation(owner, netns) }
        end
      end

      return 0 unless task

      task.join(lock_wait(deadline)) if wait > 0
      @mutex.synchronize(lock_wait(deadline)) { @completed ? 1 : 0 }
    rescue StandardError => e
      log(:warn, "Unable to request NFS cancellation: #{e.message}")
      0
    end

    def abort_if_exiting
      exiting = @mutex.synchronize(0) do
        next false if @closed || @completed
        next true if @terminal
        next false unless @init_identity

        restore_init unless @init_proc
        !@init_proc || init_exiting?(File.join(@proc_root, 'self/fd', @init_proc.fileno.to_s))
      end
      exiting ? abort : 0
    rescue OsCtl::Lib::Mutex::Timeout
      0
    end

    # Called only when the container run has stopped, not on daemon shutdown.
    def close(deadline: nil)
      @mutex.synchronize(lock_wait(deadline)) do
        @closed = true
        [@owner, @netns, @init_proc].compact.each(&:close)
        @owner = @netns = @init_proc = nil
        @state.retire(deadline:)
      end
    rescue StandardError => e
      log(:warn, "Unable to release NFS cancellation state: #{e.message}")
    end

    def log_type
      "nfs-cancel=#{@ident}"
    end

    protected

    def lock_wait(deadline)
      deadline && [deadline - monotonic_time, 0].max
    end

    def supported?
      # Do not retain a negative result: NFS can be loaded after daemon startup.
      File.exist?(TREE_CONTROL)
    end

    def restore
      record = @state.load
      return unless record

      if record['retired']
        @closed = true
        @state.cleanup
        return
      end

      return unless record['namespaces'] # Interrupted pre-mount preparation.

      owner = @state.open_namespace('user', record.fetch('namespaces').fetch('user'))
      netns = @state.open_namespace('net', record.fetch('namespaces').fetch('net'))
      if owner.ioctl(NS_GET_NSTYPE) != OsCtl::Lib::Sys::CLONE_NEWUSER ||
         netns.ioctl(NS_GET_NSTYPE) != OsCtl::Lib::Sys::CLONE_NEWNET ||
         initial_user_namespace?(owner) || !root_network_namespace?(netns, owner)
        raise Container::NfsCancellationState::InvalidState, 'invalid namespace ownership'
      end

      @owner = owner
      @netns = netns
      @init_identity = record['init']
      @terminal = record['terminal'] == true
      @completed = record['completed'] == true
      restore_init
    rescue StandardError => e
      owner&.close
      netns&.close
      @owner = @netns = nil
      @invalid_state = true
      log(:warn, "Unable to restore NFS cancellation state: #{e.message}")
    end

    def with_process(pid)
      File.open(File.join(@proc_root, pid.to_s)) do |dir|
        yield File.join(@proc_root, 'self/fd', dir.fileno.to_s), dir
      end
    end

    def process_stat(path)
      stat = File.read(File.join(path, 'stat'))
      [Integer(stat.split(' ', 2).first), stat[(stat.rindex(')') + 1)..].split]
    end

    def process_identity(path)
      pid, fields = process_stat(path)
      { 'pid' => pid, 'start_time' => fields.fetch(19) }
    end

    def retain_init(path, dir, deadline: nil)
      return if @init_proc

      nspid = File.foreach(File.join(path, 'status')).find { |line| line.start_with?('NSpid:') }
      return unless nspid&.split&.last == '1'

      identity = process_identity(path)
      return if @init_identity && @init_identity != identity

      @state.update({ 'init' => identity }, deadline:)
      @init_identity = identity
      @init_proc = dir.dup
    end

    def capture_parent_init(path, deadline: nil)
      _pid, fields = process_stat(path)
      with_process(Integer(fields.fetch(1))) do |parent_path, dir|
        next unless member?(parent_path)

        File.open(File.join(parent_path, 'ns/user')) do |userns|
          retain_init(parent_path, dir, deadline:) if same_namespace?(userns, @owner.stat)
        end
      end
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end

    def restore_init
      return unless @init_identity

      with_process(@init_identity.fetch('pid')) do |path, dir|
        # A live proc-directory handle then protects against subsequent reuse.
        @init_proc = dir.dup if process_identity(path) == @init_identity && member?(path)
      end
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end

    def init_exiting?(path)
      # pthread_exit by the group leader alone is not container termination.
      Dir.children(File.join(path, 'task')).all? do |tid|
        _pid, fields = process_stat(File.join(path, 'task', tid))
        Integer(fields.fetch(6)).anybits?(PF_EXITING)
      rescue Errno::ENOENT, Errno::ESRCH
        true
      end
    rescue Errno::ENOENT, Errno::ESRCH
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

    def initial_user_namespace?(userns)
      same_namespace?(userns, File.stat(File.join(@proc_root, 'self/ns/user')))
    end

    def root_network_namespace?(netns, userns)
      owner = IO.for_fd(netns.ioctl(NS_GET_USERNS))
      same_namespace?(owner, userns.stat)
    ensure
      owner&.close
    end

    def perform_cancellation(owner, netns)
      count = cancel_in_worker(owner, netns)
      @mutex.synchronize do
        @completed = count > 0
        @retry_at = monotonic_time + WORKER_TIMEOUT unless @completed
      end
    rescue StandardError => e
      @mutex.synchronize { @retry_at = monotonic_time + WORKER_TIMEOUT }
      log(:warn, "NFS cancellation failed: #{e.message}")
    ensure
      owner.close
      netns.close
      @state.cleanup if @mutex.synchronize { @closed }
    end

    def cancel_in_worker(owner, netns)
      worker_lock = @state.claim_worker
      return 0 unless worker_lock

      # Another daemon's worker may have completed since our state was loaded.
      return 1 if @state.load&.fetch('completed', false)

      reader, writer = IO.pipe
      deadline = monotonic_time + WORKER_TIMEOUT
      pid = SwitchUser.fork(keep_fds: [writer, owner, netns, worker_lock]) do
        Process.setproctitle("osctld: #{@ident} NFS cancellation")
        count = cancel_namespace(netns)
        @state.update({ 'completed' => true }, deadline:) if count > 0
        writer.puts(JSON.generate(count:))
        exit!(true)
      rescue StandardError => e
        writer.puts(JSON.generate(error: "#{e.class}: #{e.message}"))
        exit!
      end
      worker_lock.close
      worker_lock = nil
      writer.close
      output = read_worker_output(reader, deadline)
      status = wait_for_worker(pid, deadline)
      pid = nil
      result = JSON.parse(output, symbolize_names: true)
      raise "NFS cancellation failed: #{result[:error]}" unless status.success?

      result.fetch(:count)
    ensure
      reader&.close
      writer&.close unless writer&.closed?
      worker_lock&.close
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
      return if Process.wait2(pid, Process::WNOHANG)

      Process.kill('KILL', pid)
      # An uninterruptible child must not turn timeout handling into a wait.
      # Its inherited worker lock remains held until it actually exits.
      reaper = Process.detach(pid)
      Thread.new do
        reaper.join
        @state.cleanup if @mutex.synchronize { @closed }
      rescue StandardError => e
        log(:warn, "Unable to release retired NFS cancellation state: #{e.message}")
      end
    rescue Errno::ECHILD
      nil
    end

    def cancel_namespace(netns)
      sys = OsCtl::Lib::Sys.new
      sys.unshare_ns(OsCtl::Lib::Sys::CLONE_NEWNS)
      sys.make_rslave('/')
      sys.setns_io(netns, OsCtl::Lib::Sys::CLONE_NEWNET)

      Dir.mktmpdir('nfs-cancel-', '/run/osctl') do |mountpoint|
        sys.mount_sysfs(mountpoint)
        begin
          control = File.join(mountpoint, 'fs/nfs/net/nfs_client/shutdown_tree')
          return 0 unless File.exist?(control)

          File.open(control, File::WRONLY) { |f| f.write("1\n") }
          1
        ensure
          sys.unmount(mountpoint)
        end
      end
    end
  end
end
