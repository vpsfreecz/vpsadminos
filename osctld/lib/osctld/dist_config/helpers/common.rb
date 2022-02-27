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
        return if (File.stat(path).mode & 0200) != 0200
      rescue Errno::ENOENT
        # pass
      end

      yield(path) if block_given?
      true
    end

    # @param service [String]
    def systemd_service_masked?(service)
      begin
        dst = File.readlink(File.join(rootfs, 'etc/systemd/system', service))
      rescue Errno::ENOENT
        return false
      else
        return dst == '/dev/null'
      end
    end

    # @param service [String]
    # @param target [String]
    def systemd_service_enabled?(service, target)
      wanted = File.join(
        rootfs,
        'etc/systemd/system',
        "#{target}.wants",
        service,
      )

      begin
        File.lstat(wanted)
        return true
      rescue Errno::ENOENT
        return false
      end
    end
  end
end
