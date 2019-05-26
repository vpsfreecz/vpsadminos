module OsCtl::Template
  class Operations::Base
    def self.run(*args)
      op = new(*args)
      op.execute
    end

    def execute
      raise NotImplementedError
    end
  end
end
