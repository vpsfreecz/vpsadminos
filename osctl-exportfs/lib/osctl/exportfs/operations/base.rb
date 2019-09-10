module OsCtl::ExportFS
  class Operations::Base
    def self.run(*args, &block)
      op = new(*args, &block)
      op.execute
    end

    def execute
      raise NotImplementedError
    end
  end
end
