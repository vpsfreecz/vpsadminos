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
  end
end
