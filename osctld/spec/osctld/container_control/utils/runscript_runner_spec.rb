# frozen_string_literal: true

require 'socket'
require 'osctld/container_control/command'
require 'osctld/container_control/utils/runscript'
require 'osctld/container_control/runner'

RSpec.describe OsCtld::ContainerControl::Utils::Runscript::Runner do
  let(:runner_class) do
    Class.new(OsCtld::ContainerControl::Runner) do
      include OsCtld::ContainerControl::Utils::Runscript::Runner
    end
  end
  let(:runner) { runner_class.new(pool: 'tank', id: 'ct1') }

  ['', 'rea'].each do |payload|
    it "bounds an open real init pipe carrying #{payload.inspect}" do
      stub_const("#{described_class}::TRANSIENT_READY_TIMEOUT", 0.05)
      reader, writer = IO.pipe
      writer.write(payload) unless payload.empty?

      expect { runner.send(:wait_transient_ready, reader) }.to raise_error(Errno::ETIMEDOUT)
    ensure
      reader&.close
      writer&.close
    end
  end

  it 'accepts readiness split over real pipe writes' do
    reader, writer = IO.pipe
    writer.write('rea')
    child = Thread.new { writer.write("dy\n") }

    expect { runner.send(:wait_transient_ready, reader) }.not_to raise_error
  ensure
    child&.join
    reader&.close
    writer&.close
  end

  it 'stops the live LXC payload before terminating its monitor' do
    stub_const("#{described_class}::TRANSIENT_EXIT_TIMEOUT", 0)
    lxc = instance_double(LXC::Container, running?: true, stop: true)
    allow(runner).to receive(:lxc_ct).and_return(lxc)
    allow(Process).to receive(:wait2).with(1234, Process::WNOHANG).and_return(nil)
    calls = []
    allow(lxc).to receive(:stop) { calls << :stop }
    allow(runner).to receive(:wait_for_process).with(1234, timeout: 0) { calls << :wait }

    runner.send(:stop_transient_runner, 1234)

    expect(calls).to eq(%i[stop wait])
  end

  it 'closes a partial pipe allocation and its private socket on EMFILE' do
    allocated = IO.pipe
    socket, peer = UNIXSocket.pair
    allow(runner).to receive(:network_socket).and_return(socket)
    calls = 0
    allow(IO).to receive(:pipe) do
      calls += 1
      raise Errno::EMFILE if calls == 2

      allocated
    end
    allow(runner).to receive(:runscript_run)

    expect { runner.send(:with_configured_network, init_script: '/unused') }
      .to raise_error(Errno::EMFILE)
    expect(runner).not_to have_received(:runscript_run)
    expect(allocated).to all(be_closed)
    expect(socket).to be_closed
    expect(peer).not_to be_closed
  ensure
    [*allocated, socket, peer].compact.each { |io| io.close unless io.closed? }
  end

  it 'closes both real pipes on fork EAGAIN without signalling an unowned PID' do
    allocated = []
    socket, peer = UNIXSocket.pair
    allow(runner).to receive(:network_socket).and_return(socket)
    allow(IO).to receive(:pipe).and_wrap_original do |original|
      pair = original.call
      allocated.concat(pair)
      pair
    end
    allow(Process).to receive(:fork).and_raise(Errno::EAGAIN)
    allow(runner).to receive(:stop_transient_runner)

    expect { runner.send(:with_configured_network, init_script: '/unused') }
      .to raise_error(Errno::EAGAIN)
    expect(runner).not_to have_received(:stop_transient_runner)
    expect(allocated.length).to eq(4)
    expect(allocated).to all(be_closed)
    expect(socket).to be_closed
    expect(peer).not_to be_closed
  ensure
    [*allocated, socket, peer].compact.each { |io| io.close unless io.closed? }
  end

  it 'releases pipes and reaps a real init child when startup closes early' do
    lxc = instance_double(LXC::Container, running?: false)
    allow(runner).to receive(:lxc_ct).and_return(lxc)
    child = nil
    descriptors = nil
    allow(runner).to receive(:runscript_run) do |opts|
      descriptors = [opts[:stdin], opts[:stdout], *opts[:close_fds]]
      child = fork do
        Process.setpgrp
        opts[:close_fds].each(&:close)
        opts[:stdout].close
        opts[:stdin].read
        exit!(0)
      end
    end

    expect { runner.send(:with_configured_network, init_script: '/unused') }.to raise_error(EOFError)
    expect(descriptors).to all(be_closed)
    expect { Process.waitpid(child, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    child = nil
  ensure
    descriptors&.each { |io| io.close unless io.closed? }
    if child
      Process.kill('KILL', child)
      Process.wait(child)
    end
  end
end
