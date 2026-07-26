# frozen_string_literal: true

require 'osctld/process_identity'

RSpec.describe OsCtld::ProcessIdentity do
  it 'captures and reloads the current process identity' do
    identity = described_class.capture(Process.pid)
    loaded = described_class.load(identity.dump)

    expect(loaded.pid).to eq(Process.pid)
    expect(loaded.start_time_ticks).to be > 0
    expect(loaded).to be_alive
  end

  it 'rejects a reused pid with a different start time' do
    identity = described_class.new(Process.pid, 0)

    expect(identity).not_to be_alive
  end

  it 'distinguishes a finished worker thread from its live process' do
    queue = Queue.new
    thread = Thread.new do
      queue << described_class.capture_thread
    end
    identity = queue.pop
    thread.join

    expect(identity.pid).to eq(Process.pid)
    expect(identity.tid).not_to be_nil
    expect(identity).not_to be_alive
    expect(described_class.capture(Process.pid)).to be_alive
  end

  it 'recognizes descendants of the captured process' do
    reader, writer = IO.pipe
    child_pid = Process.fork do
      writer.close
      reader.read
      exit!(0)
    end
    reader.close

    expect(described_class.capture(Process.pid)).to be_ancestor_of(child_pid)
  ensure
    writer&.close
    Process.wait(child_pid) if child_pid
  end
end
