# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'socket'

RSpec.describe OsCtl::Oomd::ActionWorkers do
  let(:lines) { [] }
  let(:evidence) do
    OsCtl::Oomd::Evidence.new(writer: lambda { |bytes|
      lines << bytes
      bytes.bytesize
    })
  end

  it 'keeps two actual blocked commands in flight, deduplicates capacity and has no stale permit queue' do
    entered = Queue.new
    release = Queue.new
    workers = described_class.new(evidence:, size: 2, dry_run: false, executor: lambda { |permit|
      entered << permit
      release.pop
      true
    }, notifier: ->(_event) {})
    workers.start
    a = { id: 'a' }
    b = { id: 'b' }
    expect(workers.dispatch(a)).to be(true)
    expect(workers.dispatch(b)).to be(true)
    expect(Timeout.timeout(2) { [entered.pop, entered.pop] }).to contain_exactly(a, b)
    expect(workers.dispatch(id: 'c')).to be(false)
    results = []
    workers.completions { |*result| results << result }
    expect(results).to be_empty
    2.times { release << true }
    Timeout.timeout(2) do
      loop do
        workers.completions { |*result| results << result }
        break if results.size == 2

        Thread.pass
      end
    end
    expect(results.map(&:last)).to eq(%i[success success])
    expect(entered).to be_empty
  ensure
    2.times { release << true }
    workers&.stop
  end

  it 'keeps stdout live while blocked broadcast retains two slots and retries the same ID' do
    entered = Queue.new
    release = Queue.new
    attempts = []
    workers = described_class.new(evidence:, size: 2, dry_run: false, executor: ->(_permit) { true }, notifier: lambda { |event|
      attempts << event
      entered << true
      release.pop
      raise IOError, 'first attempt fails' if attempts.size == 1
    })
    workers.start
    a = { id: 'a' }
    b = { id: 'b' }
    expect(workers.dispatch(a)).to be(true)
    expect(workers.dispatch(b)).to be(true)
    completed = []
    Timeout.timeout(2) do
      loop do
        workers.completions { |*result| completed << result }
        break if completed.size == 2

        Thread.pass
      end
    end
    Timeout.timeout(2) { entered.pop }
    expect(workers.dispatch(id: 'c')).to be(false)
    Timeout.timeout(2) { Thread.pass until evidence.status[:evidence_pending_records] == 0 }
    expect(lines.map { |line| JSON.parse(line)['type'] }.count('action_result')).to eq(2)
    release << true
    Timeout.timeout(2) { entered.pop }
    expect(attempts[1]).to equal(attempts[0])
    expect(attempts[1][:event_id]).to eq(a[:action_id])
    expect(workers.notification_failures).to eq(1)
  ensure
    4.times { release << true }
    workers&.stop
  end

  it 'retains both already received terminal outcomes behind a blocked stdout sink' do
    release = false
    accepted = []
    sink = OsCtl::Oomd::Evidence.new(writer: lambda { |bytes|
      next :wait_writable unless release

      accepted << bytes
      bytes.bytesize
    })
    workers = described_class.new(evidence: sink, size: 2, dry_run: false, executor: ->(_permit) { true }, notifier: ->(_event) {})
    workers.start
    expect(workers.dispatch(id: 'a')).to be(true)
    expect(workers.dispatch(id: 'b')).to be(true)
    held = sink.reserve(450)
    results = []
    Timeout.timeout(2) do
      loop do
        workers.completions { |*result| results << result }
        break if results.size == 2

        Thread.pass
      end
    end
    expect(results.map(&:last)).to eq(%i[success success])
    expect(accepted).to be_empty
    expect(sink.status[:evidence_pending_records]).to eq(6)
    expect(sink.status[:evidence_records]).to be <= 512
    sink.release(held)
    release = true
    workers.stop
    workers = nil
    expect(accepted.map { |line| JSON.parse(line)['type'] }.count('action_result')).to eq(2)
  ensure
    release = true
    sink&.release(held)
    workers&.stop
  end

  it 'round-trips all long progress bytes without truncation and with bounded line parts' do
    server_socket, client_socket = UNIXSocket.pair
    allow(UNIXSocket).to receive(:new).with(OsCtl::Client::SOCKET).and_return(client_socket)
    payload = "#{'ž' * 4000}\u0000end"
    server = Thread.new do
      server_socket.puts(JSON.generate(version: 'test-daemon'))
      server_socket.gets
      server_socket.puts(JSON.generate(status: true, progress: payload))
      server_socket.puts(JSON.generate(status: true, response: nil))
    end
    workers = described_class.new(evidence:, size: 1, dry_run: false)
    expect(workers.send(:execute, pool: 'tank', id: 'a', run: [42, 123], action: :restart)).to be(true)
    evidence.start
    evidence.stop
    records = lines.map { |line| JSON.parse(line) }
    expect(lines.map(&:bytesize).max).to be <= 3072
    expect(records.map { |r| r['part'] }).to eq((1..records.size).to_a)
    expect(records.map { |r| r['parts'] }.uniq).to eq([records.size])
    expect(records.map { |r| r['original_bytes'] }.uniq).to eq([payload.bytesize])
    expect(records.map { |r| Base64.strict_decode64(r['data']) }.join).to eq(payload.b)
    expect(server.join(2)).to eq(server)
  ensure
    server_socket&.close unless server_socket&.closed?
    client_socket&.close unless client_socket&.closed?
  end

  it 'releases provisional log and broadcast reservations when the final fresh grant refuses' do
    workers = described_class.new(evidence:, size: 1, dry_run: false, executor: ->(_permit) { raise 'must not run' })
    expect(workers.dispatch(id: 'stale') { false }).to be(false)
    expect(evidence.status[:evidence_records]).to eq(8)
    expect(evidence.status[:evidence_pending_records]).to eq(0)
    expect(workers.available?).to be(true)
  end

  [true, false].each do |success|
    it "releases only on a validated terminal response (status #{success}), preserving guarded names" do
      server_socket, client_socket = UNIXSocket.pair
      allow(UNIXSocket).to receive(:new).with(OsCtl::Client::SOCKET).and_return(client_socket)
      requests = Queue.new
      server = Thread.new do
        server_socket.puts(JSON.generate(version: 'test-daemon'))
        requests << JSON.parse(server_socket.gets)
        server_socket.puts(JSON.generate(status: true, progress: 'OOMd expected run accepted pid=42 start=123'))
        response = success ? { status: true, response: nil } : { status: false, message: "Unsupported command 'ct_oomd_restart'" }
        server_socket.puts(JSON.generate(response))
      end
      workers = described_class.new(evidence:, size: 1, dry_run: false)
      permit = { pool: 'tank', id: 'a', run: [42, 123], action: :restart }
      expect(workers.send(:execute, permit)).to be(success)
      request = Timeout.timeout(2) { requests.pop }
      expect(request).to include('cmd' => 'ct_oomd_restart', 'opts' => include(
        'pool' => 'tank', 'id' => 'a', 'expected_init_pid' => 42, 'expected_init_start_time' => 123
      ))
      head = evidence.instance_variable_get(:@queue).first
      progress = JSON.parse(head[0])
      expect(Base64.strict_decode64(progress.fetch('data'))).to eq('OOMd expected run accepted pid=42 start=123')
      expect(server.join(2)).to eq(server)
    ensure
      server_socket&.close unless server_socket&.closed?
      client_socket&.close unless client_socket&.closed?
    end
  end

  it 'retains the slot after real connection loss while the submitted daemon action still runs' do
    server_socket, client_socket = UNIXSocket.pair
    allow(UNIXSocket).to receive(:new).with(OsCtl::Client::SOCKET).and_return(client_socket)
    submitted = Queue.new
    finish_action = Queue.new
    server = Thread.new do
      server_socket.puts(JSON.generate(version: 'test-daemon'))
      submitted << JSON.parse(server_socket.gets)
      server_socket.close
      finish_action.pop # The daemon action outlives the action connection.
    end
    workers = described_class.new(evidence:, size: 1, dry_run: false, notifier: ->(_event) {})
    workers.start
    expect(workers.dispatch(pool: 'tank', id: 'a', run: [42, 123], action: :restart)).to be(true)
    expect(Timeout.timeout(2) { submitted.pop }.fetch('cmd')).to eq('ct_oomd_restart')
    outcomes = []
    Timeout.timeout(2) do
      loop do
        workers.completions { |*result| outcomes << result }
        break unless outcomes.empty?

        Thread.pass
      end
    end
    expect(outcomes.last.last).to eq(:unknown)
    expect(server).to be_alive
    expect(workers.dispatch(pool: 'tank', id: 'b', run: [43, 124], action: :restart)).to be(false)
  ensure
    finish_action << true
    server&.join(2)
    # Only after the test daemon's effect is proven complete can its parked
    # fixture worker be interrupted; production retains unknown ownership.
    workers&.instance_variable_get(:@threads)&.each(&:kill)
    workers&.instance_variable_set(:@busy, [false]) # Fixture daemon effect has joined.
    workers&.stop
    server_socket&.close unless server_socket&.closed?
    client_socket&.close unless client_socket&.closed?
  end

  it 'classifies malformed terminal protocol as uncertainty instead of a definitive error' do
    client = described_class::ActionClient.new
    expect(client.parse('{"version":"test-daemon"}')).to include(version: 'test-daemon')
    expect { client.parse('{"message":"missing status"}') }.to raise_error(OsCtl::Client::Error)
    expect { client.parse('{"status":"false","message":"invalid status"}') }.to raise_error(OsCtl::Client::Error)
  end

  it 'holds a physical slot and shutdown when effects are unknown, without spawning a replacement' do
    workers = described_class.new(evidence:, size: 1, dry_run: false, executor: ->(_permit) { raise IOError, 'uncertain fixture' },
                                  notifier: ->(_event) {})
    workers.start
    expect(workers.dispatch(id: 'a')).to be(true)
    outcomes = []
    Timeout.timeout(2) do
      loop do
        workers.completions { |*result| outcomes << result }
        break unless outcomes.empty?

        Thread.pass
      end
    end
    expect(outcomes.last.last).to eq(:unknown)
    expect(workers.dispatch(id: 'b')).to be(false)
    action_threads = workers.instance_variable_get(:@threads)
    expect(action_threads.size).to eq(1)
    expect(action_threads.first).to be_alive
    shutdown = Thread.new { workers.stop }
    expect(shutdown.join(0.02)).to be_nil
  ensure
    # The injected executor spawned no process. Only its deliberately blocked
    # fixture thread is interrupted; production never releases unknown effects.
    action_threads&.each(&:kill)
    workers&.instance_variable_set(:@busy, [false]) # Injected executor owns no external work.
    shutdown&.join(2)
  end
end
