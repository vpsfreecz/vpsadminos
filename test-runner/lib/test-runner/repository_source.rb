require 'fileutils'
require 'open3'
require 'pathname'
require 'test-runner/gc_root'
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
    end

    def open
      GcRoot.new(root_directory:).open do |root_path|
        @path = resolve_and_root_source(root_path)
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
