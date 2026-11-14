# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'socket'

RSpec.describe OsCtl::Oomd::ActionWorkers do
  it 'keeps two actual blocked commands in flight, deduplicates capacity and has no stale permit queue' do
    entered = Queue.new
    release = Queue.new
    workers = described_class.new(size: 2, dry_run: false, executor: lambda { |permit|
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

  it 'completes physical action slots while a fixed notification worker is blocked and exposes drops' do
    notifying = Queue.new
    release = Queue.new
    workers = described_class.new(size: 2, dry_run: false, executor: ->(_permit) { true }, notifier: lambda { |_event|
      notifying << true
      release.pop
    })
    workers.start
    workers.publish(type: :log)
    Timeout.timeout(2) { notifying.pop }
    16.times { expect(workers.publish(type: :log)).to be(true) }
    expect(workers.publish(type: :log)).to be(false)
    expect(workers.notification_drops).to eq(1)
    expect(workers.dispatch(id: 'a')).to be(true)
    completed = []
    Timeout.timeout(2) do
      loop do
        workers.completions { |*result| completed << result }
        break unless completed.empty?

        Thread.pass
      end
    end
    expect(completed.last.last).to eq(:success)
    expect(workers.dispatch(id: 'b')).to be(true)
  ensure
    20.times { release << true }
    workers&.stop
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
      workers = described_class.new(size: 1, dry_run: false)
      permit = { pool: 'tank', id: 'a', run: [42, 123], action: :restart }
      expect(workers.send(:execute, permit)).to be(success)
      request = Timeout.timeout(2) { requests.pop }
      expect(request).to include('cmd' => 'ct_oomd_restart', 'opts' => include(
        'pool' => 'tank', 'id' => 'a', 'expected_init_pid' => 42, 'expected_init_start_time' => 123
      ))
      expect(workers.instance_variable_get(:@notifications).pop(true)).to include(
        message: 'tank:a OOMd expected run accepted pid=42 start=123'
      )
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
    workers = described_class.new(size: 1, dry_run: false, notifier: ->(_event) {})
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
    workers = described_class.new(size: 1, dry_run: false, executor: ->(_permit) { raise IOError, 'uncertain fixture' },
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
    shutdown&.join(2)
  end
end
