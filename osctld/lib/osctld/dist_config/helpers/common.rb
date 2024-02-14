module OsCtld
  module DistConfig::Helpers::Common
    # Check if the file at `path` si writable by its user
    #
    # If the file doesn't exist, we take it as writable. If a block is given,
    # it is called if `path` is writable.
    #
    # @yieldparam path [String]
    def writable?(path)
      begin
        return false if (File.stat(path).mode & 0o200) != 0o200
      rescue Errno::ENOENT
        # pass
      end

      yield(path) if block_given?
      true
    end

    # @param service [String]
    def systemd_service_masked?(service)
      dst = File.readlink(File.join(rootfs, 'etc/systemd/system', service))
    rescue Errno::ENOENT, Errno::EINVAL
      false
    else
      dst == '/dev/null'
    end

    # @param service [String]
    # @param target [String]
    def systemd_service_enabled?(service, target)
      wanted = File.join(
        rootfs,
        'etc/systemd/system',
        "#{target}.wants",
        service
      )

      begin
        File.lstat(wanted)
        true
      rescue Errno::ENOENT
        false
      end
    end
  end
end
