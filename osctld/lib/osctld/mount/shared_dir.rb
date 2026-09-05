require 'digest'
require 'libosctl'
require 'pathname'

module OsCtld
  class Mount::SharedDir
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def initialize(ct)
      @ct = ct
    end

    # Prepare the shared mount directory on the host
    def create
      dir = Pathname.new(path)

      unless dir.exist?
        dir.mkdir
        syscmd("mount --bind \"#{dir}\" \"#{dir}\"")
        syscmd("mount --make-rshared \"#{dir}\"")
      end

      create_readme unless File.exist?(readme_path)
    end

    # Remove the shared mount directory from the host
    def remove
      dir = Pathname.new(path)
      unmount(dir)
      FileUtils.rm_f(readme_path)
      prune_empty_child_directories(dir) if dir.exist?
      dir.rmdir if dir.exist?
    end

    # Propagate a new mount inside the container via the shared directory
    # @param mnt [Mount::Entry]
    def propagate(mnt)
      # Bind-mount the new mount into the shared directory
      host_path = host_path_for(mnt.mountpoint)

      Dir.mkdir(host_path)

      opts =
        if ct.map_mode == 'native' && mnt.map_ids
          "-o X-mount.idmap=/proc/#{ct.init_pid}/ns/user"
        end

      syscmd("mount --bind #{opts} \"#{mnt.fs}\" \"#{host_path}\"")

      # Move the mount inside the container to the right place
      begin
        ContainerControl::Commands::Mount.run!(
          ct,
          shared_dir: File.join('/', mountpoint),
          src: File.basename(host_path),
          dst: File.join('/', mnt.mountpoint)
        )
      rescue ContainerControl::Error => e
        log(:warn, ct, "Failed to mount #{mnt.mountpoint} at runtime: #{e.message}")
      end

      syscmd("umount \"#{host_path}\"")
      Dir.rmdir(host_path)
    end

    # Bind-mount path with ID-mapping and push it through the shared directory
    # @param dir [String]
    # @param user_ns [IO] opened user namespace of the LXC hook process
    # @param [String] path to the mountpoint, same in both init and ct mount namespaces
    def map_and_push(dir, user_ns)
      host_path = host_path_for(dir)
      user_ns_path = File.join('/proc', Process.pid.to_s, 'fd', user_ns.fileno.to_s)

      Dir.mkdir(host_path)
      syscmd_argv([
                    'mount',
                    '--bind',
                    '-o', "X-mount.idmap=#{user_ns_path}",
                    dir,
                    host_path
                  ])

      host_path
    end

    # Cleanup after {#map_and_push}
    # @param dir [String]
    def cleanup_pushed(dir)
      host_path = host_path_for(dir)

      syscmd("umount \"#{host_path}\"", valid_rcs: [32]) # 32 = not mounted

      begin
        Dir.rmdir(host_path)
      rescue Errno::ENOENT
        # pass
      end

      nil
    end

    # @return [String]
    def host_path_for(dir)
      File.join(path, Digest::SHA2.hexdigest(dir))
    end

    # @return [String]
    def path
      File.join(ct.pool.mount_dir, ct.id)
    end

    # Mountpoint relative to the container's rootfs
    # @return [String]
    def mountpoint
      'dev/.osctl-mount-helper'
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    protected

    attr_reader :ct

    def unmount(dir)
      return unless dir.exist?

      cmd = "umount -f \"#{dir}\""
      ret = syscmd(cmd, valid_rcs: :all)

      return if ret.success?
      return if ret.output.include?('not mounted')
      return if ret.output.include?('not found')
      return if ret.output.include?('no mount point specified')

      raise SystemCommandFailed.new(cmd, ret.exitstatus, ret.output)
    end

    def prune_empty_child_directories(dir)
      dir.children.each do |child|
        next unless File.lstat(child).directory?

        child.rmdir
        log(:warn, ct, "Removed stale empty shared mount directory #{child}")
      rescue Errno::ENOENT, Errno::ENOTEMPTY
        next
      end
    end

    def readme_path
      File.join(path, 'README.txt')
    end

    def create_readme
      File.write(
        readme_path,
        <<~END
          Directory `#{File.join('/', mountpoint)}` is used by osctl from vpsAdminOS to
          propagate new mounts into this container. Do not remove nor unmount this
          directory, or you'll have to restart your container to create new mounts!
        END
      )
    end
  end
end
