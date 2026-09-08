# frozen_string_literal: true

require 'socket'
require 'osctld/process_identity'
require 'osctld/container_control/transient_network'
require 'osctld/container_control/commands/state'

RSpec.describe OsCtld::ContainerControl::TransientNetwork do
  let(:container) { Struct.new(:cgroup_path).new('osctl/ct1') }
  let(:network) { instance_double(OsCtld::NetConfig, setup: nil) }
  let(:runner) { instance_double(OsCtld::ProcessIdentity, pid: 123, alive?: true) }
  let(:identity) { instance_double(OsCtld::ProcessIdentity, pid: 456, authenticate!: nil, alive?: true) }
  let(:server) { described_class.new(container, network) }

  before do
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!).with(container, force: true)
                                                                      .and_return(Struct.new(:state, :init_pid).new(:running, 456))
    allow(OsCtld::ProcessIdentity).to receive(:open).with(456, namespaces: %i[net user]).and_yield(identity)
  end

  after { server.close }

  it 'accepts no caller-selected PID or network payload' do
    server.runner_socket.write("{\"init_pid\":1}\n")
    server.serve(runner)

    result = JSON.parse(server.runner_socket.readline)
    expect(result.fetch('status')).to be(false)
    expect(OsCtld::ContainerControl::Commands::State).not_to have_received(:run!)
    expect(network).not_to have_received(:setup)
  end

  describe 'readiness liveness with real sockets' do
    before { stub_const("#{described_class}::READY_TIMEOUT", 0.05) }

    ['', 'rea'].each do |payload|
      it "bounds an open socket carrying #{payload.inspect}" do
        server.runner_socket.write(payload) unless payload.empty?
        worker = Thread.new { server.serve(runner) }

        expect(worker.join(1)).to eq(worker)
        expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(false)
        expect(OsCtld::ContainerControl::Commands::State).not_to have_received(:run!)
        expect(network).not_to have_received(:setup)
      ensure
        worker&.kill&.join
      end
    end

    it 'notices runner death even when another process retains the socket' do
      allow(runner).to receive(:alive?).and_return(false)
      worker = Thread.new { server.serve(runner) }

      expect(worker.join(1)).to eq(worker)
      expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(false)
      expect(OsCtld::ContainerControl::Commands::State).not_to have_received(:run!)
    ensure
      worker&.kill&.join
    end

    it 'detects an actually exited pinned helper without relying on socket EOF' do
      child = fork { exit!(0) }
      pinned = OsCtld::ProcessIdentity.new(child)
      Process.wait(child)
      child = nil
      worker = Thread.new { server.serve(pinned) }

      expect(worker.join(1)).to eq(worker)
      expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(false)
      expect(OsCtld::ContainerControl::Commands::State).not_to have_received(:run!)
    ensure
      worker&.kill&.join
      pinned&.close
      Process.wait(child) if child
    end

    it 'handles EOF before readiness without namespace or network effects' do
      server.runner_socket.close_write
      server.serve(runner)

      expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(false)
      expect(OsCtld::ContainerControl::Commands::State).not_to have_received(:run!)
      expect(network).not_to have_received(:setup)
    end
  end

  it 'pins the daemon-selected LXC init before authenticating and applying' do
    calls = []
    allow(identity).to receive(:authenticate!) { |**opts| calls << [:authenticate, opts] }
    allow(server).to receive(:authenticate_ancestry!) { |*args| calls << [:ancestry, args] }
    allow(server).to receive(:authenticate_namespaces!) { |*args| calls << [:namespaces, args] }
    allow(server).to receive(:apply) { |*args| calls << [:apply, args] }
    server.runner_socket.write("ready\n")

    server.serve(runner)

    expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(true)
    expect(calls).to eq([
                          [:authenticate, { cgroup_path: 'osctl/ct1' }],
                          [:ancestry, [identity, runner]],
                          [:namespaces, [identity]],
                          [:apply, [identity, runner]]
                        ])
  end

  it 'refuses an init outside the configured container cgroup' do
    allow(identity).to receive(:authenticate!).and_raise(Errno::EXDEV)
    server.runner_socket.write("ready\n")

    server.serve(runner)

    expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(false)
    expect(network).not_to have_received(:setup)
  end

  it 'refuses an init not descended from the pinned helper' do
    allow(identity).to receive(:read_proc_file).with('stat').and_return('456 (init) S 1 0')
    server.runner_socket.write("ready\n")

    server.serve(runner)

    expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(false)
    expect(network).not_to have_received(:setup)
  end

  it 'accepts actual descendants through pinned proc descriptors' do
    child = fork { sleep }
    OsCtld::ProcessIdentity.new(Process.pid).tap do |parent|
      OsCtld::ProcessIdentity.new(child).tap do |descendant|
        expect { server.send(:authenticate_ancestry!, descendant, parent) }.not_to raise_error
      ensure
        descendant.close
      end
    ensure
      parent.close
    end
  ensure
    Process.kill('TERM', child) if child
    Process.wait(child) if child
  end

  it 'rejects a host-namespace process even if the caller supplied a valid-looking PID' do
    pinned = OsCtld::ProcessIdentity.new(Process.pid, namespaces: %i[net user])
    expect { server.send(:authenticate_namespaces!, pinned) }
      .to raise_error(Errno::EPERM, /host user namespace/)
    expect(network).not_to have_received(:setup)
  ensure
    pinned&.close
  end

  # The kernel ownership graph needs distinct process, user and network FDs.
  # rubocop:disable RSpec/MultipleMemoizedHelpers
  describe 'namespace ownership' do
    let(:container) do
      entry = Struct.new(:ns_id, :host_id, :id_count).new(0, 100_000, 65_536)
      user = Struct.new(:uid_map, :gid_map).new([entry], [entry])
      Struct.new(:cgroup_path, :user).new('osctl/ct1', user)
    end
    let(:userns) { instance_double(IO, stat: instance_double(File::Stat, dev: 5, ino: 55)) }
    let(:netns) { instance_double(IO) }
    let(:owner) { instance_double(IO, stat: instance_double(File::Stat, dev: 5, ino: 55), close: nil) }
    let(:sys) { instance_double(OsCtl::Lib::Sys, namespace_userns: owner) }

    before do
      allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
      allow(identity).to receive(:namespace).with(:user).and_return(userns)
      allow(identity).to receive(:namespace).with(:net).and_return(netns)
      allow(identity).to receive(:read_proc_file).with('uid_map').and_return("0 100000 65536\n")
      allow(identity).to receive(:read_proc_file).with('gid_map').and_return("0 100000 65536\n")
      allow(identity).to receive(:read_proc_file).with('status').and_return("NSpid:\t456\t1\n")
    end

    it 'accepts only the configured container mapping and its own netns' do
      expect { server.send(:authenticate_namespaces!, identity) }.not_to raise_error
      expect(owner).to have_received(:close)
    end

    it 'refuses a network namespace owned by a different user namespace' do
      allow(owner).to receive(:stat).and_return(instance_double(File::Stat, dev: 5, ino: 56))
      expect { server.send(:authenticate_namespaces!, identity) }.to raise_error(Errno::EXDEV, /different user/)
      expect(owner).to have_received(:close)
    end

    it 'refuses a foreign mapping even if the process has the requested cgroup' do
      allow(identity).to receive(:read_proc_file).with('uid_map').and_return("0 200000 65536\n")
      expect { server.send(:authenticate_namespaces!, identity) }.to raise_error(Errno::EXDEV, /foreign ID mapping/)
    end

    it 'refuses an ordinary descendant masquerading as LXC init' do
      allow(identity).to receive(:read_proc_file).with('status').and_return("NSpid:\t456\t2\n")
      expect { server.send(:authenticate_namespaces!, identity) }.to raise_error(Errno::EXDEV, /not a container PID 1/)
    end
  end

  # rubocop:enable RSpec/MultipleMemoizedHelpers

  it 'rejects an exited pinned child before any namespace or network effects' do
    child = fork { sleep }
    pinned = OsCtld::ProcessIdentity.new(child, namespaces: [:net])
    Process.kill('TERM', child)
    Process.wait(child)
    child = nil
    # Model numeric reuse: the object must still use the original pidfd.
    pinned.instance_variable_set(:@pid, Process.pid)
    expect { pinned.authenticate!(cgroup_path: '/') }.to raise_error(Errno::ESRCH)
    expect(network).not_to have_received(:setup)
  ensure
    pinned&.close
    if child
      Process.kill('TERM', child)
      Process.wait(child)
    end
  end

  it 'refuses a dead or recycled helper PID' do
    allow(runner).to receive(:alive?).and_return(false)
    server.runner_socket.write("ready\n")

    server.serve(runner)

    expect(JSON.parse(server.runner_socket.readline).fetch('status')).to be(false)
    expect(network).not_to have_received(:setup)
  end
end
