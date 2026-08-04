require 'fileutils'
require 'open3'
require 'pathname'
require 'securerandom'
require 'tmpdir'

module TestRunner
  class RepositorySource
    ROOT_DIRECTORY = 'os-test-runner-repository-sources'.freeze
    attr_reader :original_path, :path, :root_directory

    def self.open(original_path:, root_directory: nil, nixpkgs_path: nil, nix_system: nil)
      source = new(original_path:, root_directory:, nixpkgs_path:, nix_system:)
      source.open { yield(source) }
    end

    def initialize(original_path:, root_directory: nil, nixpkgs_path: nil, nix_system: nil)
      @original_path = File.expand_path(original_path)
      @root_directory = File.expand_path(root_directory || default_root_directory)
      @nixpkgs_path = File.expand_path(nixpkgs_path || ENV.fetch('TEST_RUNNER_NIXPKGS_PATH'))
      @nix_system = nix_system || ENV.fetch('TEST_RUNNER_NIX_SYSTEM')
      @path = nil
      @lock_file = nil
      @lock_path = nil
      @root_path = nil
    end

    def open
      FileUtils.mkdir_p(root_directory, mode: 0o700)
      reserve_gc_root
      @path = resolve_and_root_source

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

    def resolve_and_root_source
      out, status = Open3.capture2(
        'nix-build',
        '--out-link',
        @root_path,
        helper_file,
        '--arg',
        'repoRoot',
        original_path,
        '--arg',
        'nixpkgsPath',
        @nixpkgs_path,
        '--argstr',
        'nixSystem',
        @nix_system
      )

      unless status.success?
        raise "unable to resolve and GC-root repository source (#{status.exitstatus})"
      end

      output_path = out.lines.map(&:strip).reject(&:empty?).last
      raise 'nix-build returned no repository source output' if output_path.nil?

      File.realpath(File.join(output_path, 'source'))
    end

    def reserve_gc_root
      with_registry_lock do
        cleanup_stale_roots

        loop do
          token = "#{Process.pid}-#{SecureRandom.hex(8)}"
          @lock_path = File.join(root_directory, "#{token}.lock")
          @root_path = File.join(root_directory, "#{token}.root")

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
      return if @lock_path.nil? && @root_path.nil?

      with_registry_lock do
        unlink_gc_root(@root_path)

        @lock_file&.flock(File::LOCK_UN)
        @lock_file&.close
        @lock_file = nil

        File.unlink(@lock_path) if @lock_path && File.file?(@lock_path)
      end
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

    def default_root_directory
      runtime_dir = ENV.fetch('XDG_RUNTIME_DIR', nil)
      runtime_dir = Dir.tmpdir if runtime_dir.nil? || runtime_dir.empty?

      File.join(runtime_dir, "#{ROOT_DIRECTORY}-#{Process.uid}")
    end
  end
end
