require 'concurrent'
require 'libosctl'
require 'thread'

module OsCtld
  # Singleton event daemon
  #
  # This class aggregates events from osctld and announces them to subscribed
  # clients.
  #
  # == Subscribing
  # Clients can subscribe by calling {#subscribe}, which returns a queue over
  # which the events will be sent. To unsubscribe, call #{unsubscribe} with
  # the queue as an argument. An instance of {Event} is sent over the queue
  # for every reported event.
  #
  # == Announcing events
  # Events are announced using method {#report}. Events are classified by
  # a `type` and described by `opts`. For possible event types, see below.
  #
  # == Event types
  # === `:management`
  # Used for management commands received over the command socket.
  # Options:
  #
  #     {
  #       id: unique internal command identifier,
  #       cmd: management command,
  #       opts: command options,
  #       state: :run | :done | :failed
  #     }
  #
  # === `:state`
  # Used to report changes of container states.
  # Options:
  #
  #     {
  #       pool: pool name,
  #       id: container id,
  #       state: new state
  #     }
  #
  # === `:db`
  # Reports about changes in osctld database.
  # Options:
  #
  #     {
  #       object: pool/user/group/container,
  #       pool: object's pool name,
  #       id: object identificator,
  #       action: add/remove
  #     }
  #
  # === `:ct_scheduled`
  # Reports actions by the CPU scheduler
  # Options:
  #
  #     {
  #       pool: pool name,
  #       id: container id,
  #       cpu_package_inuse: package id
  #     }
  #
  # === `:ct_init_pid`
  # Reports discovery of container init PID
  # Options:
  #
  #     {
  #       pool: pool name,
  #       id: container id,
  #       init_pid: init PID
  #     }
  #
  # === `:ct_netif`
  # Reports about container networking interfaces being added, deleted or coming
  # up and down.
  #
  # Options:
  #
  #     {
  #       pool: container's pool name,
  #       id: container id,
  #       action: add/remove/rename/up/down,
  #       name: interface name inside the container,
  #       new_name: net interface name when action is rename,
  #       veth: interface name on the host
  #     }
  class Eventd
    @@instance = nil

    class << self
      def instance
        return @@instance if @@instance
        @@instance = new
      end

      %i(start stop subscribe unsubscribe report).each do |m|
        define_method(m) do |*args, **kwargs, &block|
          instance.method(m).call(*args, **kwargs, &block)
        end
      end
    end

    private
    def initialize
      @queue = Queue.new
      @subscribers = Concurrent::Array.new
    end

    public
    def start
      @thread = Thread.new do
        loop do
          event = @queue.pop
          break if event == :stop

          @subscribers.each do |queue|
            queue << event
          end
        end

        @subscribers.clear
      end
    end

    def stop
      @queue << :stop
      @thread.join
    end

    # Subscribe a client to all events
    # @return [Queue]
    def subscribe
      q = OsCtl::Lib::Queue.new
      @subscribers << q
      q
    end

    # Unsubscribe client represented by `queue`
    # @param queue [Queue]
    def unsubscribe(queue)
      @subscribers.delete(queue)
    end

    # Report an event that should be announced to all subscribers
    # @param type [Symbol]
    # @param opts [Hash]
    def report(type, **opts)
      @queue << Event.new(type, opts)
    end
  end
end
