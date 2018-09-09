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
      syscmd("umount -f \"#{dir}\"", valid_rcs: [32]) # 32 = not mounted
      File.unlink(readme_path) if File.exist?(readme_path)
      dir.rmdir if dir.exist?
    end

    # Propagate a new mount inside the container via the shared directory
    # @param mnt [Mount::Entry]
    def propagate(mnt)
      tmp = Digest::SHA2.hexdigest(mnt.mountpoint)

      # Bind-mount the new mount into the shared directory
      host_path = File.join(path, tmp)
      Dir.mkdir(host_path)
      syscmd("mount --bind \"#{mnt.fs}\" \"#{host_path}\"")

      # Move the mount inside the container to the right place
      ret = ct_control(
        ct,
        :mount,
        id: ct.id,
        shared_dir: File.join('/', mountpoint),
        src: tmp,
        dst: File.join('/', mnt.mountpoint)
      )

      unless ret[:status]
        log(:warn, ct, "Failed to mount #{mnt.mountpoint} at runtime")
      end

      syscmd("umount \"#{host_path}\"")
      Dir.rmdir(host_path)
    end

    # @return [String]
    def path
      File.join(ct.pool.mount_dir, ct.id)
    end

    # Mountpoint relative to the container's rootfs
    # @return [String]
    def mountpoint
      '.osctl-mount-helper'
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    protected
    attr_reader :ct

    def readme_path
      File.join(path, 'README.txt')
    end

    def create_readme
      File.write(
        readme_path,
        <<END
Directory `.osctl-mount-helper` is used by osctl from vpsAdminOS to propagate
new mounts into this container. Do not remove nor unmount this directory, or
you'll have to restart your container to create new mounts!
END
      )
    end
  end
end
