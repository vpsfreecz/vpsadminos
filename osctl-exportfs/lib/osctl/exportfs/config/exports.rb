module OsCtl::ExportFS
  class Config::Exports
    # @param cfg [Array]
    def initialize(cfg)
      @db = cfg.map { |v| Export.load(v) }
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

    def dump
      db.map(&:dump)
    end

    protected
    attr_reader :db
  end
end
