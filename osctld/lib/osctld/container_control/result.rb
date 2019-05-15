module OsCtld
  class ContainerControl::Result
    # Create result from the runner's output
    # @return [ContainerControl::Result]
    def self.from_runner(data)
      if data[:status]
        new(true, data: data[:output])
      else
        new(false, message: data[:message])
      end
    end

    attr_reader :status, :data, :message

    def initialize(status, data: nil, message: nil)
      @status = status
      @data = data
      @message = message
    end

    def ok?
      status ? true : false
    end
  end
end
