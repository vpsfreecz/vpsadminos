module OsCtld
  class Commands::Assets < Commands::Base
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def initialize(*_)
      super
      @assets = []
    end

    protected
    attr_reader :assets

    def add(type, path, purpose)
      entry = {
        type: type,
        path: path,
      }

      case type
      when :dataset
        e = zfs(:get, '-H -ovalue name', path, valid_rcs: [1])[:exitstatus] == 0

      when :directory
        e = Dir.exist?(path)

      when :file
        e = File.exist?(path)

      when :entry
        e = yield(path)

      else
        e = false
      end

      entry[:exist] = e
      entry[:purpose] = purpose

      @assets << entry
    end
  end
end
