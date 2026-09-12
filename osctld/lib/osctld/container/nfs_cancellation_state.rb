require 'digest'
require 'json'
require 'tempfile'
require 'libosctl'

module OsCtld
  # Namespace bind mounts outlive the daemon, but belong to exactly one run.
  # Keep this outside config.yml: older daemons can still load that file.
  class Container::NfsCancellationState
    ROOT = '/run/osctl/nfs-cancellation'.freeze
    SCHEMA = 1

    class InvalidState < StandardError; end
    class LockTimeout < StandardError; end

    attr_reader :dir

    def self.prune_retired
      return unless File.directory?(ROOT)

      Dir.children(ROOT).each do |name|
        next unless /\A[0-9a-f]{64}\z/.match?(name)

        begin
          record = File.open(File.join(ROOT, name, 'state.json'), File::RDONLY | File::NOFOLLOW) do |io|
            JSON.parse(io.read(65_537))
          end
          next unless record['retired']

          run_id = Container::RunId.load(record.fetch('run_id'))
          state = new(run_id, record.fetch('payload'))
          next unless File.basename(state.dir) == name

          state.cleanup
        rescue StandardError => e
          OsCtl::Lib::Logger.log(:warn, "Unable to clean retired NFS cancellation state: #{e.message}")
        end
      end
    end

    def initialize(run_id, payload, root: ROOT, boot_id: nil)
      @identity = {
        'schema' => SCHEMA,
        'boot_id' => boot_id || File.read('/proc/sys/kernel/random/boot_id').strip,
        'run_id' => run_id.dump,
        'payload' => payload
      }
      @root = root
      @dir = File.join(root, Digest::SHA256.hexdigest(run_id.to_s))
    end

    def load
      return unless File.exist?(dir)

      check_directory(dir)
      read_record
    end

    # Publish only after both namespace mounts have been verified. A failed
    # pre-mount attempt can reuse its own partially prepared pins.
    def pin(owner, netns, deadline: nil)
      prepare
      with_lock(deadline:) do
        record = read_record || @identity.dup
        raise InvalidState, 'container run has already stopped' if record['retired']

        write_record(record) # Make interrupted preparation recognizable.

        { 'user' => owner, 'net' => netns }.each do |name, io|
          pin_namespace(name, io)
        end
        record['namespaces'] = {
          'user' => namespace_identity(owner),
          'net' => namespace_identity(netns)
        }
        write_record(record)
        record
      end
    end

    def open_namespace(name, identity)
      raise InvalidState, 'invalid namespace name' unless %w[user net].include?(name)

      io = File.open(File.join(dir, name), File::RDONLY | File::NOFOLLOW)
      unless namespace_identity(io) == identity
        io.close
        raise InvalidState, 'namespace pin does not match the container run'
      end
      io
    end

    def update(values, deadline: nil)
      return unless File.exist?(dir)

      with_lock(deadline:) do
        record = read_record
        return unless record

        write_record(record.merge(values))
      end
    end

    # The worker inherits this lock. Even if the daemon dies, a stuck worker
    # prevents a replacement daemon from spawning another one for the run.
    def claim_worker
      return unless File.exist?(dir)

      check_directory(dir)
      io = File.open(File.join(dir, 'worker.lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
      return io if io.flock(File::LOCK_EX | File::LOCK_NB)

      io.close
      nil
    end

    def retire(deadline: nil)
      update({ 'retired' => true }, deadline:)
      cleanup(deadline:)
    end

    def cleanup(deadline: nil)
      return true unless File.exist?(dir)

      worker_lock = claim_worker
      return false unless worker_lock

      with_lock(deadline:) do
        record = read_record
        return false unless record && record['retired']

        %w[user net].each do |name|
          path = File.join(dir, name)
          next unless File.exist?(path)

          begin
            OsCtl::Lib::Sys.new.unmount(path)
          rescue Errno::EINVAL
            # An interrupted pin operation can leave an empty mount target.
          end
          File.unlink(path)
        end
        %w[state.json worker.lock lock].each do |name|
          File.unlink(File.join(dir, name))
        end
        Dir.rmdir(dir)
      end
      true
    ensure
      worker_lock&.close
    end

    protected

    def prepare
      [@root, dir].each do |path|
        begin
          Dir.mkdir(path, 0o700)
        rescue Errno::EEXIST
          # Never trust an existing path solely because its name matches.
        end
        check_directory(path)
      end
    end

    def check_directory(path)
      stat = File.lstat(path)
      return if stat.directory? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o700

      raise InvalidState, 'unsafe NFS cancellation state directory'
    end

    def with_lock(deadline: nil)
      check_directory(dir)
      File.open(File.join(dir, 'lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |io|
        if deadline
          until io.flock(File::LOCK_EX | File::LOCK_NB)
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise LockTimeout, 'NFS cancellation state is busy' unless remaining > 0

            sleep([remaining, 0.01].min)
          end
        else
          io.flock(File::LOCK_EX)
        end
        yield
      end
    end

    def read_record
      record = File.open(File.join(dir, 'state.json'), File::RDONLY | File::NOFOLLOW) do |io|
        JSON.parse(io.read(65_537))
      end
      unless record.is_a?(Hash) && @identity.all? { |key, value| record[key] == value }
        raise InvalidState, 'NFS cancellation state belongs to another run or boot'
      end

      record
    rescue Errno::ENOENT
      nil
    end

    def write_record(record)
      Tempfile.create(['state-', '.json'], dir) do |io|
        io.write(JSON.generate(record))
        io.flush
        File.rename(io.path, File.join(dir, 'state.json'))
      end
    end

    def namespace_identity(io)
      stat = io.stat
      [stat.dev, stat.ino]
    end

    def pin_namespace(name, io)
      target = File.join(dir, name)
      File.open(target, File::RDONLY | File::CREAT | File::NOFOLLOW, 0o600) do |existing|
        return true if namespace_identity(existing) == namespace_identity(io)

        begin
          existing.ioctl(0xb703) # NS_GET_NSTYPE
          raise InvalidState, 'conflicting namespace pin'
        rescue Errno::ENOTTY
          # A regular file has no namespace type.
        end

        # A regular empty file is the only acceptable unfinished mount target.
        # Never replace an existing namespace pin with a different namespace.
        stat = existing.stat
        unless stat.file? && stat.uid == Process.euid && stat.zero? && stat.nlink == 1 # rubocop:disable Style/NumericPredicate -- File::Stat predicate
          raise InvalidState, 'conflicting namespace pin'
        end
      end
      OsCtl::Lib::Sys.new.bind_mount("/proc/self/fd/#{io.fileno}", target)
      pinned = open_namespace(name, namespace_identity(io))
      pinned.close
    end
  end
end
