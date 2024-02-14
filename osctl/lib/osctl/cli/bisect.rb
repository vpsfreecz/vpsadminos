require 'etc'
require 'thread'

module OsCtl::Cli
  class Bisect
    # @param cts [Array]
    # @param suspend_action [:freeze, :stop]
    # @param cols [Array]
    def initialize(cts, suspend_action: nil, cols: nil)
      @cts = cts
      @suspend_action = suspend_action
      @cols = cols
      @mutex = Mutex.new
    end

    def run
      print_set(cts)
      puts
      puts "Selected containers: #{cts.length}"
      puts "Suspend action: #{suspend_action}"
      puts
      ask_confirmation!

      begin
        bisect
      rescue StandardError, Interrupt
        puts
        puts 'Resuming all affected containers...'
        reset
        raise
      end
    end

    def reset
      execute_action_set(cts, :resume)
    end

    protected

    attr_reader :cts, :suspend_action, :cols, :mutex

    def bisect
      ct_set = @cts.clone
      action = :suspend

      loop do
        if ct_set.size == 1
          execute_action_set(ct_set, :resume) if action == :resume

          ct = ct_set.first
          puts
          puts "Container identified: #{ct[:pool]}:#{ct[:id]}"
          break
        end

        left, right = ct_set.each_slice((ct_set.size / 2.0).round).to_a

        execute_action_set(left, action)
        puts

        if action == :suspend
          if ask_success?
            ct_set = left
            action = :resume
            execute_action_set(right, :resume)
          else
            ct_set = right
            action = :suspend
            execute_action_set(left, :resume)
            puts
          end

        elsif action == :resume
          if ask_success?
            ct_set = left
            action = :suspend
            execute_action_set(right, :resume)
          else
            ct_set = right
            action = :resume
            execute_action_set(left, :resume)
            puts
          end

        else
          raise 'programming error'
        end

        puts "Narrowed down to #{ct_set.size} containers"
      end
    end

    def print_set(ct_set)
      OsCtl::Lib::Cli::OutputFormatter.print(ct_set, cols:, layout: :columns)
    end

    def ask_confirmation!
      $stdout.write('Continue? [y/N]: ')
      $stdout.flush

      unless %w[y yes].include?($stdin.readline.strip.downcase)
        raise 'Aborted'
      end

      puts
    end

    def ask_success?
      loop do
        $stdout.write('Has the situation changed? [y/n]: ')
        $stdout.flush

        s = $stdin.readline.strip.downcase
        ret = nil

        if %w[y yes].include?(s)
          ret = true
        elsif %w[n no].include?(s)
          ret = false
        end

        puts

        return ret unless ret.nil?
      end
    end

    # @param ct_set [Array]
    # @param action [:suspend, :resume]
    def execute_action_set(ct_set, action)
      queue = Queue.new
      ct_set.each_with_index { |ct, i| queue << [i + 1, ct] }
      n = ct_set.length

      osctl_action =
        if suspend_action == :freeze
          action == :suspend ? :ct_freeze : :ct_unfreeze
        elsif suspend_action == :stop
          action == :suspend ? :ct_stop : :ct_start
        else
          raise "invalid action '#{suspend_action}'"
        end

      threads = Etc.nprocessors.times.map do
        Thread.new do
          c = OsCtl::Client.new
          c.open

          loop do
            begin
              i, ct = queue.pop(true)
            rescue ThreadError
              break
            end

            resp = c.cmd_response(osctl_action, pool: ct[:pool], id: ct[:id])

            mutex.synchronize do
              puts "[#{i}/#{n}] #{action_str(action)} #{ct[:pool]}:#{ct[:id]} " +
                   "... #{resp.ok? ? 'ok' : "error: #{resp.message}"}"
            end
          end

          c.close
        end
      end

      threads.each(&:join)
    end

    # @param action [:suspend, :resume]
    def action_reverse(action)
      action == :suspend ? :resume : :suspend
    end

    def action_str(action)
      if suspend_action == :freeze
        action == :suspend ? 'freeze' : 'thaw'
      elsif suspend_action == :stop
        action == :suspend ? 'stop' : 'start'
      else
        raise "invalid action '#{suspend_action}'"
      end
    end
  end
end
