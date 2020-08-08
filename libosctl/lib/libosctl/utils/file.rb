module OsCtl::Lib
  module Utils::File
    def regenerate_file(path, mode)
      replacement = "#{path}.new"

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
