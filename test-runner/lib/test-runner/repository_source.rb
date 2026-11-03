require 'fileutils'
require 'open3'
require 'pathname'
require 'test-runner/gc_root'
require 'tmpdir'

module TestRunner
  class RepositorySource
    ROOT_DIRECTORY = 'os-test-runner-repository-sources'.freeze
    attr_reader :original_path, :path, :root_directory, :source_info

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
    end

    def open
      GcRoot.new(root_directory:).open do |root_path|
        git_identity = capture_git_identity
        @path = resolve_and_root_source(root_path)
        @source_info = snapshot_identity(git_identity)
        yield(self)
      end
    end

    def resolve_path(file_path)
      return nil if file_path.nil? || file_path.empty?

      expanded = File.expand_path(file_path, original_path)
      relative = Pathname.new(expanded).relative_path_from(Pathname.new(original_path))
      return expanded if relative.each_filename.first == '..'

      File.join(path, relative.to_s)
    end

    protected

    def capture_git_identity
      out, _err, status = Open3.capture3('git', '-C', original_path, 'rev-parse', '--show-toplevel', '--absolute-git-dir')
      return unless status.success?

      root, git_dir = out.lines.map(&:strip)
      return unless File.realpath(root) == File.realpath(original_path)

      revision, _err, status = Open3.capture3('git', '-C', original_path, 'rev-parse', '--verify', 'HEAD^{commit}')
      return unless status.success?

      [git_dir, revision.strip]
    rescue Errno::ENOENT
      nil
    end

    def snapshot_identity(git_identity)
      revision = git_identity&.last
      dirty = snapshot_dirty_state(*git_identity) if git_identity
      revision = nil if dirty.nil?

      {
        sourcePath: path,
        revision:,
        shortRev: revision&.slice(0, 7),
        dirty:
      }.freeze
    end

    def snapshot_dirty_state(git_dir, revision)
      Dir.mktmpdir('source-index-', root_directory) do |dir|
        env = { 'GIT_INDEX_FILE' => File.join(dir, 'index'), 'GIT_WORK_TREE' => path, 'GIT_DIR' => git_dir }
        git = ['git', '-c', 'core.filemode=true']
        _out, _err, status = Open3.capture3(env, *git, 'read-tree', revision)
        return nil unless status.success?

        # Refresh only this private index. Git compares captured bytes with the
        # captured commit, even if the live checkout or HEAD has since moved.
        _out, _err, status = Open3.capture3(env, *git, 'update-index', '-q', '--refresh')
        return nil unless [0, 1].include?(status.exitstatus)

        _out, _err, status = Open3.capture3(env, *git, 'diff-files', '--quiet', '--')
        return nil unless [0, 1].include?(status.exitstatus)
        return true unless status.success?

        # No --exclude-standard: ignored files included by the path snapshot
        # change its identity too. Git's own metadata is not source content.
        extra, _err, status = Open3.capture3(env, *git, 'ls-files', '--others', '--directory', '-z', '--', '.', ':!.git')
        return nil unless status.success?

        !extra.empty?
      end
    end

    def helper_file
      File.expand_path('../../nix/resolve-repository-source.nix', __dir__)
    end

    def resolve_and_root_source(root_path)
      out, status = Open3.capture2(
        'nix-build',
        '--out-link',
        root_path,
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

    def default_root_directory
      runtime_dir = ENV.fetch('XDG_RUNTIME_DIR', nil)
      runtime_dir = Dir.tmpdir if runtime_dir.nil? || runtime_dir.empty?

      File.join(runtime_dir, "#{ROOT_DIRECTORY}-#{Process.uid}")
    end
  end
end
