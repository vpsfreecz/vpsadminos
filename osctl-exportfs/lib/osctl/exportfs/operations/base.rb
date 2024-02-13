module OsCtl::ExportFS
  class Operations::Base
    def self.run(*, &)
      op = new(*, &)
      op.execute
    end

    def execute
      raise NotImplementedError
    end
  end
end
