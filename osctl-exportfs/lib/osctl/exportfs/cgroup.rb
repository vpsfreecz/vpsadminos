require 'fileutils'
require 'libosctl'

module OsCtl::ExportFS
  class CGroup
    # @return [String]
    attr_reader :path

    # @return [String]
    def self.fs
      OsCtl::Lib::CGroup.fs
    end

    # @param path [String] cgroup name
    def initialize(path)
      @path = path
    end

    # @param name [String] cgroup name
    def create(name)
      FileUtils.mkdir_p(abs_cgroup_path(name))
    end

    # @param name [String] cgroup name
    def destroy(name)
      Dir.rmdir(abs_cgroup_path(name))
    end

    # @param name [String] cgroup name
    def enter(name)
      File.write(proc_list(name), Process.pid)
    end

    # @param name [String] cgroup name
    # @return [Integer] number of killed processes
    def kill_all(name)
      killed = 0

      File.open(proc_list(name)) do |f|
        f.each_line do |line|
          pid = line.strip.to_i

          begin
            Process.kill('TERM', pid)
            killed += 1
          rescue Errno::ESRCH
            # ignore
          end
        end
      end

      killed
    end

    # @param name [String] cgroup name
    def kill_all_until_empty(name)
      loop do
        break if kill_all(name) == 0

        sleep(3)
      end
    end

    protected

    def proc_list(name)
      abs_cgroup_path(name, 'cgroup.procs')
    end

    def abs_cgroup_path(*names)
      args = [self.class.fs]
      args << 'systemd' unless OsCtl::Lib::CGroup.v2?
      args << path
      args.concat(names)
      File.join(*args)
    end
  end
end
