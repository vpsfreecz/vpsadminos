require 'prometheus/client/registry'

class Prometheus::Client::Registry
  def initialize_copy(_other)
    @metrics = @metrics.clone
    @mutex = Mutex.new
  end
end
