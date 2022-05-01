require 'prometheus/client/registry'

class Prometheus::Client::Registry
  def initialize_copy(other)
    @metrics = @metrics.clone
    @mutex = Mutex.new
  end
end
