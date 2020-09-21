require 'securerandom'

module OsCtl::Lib
  module Utils::File
    def regenerate_file(path, mode)
      replacement = "#{path}.new-#{SecureRandom.hex(3)}"

      File.open(replacement, 'w', mode) do |new|
        if File.exist?(path)
          File.open(path, 'r') do |old|
            yield(new, old)
          end

        else
          yield(new, nil)
        end
      end

      File.rename(replacement, path)
    end

    # Atomically replace or create symlink
    # @param path [String] symlink path
    # @param dst [String] destination
    def replace_symlink(path, dst)
      replacement = "#{path}.new-#{SecureRandom.hex(3)}"
      File.symlink(dst, replacement)
      File.rename(replacement, path)
    end

    def unlink_if_exists(path)
      File.unlink(path)
      true
    rescue Errno::ENOENT
      false
    end

    def rmdir_if_empty(path)
      Dir.rmdir(path)
      true
    rescue Errno::ENOTEMPTY
      false
    end
  end
end
