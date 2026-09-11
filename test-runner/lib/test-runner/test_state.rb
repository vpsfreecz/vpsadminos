require 'digest'
require 'fileutils'

module TestRunner
  module TestState
    @mutex = Mutex.new
    @locks = []

    def self.directory(base, test)
      slug = test.path.gsub(/[^A-Za-z0-9_.-]+/, '__')
      File.join(base, "os-test-#{slug}-#{Digest::SHA256.hexdigest(test.path)[0, 8]}")
    end

    def self.with_lock(directory)
      FileUtils.mkdir_p(directory)
      lock = nil
      @mutex.synchronize do
        lock = File.open(File.join(directory, '.lock'), File::RDWR | File::CREAT, 0o600)
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise "Test state is already in use: #{directory}"
        end

        @locks << lock
      end

      yield lock
    ensure
      if lock
        @mutex.synchronize do
          @locks.delete(lock)
          lock.close
        end
      end
    end

    # Keep the evaluator's lock until it exits, even if its parent dies first.
    # Close unrelated workers' locks so this child cannot prolong their lifetime.
    def self.fork(keep:, &block)
      @mutex.synchronize do
        Process.fork do
          @locks.each { |lock| lock.close unless lock.equal?(keep) }
          @locks = [keep]
          @mutex = Mutex.new
          block.call
        end
      end
    end
  end
end
