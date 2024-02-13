require 'libosctl'

module OsCtld
  # Create/destroy & attach/detach BPF programs for devices access control
  class Devices::V2::BpfProgram
    include OsCtl::Lib::Utils::Log

    # @return [String]
    attr_reader :name

    # Pin file path
    # @return [String]
    attr_reader :path

    # Create a new program
    #
    # The device list can be nil. In that case, the program cannot be loaded
    # into the kernel, because we don't know its contents, but we can still
    # create/destroy links or unload the program from the kernel.
    #
    # @param name [String]
    # @param devices [Array<Devices::Device>, nil]
    def initialize(name, devices)
      @name = name
      @devices = devices
      @path = BpfFs.prog_pin_path(name)
    end

    # Check if the program is loaded within the kernel
    def exist?
      BpfFs.prog_pinned?(@name)
    end

    # Load the program to the kernel
    def create
      if @devices.nil?
        raise 'unable to create incomplete program'
      end

      args = %W[
        -name #{@name}
        new
        #{path}
        allow
      ]

      @devices.each do |dev|
        args << "#{dev.type_s}:#{dev.major}:#{dev.minor}:#{dev.mode}"
      end

      run_devcgprog(*args)
    end

    def destroy
      File.unlink(path)
    end

    # Check if program is attached to a cgroup
    #
    # Note that even if this method returns `true`, the link may still be broken
    # if the underlying cgroup has been destroyed and recreated. We have no way
    # of verifying it using BPF FS.
    #
    # @param link [Devices::V2::BpfLink]
    def attached?(link)
      BpfFs.link_pinned?(link.pool_name, link.name)
    end

    # Attach program to cgroup
    # @param link [Devices::V2::BpfLink]
    def attach(link)
      run_devcgprog(
        'attach',
        path,
        link.cgroup_path,
        link.path
      )
    end

    # Atomically replace attached program with another program
    # @param link [Devices::V2::BpfLink]
    # @param new_link [Devices::V2::BpfLink]
    def replace(link, new_link)
      if link.pool_name != new_link.pool_name
        raise ArgumentError,
              "link on pool #{link.pool_name} while new_link on pool #{new_link.pool_name}"
      end

      run_devcgprog(
        'replace',
        link.path,
        BpfFs.prog_pin_path(new_link.prog_name),
        new_link.path
      )
    end

    # Detach program from cgroup
    # @param link [Devices::V2::BpfLink]
    def detach(link)
      File.unlink(link.path)
    end

    protected

    def run_devcgprog(*args)
      cmd = ['devcgprog'] + args

      log(:info, cmd.join(' '))
      pid = Process.spawn(*cmd)
      Process.wait(pid)

      if $?.exitstatus != 0
        raise "#{cmd.join(' ')} failed with exit status #{$?.exitstatus}"
      end

      nil
    end
  end
end
