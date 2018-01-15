module OsCtld
  class Assets::File < Assets::BaseFile
    register :file

    # @param opts [Hash] options
    # @opt opts [Integer, nil] user
    # @opt opts [Integer, nil] group
    # @opt opts [Integer, nil] mode
    def initialize(path, opts)
      super
    end

    def valid?
      add_error('not a file') unless stat.file?
      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end
  end
end
