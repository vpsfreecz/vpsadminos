module OsCtl::Lib
  module CGroup
    FS = '/sys/fs/cgroup'

    # @return [1, 2] cgroup hierarchy version
    def self.version
      return @version if @version

      if File.exist?(File.join(FS, 'cgroup.procs'))
        @version = 2
      else
        @version = 1
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
