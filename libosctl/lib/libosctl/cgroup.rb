module OsCtl::Lib
  module CGroup
    FS = '/sys/fs/cgroup'.freeze

    # @return [1, 2] cgroup hierarchy version
    def self.version
      return @version if @version

      @version = if File.exist?(File.join(FS, 'cgroup.procs'))
                   2
                 else
                   1
                 end

      @version
    end

    def self.v1?
      version == 1
    end

    def self.v2?
      version == 2
    end
  end
end
