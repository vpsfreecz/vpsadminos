module OsCtl::Image
  class Operations::Base
    def self.run(*args, **kwargs)
      op = new(*args, **kwargs)
      op.execute
    end

    def execute
      raise NotImplementedError
    end
  end
end
