module OsCtl::Lib
  module CGroup
    DEFAULT_FS = '/sys/fs/cgroup'.freeze
    RUNSTATE_FS = '/run/osctl/cgroup'.freeze
    RUNSTATE_VERSION = '/run/osctl/cgroup.version'.freeze
    INIT_MUTEX = Mutex.new

    # @return [1, 2] cgroup hierarchy version
    def self.version
      configuration.fetch(0)
    end

    def self.v1?
      version == 1
    end

    def self.v2?
      version == 2
    end

    def self.fs
      configuration.fetch(1)
    end

    def self.configuration
      cached = @configuration
      return cached if cached

      INIT_MUTEX.synchronize do
        @configuration ||= detect_configuration.freeze
      end
    end

    def self.runstate_version
      version = Integer(File.read(RUNSTATE_VERSION).strip)
      version if [1, 2].include?(version)
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      nil
    end

    def self.fs_version
      filesystem_version(fs) || 1
    end

    def self.detect_configuration
      expected_version = runstate_version

      if expected_version
        selected = [RUNSTATE_FS, DEFAULT_FS].find do |path|
          usable_fs?(path, expected_version)
        end
        return [expected_version, selected] if selected
      end

      # A stale or missing runstate version must never pair one hierarchy's
      # version with another hierarchy's path. Fall back to the public mount
      # and derive both values from that same layout.
      [filesystem_version(DEFAULT_FS) || 1, DEFAULT_FS]
    end

    def self.detect_fs(version)
      [RUNSTATE_FS, DEFAULT_FS].find do |path|
        usable_fs?(path, version)
      end || DEFAULT_FS
    end

    def self.usable_fs?(path, version)
      detected = filesystem_version(path)
      version.nil? ? !detected.nil? : detected == version
    rescue SystemCallError
      false
    end

    def self.filesystem_version(path)
      return unless Dir.exist?(path)
      return 2 if File.exist?(File.join(path, 'cgroup.procs'))
      return 1 if Dir.children(path).any?

      nil
    rescue SystemCallError
      nil
    end
  end
end
