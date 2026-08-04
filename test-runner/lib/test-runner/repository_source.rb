require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'securerandom'

module TestRunner
  class RepositorySource
    ROOT_DIRECTORY = '.repository-sources'.freeze

    attr_reader :original_path, :path

    def self.open(original_path:, state_dir:)
      source = new(original_path:, state_dir:)
      source.open { yield(source) }
    end

    def initialize(original_path:, state_dir:)
      @original_path = File.expand_path(original_path)
      @state_dir = File.expand_path(state_dir)
      @path = nil
      @lock_file = nil
      @lock_path = nil
      @root_path = nil
    end

    def open
      FileUtils.mkdir_p(root_directory)
      cleanup_stale_roots

      @path = resolve_source
      create_gc_root

      yield(self)
    ensure
      remove_gc_root
    end

    def resolve_path(file_path)
      return nil if file_path.nil? || file_path.empty?

      expanded = File.expand_path(file_path, original_path)
      relative = Pathname.new(expanded).relative_path_from(Pathname.new(original_path))
      return expanded if relative.each_filename.first == '..'

      File.join(path, relative.to_s)
    end

    protected

    def helper_file
      File.expand_path('../../nix/resolve-repository-source.nix', __dir__)
    end

    def resolve_source
      out, status = Open3.capture2(
        'nix-instantiate',
        '--eval',
        '--strict',
        '--json',
        helper_file,
        '--arg',
        'repoRoot',
        original_path
      )

      unless status.success?
        raise "unable to resolve repository source (#{status.exitstatus})"
      end

      JSON.parse(out)
    end

    def create_gc_root
      token = "#{Process.pid}-#{SecureRandom.hex(8)}"
      @lock_path = File.join(root_directory, "#{token}.lock")
      @root_path = File.join(root_directory, "#{token}.root")
      @lock_file = File.open(@lock_path, File::RDWR | File::CREAT, 0o600)
      @lock_file.flock(File::LOCK_EX)

      _out, status = Open3.capture2e(
        'nix-store',
        '--realise',
        path,
        '--add-root',
        @root_path,
        '--indirect'
      )

      return if status.success?

      raise "unable to GC-root repository source (#{status.exitstatus})"
    end

    def remove_gc_root
      unlink_gc_root(@root_path)

      @lock_file&.flock(File::LOCK_UN)
      @lock_file&.close
      @lock_file = nil

      File.unlink(@lock_path) if @lock_path && File.file?(@lock_path)
    rescue Errno::ENOENT
      nil
    ensure
      @lock_path = nil
      @root_path = nil
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

    def unlink_gc_root(root_path)
      return if root_path.nil?
      return unless File.file?(root_path) || File.symlink?(root_path)

      File.unlink(root_path)
    rescue Errno::ENOENT
      nil
    end

    def root_directory
      File.join(@state_dir, ROOT_DIRECTORY)
    end
  end
end
