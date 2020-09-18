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

    def initialize(status, data: nil, message: nil, user_runner: false)
      @status = status
      @data = data
      @message = message
      @user_runner = user_runner
    end

    def ok?
      status ? true : false
    end

    def user_runner?
      @user_runner
    end
  end
end
