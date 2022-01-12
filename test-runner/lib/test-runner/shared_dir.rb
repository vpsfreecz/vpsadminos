require 'fileutils'
require 'pathname'
require 'securerandom'

module TestRunner
  # {SharedDir} is used to push and pull files to and from machines
  class SharedDir
    # @return [Machine]
    attr_reader :machine

    # @return [String]
    attr_reader :fs_name

    # @return [String]
    attr_reader :host_path

    # @return [String]
    attr_reader :machine_mountpoint

    # @param machine [Machine]
    def initialize(machine)
      @machine = machine
      @fs_name = 'testRunnerSharedDir'
      @host_path = File.join(machine.send(:tmpdir), "shared-dir")
      @host_push = File.join(host_path, 'push')
      @host_pull = File.join(host_path, 'pull')
      @machine_mountpoint = '/run/test-runner/shared-dir'
      @machine_push = File.join(machine_mountpoint, 'push')
      @machine_pull = File.join(machine_mountpoint, 'pull')
    end

    # Create the shared directory on the host
    def setup
      FileUtils.mkpath(host_path)
      FileUtils.mkpath(host_push)
      FileUtils.mkpath(host_pull)
    end

    # Mount the shared directory within the machine
    def mount
      machine.all_succeed(
        "mkdir -p \"#{machine_mountpoint}\"",
        "mount -t virtiofs #{fs_name} \"#{machine_mountpoint}\"",
      )
    end

    # Destroy the shared directory on the host
    def destroy
      system('rm', '-rf', host_path) \
        || (fail "unable to delete shared directory at '#{host_path}'")
    end

    # Push file to the machine
    def push_file(src, dst, preserve: false)
      safe_name = path_to_safe_name(src)
      FileUtils.cp(src, File.join(host_push, safe_name), preserve: preserve)
      machine.succeeds("mv \"#{File.join(machine_push, safe_name)}\" \"#{dst}\"")
      dst
    end

    # Pull file from the machine
    def pull_file(src, preserve: false)
      safe_name = path_to_safe_name(src)
      opt = preserve ? '-p' : ''
      dst = File.join(machine_pull, safe_name)
      machine.succeeds("cp #{opt} \"#{src}\" \"#{dst}\"")
      File.join(host_pull, safe_name)
    end

    protected
    attr_reader :host_push, :host_pull, :machine_push, :machine_pull

    def path_to_safe_name(path)
      pn = Pathname.new(path)
      name = pn.cleanpath.to_s.sub(/^\//, '').gsub('/', '--')
      "#{SecureRandom.hex(4)}-#{name}"
    end
  end
end
