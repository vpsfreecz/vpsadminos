module OsCtld
  # Identifies a process without trusting a reusable PID.
  class ProcessIdentity
    attr_reader :pid, :tid, :start_time_ticks

    # @param pid [Integer]
    # @return [ProcessIdentity, nil]
    def self.capture(pid, tid: nil)
      new(pid, read_start_time(pid, tid:), tid:)
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end

    def self.capture_thread(thread = Thread.current)
      capture(Process.pid, tid: thread.native_thread_id)
    end

    # @param cfg [Hash]
    # @return [ProcessIdentity]
    def self.load(cfg)
      new(
        cfg.fetch('pid'),
        cfg['start_time_ticks'] || cfg.fetch('start_time'),
        tid: cfg['tid']
      )
    end

    # @param pid [Integer]
    # @param tid [Integer, nil]
    # @return [Integer]
    def self.read_start_time(pid, tid: nil)
      path =
        if tid
          File.join('/proc', pid.to_i.to_s, 'task', tid.to_i.to_s, 'stat')
        else
          File.join('/proc', pid.to_i.to_s, 'stat')
        end
      stat = File.read(path)
      tail = stat[stat.rindex(')') + 2..]
      tail.split.fetch(19).to_i
    end

    def initialize(pid, start_time_ticks, tid: nil)
      @pid = pid.to_i
      @tid = tid&.to_i
      @start_time_ticks = start_time_ticks.to_i
    end

    def alive?
      self.class.read_start_time(pid, tid:) == start_time_ticks
    rescue Errno::ENOENT, Errno::ESRCH
      false
    end

    def ancestor_of?(descendant_pid)
      current = descendant_pid.to_i
      visited = {}

      while current > 1 && !visited[current]
        return alive? if current == pid

        visited[current] = true
        current = self.class.read_parent_pid(current)
      end

      false
    rescue Errno::ENOENT, Errno::ESRCH
      false
    end

    def self.read_parent_pid(pid)
      stat = File.read(File.join('/proc', pid.to_i.to_s, 'stat'))
      tail = stat[stat.rindex(')') + 2..]
      tail.split.fetch(1).to_i
    end

    def dump
      {
        'pid' => pid,
        'tid' => tid,
        'start_time_ticks' => start_time_ticks
      }.compact
    end
  end
end
