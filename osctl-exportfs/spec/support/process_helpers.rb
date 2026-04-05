# frozen_string_literal: true

module ProcessHelpers
  def build_wait_status(exitstatus)
    instance_double(Process::Status, exitstatus:, success?: exitstatus == 0)
  end

  def stub_pid_signalability(live_pids: [], denied_pids: [])
    allow(Process).to receive(:kill).with(0, anything) do |_signal, pid|
      if live_pids.include?(pid)
        1
      elsif denied_pids.include?(pid)
        raise Errno::EPERM
      else
        raise Errno::ESRCH
      end
    end
  end

  def with_argv(argv)
    old = ARGV.dup
    ARGV.replace(argv)
    yield
  ensure
    ARGV.replace(old)
  end
end

RSpec.configure do |config|
  config.include ProcessHelpers
end
