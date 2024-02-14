require 'json'

module OsCtld
  class History
    class Reader
      def initialize(path)
        @f = File.open(path, 'r')
      end

      def close
        @f.close
      end

      def each
        yield(parse) until @f.eof?
      rescue EOFError
      end

      include Enumerable

      def eof?
        @f.eof?
      end

      def read
        parse
      end

      protected

      def parse
        JSON.parse(@f.readline, symbolize_names: true)
      end
    end

    @@instance = nil

    class << self
      def instance
        return @@instance if @@instance

        @@instance = new
      end

      %i[assets start stop open close log read].each do |m|
        define_method(m) do |*args, &block|
          instance.method(m).call(*args, &block)
        end
      end
    end

    private

    def initialize
      @queue = Queue.new
      @files = {}
    end

    public

    def assets(pool, add)
      add.file(
        log_path(pool),
        desc: 'Pool history',
        user: 0,
        group: 0,
        mode: 0o400
      )
    end

    def start
      @thread = Thread.new { main_loop }
    end

    def stop
      @queue << [:stop]
      @thread.join
    end

    def open(pool)
      @queue << [:open, pool]
    end

    def close(pool)
      @queue << [:close, pool]
    end

    def log(pool, cmd, opts)
      @queue << [:log, pool, cmd, opts]
    end

    def read(pool)
      Reader.new(log_path(pool))
    end

    protected

    def main_loop
      files = {}

      loop do
        cmd, *args = @queue.pop

        case cmd
        when :stop
          break

        when :open
          pool = args.pop

          unless files.has_key?(pool.name)
            files[pool.name] = File.open(log_path(pool), 'a', 0o400)
          end

        when :close
          pool = args.pop

          if files.has_key?(pool.name)
            files[pool.name].close
            files.delete(pool.name)
          end

        when :log
          do_log(files, *args)
        end
      end

      files.each_value(&:close)
    end

    def do_log(files, pool, cmd, opts)
      unless files.has_key?(pool.name)
        files[pool.name] = File.open(log_path(pool), 'a', 0o400)
      end

      write_log(files[pool.name], cmd, opts)
    end

    def write_log(file, cmd, opts)
      file.puts({ time: Time.now.to_i, cmd:, opts: }.to_json)
      file.flush
    end

    def log_path(pool)
      File.join(pool.log_path, '.history')
    end
  end
end
