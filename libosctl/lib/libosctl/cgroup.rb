module OsCtl::Lib
  module CGroup
    DEFAULT_FS = '/sys/fs/cgroup'.freeze
    RUNSTATE_FS = '/run/osctl/cgroup'.freeze
    FS = DEFAULT_FS
    RUNSTATE_VERSION = '/run/osctl/cgroup.version'.freeze

    # @return [1, 2] cgroup hierarchy version
    def self.version
      return @version if @version

      @version = runstate_version || fs_version

      @version
    end

    def self.v1?
      version == 1
    end

    def self.v2?
      version == 2
    end

    def self.fs
      @fs ||= detect_fs(@version)
    end

    def self.runstate_version
      version = Integer(File.read(RUNSTATE_VERSION).strip)
      return version if [1, 2].include?(version)
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      nil
    end

    def self.fs_version
      File.exist?(File.join(fs, 'cgroup.procs')) ? 2 : 1
    end

    def self.detect_fs(version)
      [RUNSTATE_FS, DEFAULT_FS].find do |path|
        usable_fs?(path, version)
      end || DEFAULT_FS
    end

    def self.usable_fs?(path, version)
      return false unless Dir.exist?(path)

      if version == 2
        File.exist?(File.join(path, 'cgroup.procs'))
      elsif version == 1
        Dir.children(path).any?
      else
        File.exist?(File.join(path, 'cgroup.procs')) || Dir.children(path).any?
      end
    rescue SystemCallError
      false
    end
  end
end
