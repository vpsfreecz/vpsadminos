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
      FileUtils.rm_f(readme_path)
      dir.rmdir if dir.exist?
    end

    # Propagate a new mount inside the container via the shared directory
    # @param mnt [Mount::Entry]
    def propagate(mnt)
      # Bind-mount the new mount into the shared directory
      host_path = host_path_for(mnt.mountpoint)

      Dir.mkdir(host_path)

      opts =
        if ct.map_mode == 'native' && mnt.id_mapped?
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
    # @param ns_pid [Integer]
    # @param [String] path to the mountpoint, same in both init and ct mount namespaces
    def map_and_push(dir, ns_pid)
      host_path = host_path_for(dir)

      Dir.mkdir(host_path)
      syscmd("mount --bind -o X-mount.idmap=/proc/#{ns_pid}/ns/user #{dir} #{host_path}")

      host_path
    end

    # Cleanup after {#map_and_push}
    # @param dir [String]
    def cleanup_pushed(dir)
      host_path = host_path_for(dir)

      syscmd("umount \"#{host_path}\"")
      Dir.rmdir(host_path)

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
