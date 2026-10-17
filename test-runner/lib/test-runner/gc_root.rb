require 'fileutils'
require 'securerandom'
require 'tmpdir'

module TestRunner
  # Invocation-owned indirect GC root, with flock-based stale-root recovery.
  class GcRoot
    attr_reader :path, :root_directory

    def initialize(root_directory:)
      @root_directory = File.expand_path(root_directory)
    end

    def open
      FileUtils.mkdir_p(root_directory, mode: 0o700)
      reserve_gc_root
      yield(path)
    ensure
      remove_gc_root
    end

    protected

    def reserve_gc_root
      with_registry_lock do
        cleanup_stale_roots

        loop do
          token = "#{Process.pid}-#{SecureRandom.hex(8)}"
          @lock_path = File.join(root_directory, "#{token}.lock")
          @path = File.join(root_directory, "#{token}.root")

          begin
            @lock_file = File.open(
              @lock_path,
              File::RDWR | File::CREAT | File::EXCL,
              0o600
            )
            break
          rescue Errno::EEXIST
            next
          end
        end

        @lock_file.flock(File::LOCK_EX)
      end
    end

    def remove_gc_root
      return if @lock_path.nil? && @path.nil?

      with_registry_lock do
        unlink_gc_root(@path)

        @lock_file&.flock(File::LOCK_UN)
        @lock_file&.close
        @lock_file = nil

        File.unlink(@lock_path) if @lock_path && File.file?(@lock_path)
      end
    rescue Errno::ENOENT
      nil
    ensure
      @lock_path = nil
      @path = nil
    end

    def cleanup_stale_roots
      Dir.glob(File.join(root_directory, '*.lock')).each do |lock_path|
        File.open(lock_path, File::RDWR) do |lock_file|
          next unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)

          unlink_gc_root(lock_path.sub(/\.lock\z/, '.root'))
          File.unlink(lock_path)
        end
      rescue Errno::ENOENT
        next
      end

      Dir.glob(File.join(root_directory, '*.root')).each do |root_path|
        lock_path = root_path.sub(/\.root\z/, '.lock')
        unlink_gc_root(root_path) unless File.exist?(lock_path)
      end
    end

    def with_registry_lock
      File.open(registry_lock_path, File::RDWR | File::CREAT, 0o600) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        yield
      ensure
        lock_file.flock(File::LOCK_UN)
      end
    end

    def unlink_gc_root(root_path)
      return if root_path.nil?
      return unless File.file?(root_path) || File.symlink?(root_path)

      File.unlink(root_path)
    rescue Errno::ENOENT
      nil
    end

    def registry_lock_path
      "#{root_directory}.lock"
    end
  end
end
