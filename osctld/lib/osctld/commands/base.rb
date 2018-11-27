module OsCtld
  class Commands::Base
    def self.handle(name)
      @cmd = name
      Command.register(name, self)
    end

    def self.cmd
      @cmd
    end

    # @param cmd_opts [Hash] command options
    # @param opts [Hash] options
    # @option opts [Fixnum] id command id
    # @option opts [Generic::ClientHandler, nil] handler
    # @option opts [Boolean] indirect
    def self.run(cmd_opts = {}, opts = {})
      opts[:id] ||= Command.get_id
      c = new(cmd_opts, opts)
      c.base_execute
    end

    def self.run!(*args)
      ret = run(*args)

      if !ret.is_a?(Hash)
        fail "invalid return value '#{ret.inspect}'"

      elsif !ret[:status]
        fail ret[:message]
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

    def manipulation_holder
      if opts[:cli]
        "'#{opts[:cli]}'"
      else
        self.class.cmd.to_s
      end
    end

    protected
    attr_reader :client_handler

    def call_cmd(klass, opts = {})
      klass.run(opts, handler: client_handler, indirect: true)
    end

    def call_cmd!(*args)
      ret = call_cmd(*args)

      if !ret.is_a?(Hash)
        error!("invalid return value '#{ret.inspect}'")

      elsif !ret[:status]
        error!(ret[:message])
      end

      ret
    end

    # @param manipulable [Object, Array<Object>]
    # @yield [] block called with the lock held
    def manipulate(manipulable, &codeblock)
      block = opts[:manipulation_lock] == 'wait'

      if opts[:manipulation_lock] == 'ignore'
        codeblock.call

      elsif manipulable.is_a?(Array)
        locked = []

        # Acquire all locks
        begin
          manipulable.each do |m|
            m.acquire_manipulation_lock(self, block: block) || (fail 'unable to lock')
            locked << m
          end

        rescue ResourceLocked
          locked.reverse_each(&:release_manipulation_lock)
          raise
        end

        # Call the block and release locks
        begin
          codeblock.call

        ensure
          locked.reverse_each(&:release_manipulation_lock)
        end

      else
        manipulable.manipulate(self, block: block, &codeblock)
      end
    end

    def ok(resp = nil)
      {status: true, output: resp}
    end

    def handled
      {status: :handled}
    end

    def error(msg)
      {status: false, message: msg}
    end

    def error!(msg)
      raise CommandFailed, msg
    end

    def progress(msg)
      if @client_handler && (opts[:progress].nil? || opts[:progress])
        @client_handler.send_update(msg)
      end
    end

    def indirect?
      @indirect
    end
  end
end
