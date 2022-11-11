require 'etc'
require 'libosctl'
require 'thread'

module OsCtld
  # Event pub/sub server
  #
  # This class aggregates events from osctld and announces them to subscribed
  # clients.
  #
  # == Subscribing
  # Clients can subscribe by calling {#subscribe}, which returns a queue over
  # which the events will be sent. To unsubscribe, call #{unsubscribe} with
  # the queue as an argument. An instance of {Eventd::Event} is sent over the queue
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
  # === `:osctld_shutdown`
  # Sent when osctld is shutting down.
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
  class Eventd::Manager
    def initialize
      @workers = []
    end

    # @param num_workers [Integer, nil]
    def start(num_workers: nil)
      num_workers ||= default_worker_count
      @workers.clear

      num_workers.times.each do
        w = Eventd::Worker.new
        w.start
        @workers << w
      end

      nil
    end

    def stop
      @workers.each(&:stop)
      nil
    end

    def shutdown
      report(:osctld_shutdown)
      stop
      nil
    end

    # Subscribe a client to all events
    # @return [OsCtl::Lib::Queue]
    def subscribe
      q = OsCtl::Lib::Queue.new
      get_worker.subscribe(q)
      q
    end

    # Unsubscribe client represented by `queue`
    # @param queue [OsCtl::Lib::Queue]
    def unsubscribe(queue)
      @workers.each { |w| w.unsubscribe(queue) }
      nil
    end

    # Report an event that should be announced to all subscribers
    # @param type [Symbol]
    # @param opts [Hash]
    def report(type, **opts)
      event = Eventd::Event.new(type, opts)
      @workers.each { |w| w.report(event) }
      nil
    end

    protected
    def get_worker
      ret = nil
      min_size = nil

      @workers.each do |w|
        w_size = w.size

        if min_size.nil? || w_size < min_size
          ret = w
          min_size = w_size
        end
      end

      fail 'programming error: no worker found' if ret.nil?

      ret
    end

    def default_worker_count
      [Etc.nprocessors / 32, 2].max
    end
  end
end
