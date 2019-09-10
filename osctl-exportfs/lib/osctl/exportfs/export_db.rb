require 'libosctl'
require 'yaml'

module OsCtl::ExportFS
  class ExportDB
    include OsCtl::Lib::Utils::File

    attr_reader :path

    # @param path [String]
    def initialize(path)
      @path = path

      if File.exist?(path)
        read_db
      else
        @db = []
      end
    end

    # @param export [Export]
    def <<(export)
      db << export
    end

    # @param dir [String]
    # @param host [String]
    # @return [Export, nil]
    def lookup(dir, host)
      db.each do |ex|
        return ex if ex.dir == dir && ex.host == host
      end

      nil
    end

    # @param export [Export]
    def remove(export)
      db.delete(export)
    end

    def each(&block)
      db.each(&block)
    end

    def save
      regenerate_file(path, 0644) do |new|
        new.write(YAML.dump(db.map(&:dump)))
      end
    end

    protected
    attr_reader :db

    def read_db
      @db = YAML.load_file(path).map { |v| Export.load(v) }
    end
  end
end
