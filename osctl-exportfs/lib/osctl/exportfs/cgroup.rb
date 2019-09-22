require 'fileutils'

module OsCtl::ExportFS
  class CGroup
    FS = '/sys/fs/cgroup'

    # @return [String]
    attr_reader :controller

    # @return [String]
    attr_reader :path

    # @param controller [String]
    # @param path [String] cgroup name
    def initialize(controller, path)
      @controller = controller
      @path = path
    end

    # @param name [String] cgroup name
    def create(name)
      FileUtils.mkdir_p(File.join(FS, controller, path, name))
    end

    # @param name [String] cgroup name
    def destroy(name)
      Dir.rmdir(File.join(FS, controller, path, name))
    end

    # @param name [String] cgroup name
    def enter(name)
      File.open(proc_list(name), 'w') do |f|
        f.write(Process.pid)
      end
    end

    # @param name [String] cgroup name
    # @return [Integer] number of killed processes
    def kill_all(name)
      killed = 0

      File.open(proc_list(name)) do |f|
        f.each_line do |line|
          pid = line.strip.to_i

          begin
            killed += 1
            Process.kill('TERM', pid)
          rescue Errno::ESRCH
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
      File.join(FS, controller, path, name, 'cgroup.procs')
    end
  end
end
