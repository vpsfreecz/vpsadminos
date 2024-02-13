module SvCtl
  class Service
    attr_reader :name, :runlevel

    def initialize(name, runlevel)
      @name = name
      @runlevel = runlevel
    end

    def exist?
      Dir.exist?(src_path)
    end

    def enabled?
      File.symlink?(dst_path)
    end

    def enable
      File.symlink(src_path, dst_path)
    end

    def disable
      File.unlink(dst_path)
    end

    def runlevels
      ret = []

      SvCtl.runlevels.each do |v|
        ret << v if Dir.exist?(dst_path(v))
      end

      ret
    end

    def <=>(other)
      name <=> other.name
    end

    protected

    def src_path
      File.join(SvCtl::SERVICE_DIR, name)
    end

    def dst_path(runlevel = nil)
      File.join(SvCtl::RUNSVDIR, runlevel || self.runlevel, name)
    end
  end
end
