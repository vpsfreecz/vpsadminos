require 'socket'

module OsCtld
  class Commands::Base
    def self.handle(name)
      @cmd = name
      Command.register(name, self)
    end

    class << self
      attr_reader :cmd
    end

    # @param kwargs [Hash] command options
    # @param internal [Hash] internal options
    # @option internal [Fixnum] :id command id
    # @option internal [Generic::ClientHandler, nil] :handler
    # @option internal [Boolean] :indirect
    def self.run(internal: {}, **kwargs)
      internal[:id] ||= Command.get_id
      c = new(kwargs, internal)
      c.base_execute
    end

    def self.run!(**)
      ret = run(**)

      if !ret.is_a?(Hash)
        raise "invalid return value '#{ret.inspect}'"

      elsif !ret[:status]
        raise ret[:message]
      end

      ret
    end

    attr_reader :id, :client, :opts

    def initialize(cmd_opts, opts)
      @opts = cmd_opts
      @id = opts[:id]
      @client_handler = opts[:handler]
      @client = @client_handler && @client_handler.socket
      @indirect = opts[:indirect] || false
    end

    # This method is for command templates, do not override it in your command
    def base_execute
      execute
    end

    # Implement this method in your command, or follow instructions from your
    # command template.
    def execute
      raise NotImplementedError
    end

    # Implement to prematurely stop the client thread
    def request_stop; end

    def manipulation_holder
      if opts[:cli]
        "'#{opts[:cli]}'"
      else
        self.class.cmd.to_s
      end
    end

    protected

    attr_reader :client_handler

    def call_cmd(klass, **)
      klass.run(internal: { handler: client_handler, indirect: true }, **)
    end

    def call_cmd!(*, **)
      ret = call_cmd(*, **)

      if !ret.is_a?(Hash)
        error!("invalid return value '#{ret.inspect}'")

      elsif !ret[:status]
        error!(ret[:message])
      end

      ret
    end

    def client_pid
      return unless client_handler

      client_handler.socket.getsockopt(
        Socket::SOL_SOCKET,
        Socket::SO_PEERCRED
      ).unpack1('L')
    end

    # @param manipulable [Object, Array<Object>]
    # @yield [] block called with the lock held
    def manipulate(manipulable, lifecycle: false, &codeblock)
      block = opts[:manipulation_lock] == 'wait'
      guarded_block = proc do
        unless lifecycle == true || opts[:manipulation_lock] == 'ignore'
          guard_container_lifecycle!(
            manipulable,
            allow_policy_taint: lifecycle == :policy_update
          )
        end
        codeblock.call
      end

      if opts[:manipulation_lock] == 'ignore'
        guarded_block.call

      elsif manipulable.is_a?(Array)
        locked = []

        # Acquire all locks
        begin
          manipulable.each do |m|
            m.acquire_manipulation_lock(self, block:) || (raise 'unable to lock')
            locked << m
          end
        rescue ResourceLocked
          locked.reverse_each(&:release_manipulation_lock)
          raise
        end

        # Call the block and release locks
        begin
          guarded_block.call
        ensure
          locked.reverse_each(&:release_manipulation_lock)
        end

      else
        manipulable.manipulate(self, block:, &guarded_block)
      end
    end

    def guard_container_lifecycle!(manipulable, allow_policy_taint: false)
      Array(manipulable).each do |object|
        next unless object.is_a?(OsCtld::Container)

        blocker = object.lifecycle.manipulation_blocker(
          allow_policy_taint:
        )
        next unless blocker

        detail = blocker[:effect] ? " effect #{blocker[:effect]}" : ''
        raise CommandFailed,
              "container lifecycle is #{blocker[:phase]}#{detail}; " \
              'wait for it to settle or use an explicit recovery command'
      end
    end

    def ok(resp = nil)
      { status: true, output: resp }
    end

    def handled
      { status: :handled }
    end

    def error(msg)
      { status: false, message: msg }
    end

    def error!(msg)
      raise CommandFailed, msg
    end

    def progress(msg)
      return unless @client_handler && (opts[:progress].nil? || opts[:progress])

      @client_handler.send_update(msg)
    end

    def indirect?
      @indirect
    end
  end
end
