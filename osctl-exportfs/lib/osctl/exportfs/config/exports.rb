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

    # @param as [String]
    # @param host [String]
    # @return [Export, nil]
    def lookup(as, host)
      db.detect { |ex| return ex if ex.as == as && ex.host == host }
    end

    # @param export [Export]
    def remove(export)
      db.delete(export)
    end

    def each(&)
      db.each(&)
    end

    # @param as [String]
    def find_by_as(as)
      as_abs = File.absolute_path(as)
      db.detect { |ex| File.absolute_path(ex.as) == as_abs }
    end

    # @return [Array(String, String, Array<::Export>)]
    def group_by_as
      ret = {}

      db.each do |ex|
        ret[ex.as] ||= []
        ret[ex.as] << ex
      end

      ret.map do |as, exports|
        first_ex = exports.first

        exports.each do |ex|
          if ex.dir != first_ex.dir
            raise "target export path #{as} has two source paths: #{ex.dir} " \
                  "and #{first_ex.dir}"
          end
        end

        [first_ex.dir, as, exports]
      end
    end

    def dump
      db.map(&:dump)
    end

    protected

    attr_reader :db
  end
end
