# frozen_string_literal: true

# Replace the clock and kernel operations to exercise the whole budget without
# sleeping for a minute or modifying the host's cgroups.
# rubocop:disable RSpec/SubjectStub, RSpec/MultipleMemoizedHelpers, RSpec/InstanceVariable

require 'osctld/container/nfs_cancellation'
require 'osctld/container/run_id'
require 'osctld/cgroup'
require 'osctld/container/forced_stop'
require 'osctld/container_control/result'

RSpec.describe OsCtld::Container::ForcedStop do
  subject(:forced_stop) { described_class.new(ct) }

  let(:cancellation) { instance_double(OsCtld::Container::NfsCancellation, capture: nil, abort: 0) }
  let(:run_conf) { Struct.new(:init_pid, :nfs_cancellation).new(123, cancellation) }
  let(:ct) do
    Struct.new(:ident, :cgroup_path, :get_run_conf, :state)
          .new('tank:ct1', 'osctl/tank/ct.ct1/user-owned', run_conf, :running)
  end
  let(:success) { OsCtld::ContainerControl::Result.new(true) }
  let(:failure) { OsCtld::ContainerControl::Result.new(false, message: 'stop failed') }
  let(:root) { Dir.mktmpdir('forced-stop-spec-') }
  let(:trace) { [] }
  let(:stop) do
    lambda { |deadline|
      trace << [:lxc, deadline]
      success
    }
  end
  let(:recovery) do
    instance_double(OsCtld::Container::Recovery, kill_all: nil, recover_state: nil, cleanup_or_taint: true)
  end

  before do
    @clock = 0.0
    allow(forced_stop).to receive(:now) { @clock }
    allow(forced_stop).to receive(:sleep) { |duration| @clock += duration }
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(OsCtld::Container::Recovery).to receive(:new).with(ct, deadline: anything).and_return(recovery)
    allow(OsCtld::CGroup).to receive(:thaw_tree)
    allow(OsCtld::CGroup).to receive(:freeze_tree)
    allow(OsCtld::CGroup).to receive(:wait_frozen)
    allow(OsCtld::CGroup).to receive(:subsystems).and_return(['freezer'])
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path).with('freezer', ct.cgroup_path).and_return(root)
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
      .and_return(Struct.new(:state).new(:stopped))
    File.write(File.join(root, 'cgroup.procs'), '')
  end

  after { FileUtils.remove_entry(root) }

  it 'starts its clock only when forced stopping begins' do
    expect(forced_stop.started?).to be(false)
    @clock = 1000
    expect(forced_stop.run(stop:)).to be(true)
    expect(trace).to eq([[:lxc, 1050]])
    expect(cancellation).to have_received(:abort).with(wait: 5, deadline: 1005)
    expect(forced_stop.started?).to be(true)
  end

  it 'cancels before killing without a freezer completion barrier' do
    allow(cancellation).to receive(:abort) { trace << [:cancel] }
    expect(forced_stop.run(stop:)).to be(true)
    expect(trace).to eq([[:cancel], [:lxc, 50]])
    expect(OsCtld::CGroup).not_to have_received(:freeze_tree)
    expect(OsCtld::CGroup).not_to have_received(:wait_frozen)
  end

  it 'still kills when cancellation fails' do
    allow(cancellation).to receive(:abort).and_raise(IOError, 'shutdown failed')
    expect(forced_stop.run(stop:)).to be(true)
    expect(trace).to eq([[:lxc, 50]])
  end

  it 'still kills when capture or thawing fails' do
    allow(cancellation).to receive(:capture).and_raise(IOError, 'capture failed')
    allow(OsCtld::CGroup).to receive(:thaw_tree).and_raise(Errno::ENOENT)
    expect(forced_stop.run(stop:)).to be(true)
    expect(trace).to eq([[:lxc, 50]])
  end

  it 'still attempts killing when a previous daemon holds the cancellation sidecar lock' do
    allow(forced_stop).to receive(:now).and_call_original
    stub_const('OsCtld::Container::ForcedStop::CANCELLATION_HEAD_START', 0.05)
    ct.define_singleton_method(:id) { 'ct1' }
    run_id = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: ct.id)
    actual = OsCtld::Container::NfsCancellation.new(ct, run_id:, state_root: File.join(root, 'state'))
    actual.instance_variable_set(:@owner, File.open('/proc/self/ns/user'))
    actual.instance_variable_set(:@netns, File.open('/proc/self/ns/net'))
    allow(actual).to receive(:supported?).and_return(true)
    run_conf.init_pid = nil
    run_conf.nfs_cancellation = actual
    state = actual.instance_variable_get(:@state)
    state.send(:prepare)
    state.send(:write_record, state.instance_variable_get(:@identity))

    File.open(File.join(state.dir, 'lock'), File::RDWR | File::CREAT, 0o600) do |holder|
      holder.flock(File::LOCK_EX)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(forced_stop.run(stop:)).to be(true)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
      expect(trace.map(&:first)).to eq([:lxc])
      expect(actual.instance_variable_get(:@worker)).to be_nil
    end
  ensure
    actual&.close
  end

  it 'recovers immediately after an LXC error using the original deadline' do
    runner = lambda { |deadline|
      trace << [:lxc, deadline]
      @clock = 7
      failure
    }
    expect(forced_stop.run(stop: runner)).to be(true)
    expect(recovery).to have_received(:kill_all)
    expect(recovery).to have_received(:cleanup_or_taint)
    expect(trace).to eq([[:lxc, 50]])
  end

  it 'reserves the last ten seconds for recovery when LXC times out' do
    runner = lambda do |deadline|
      @clock = deadline
      raise OsCtld::ContainerControl::UserRunnerError, 'timeout'
    end
    expect(forced_stop.run(stop: runner)).to be(true)
    expect(trace).to be_empty
    expect(recovery).to have_received(:kill_all)
  end

  it 'does not report success while any container process remains' do
    File.write(File.join(root, 'cgroup.procs'), "123\n")
    expect { forced_stop.run(stop:) }
      .to raise_error(OsCtld::ContainerControl::Error, /did not stop/)
    expect(@clock).to be_within(0.001).of(60)
    expect(ct.state).to eq(:error)
    expect(recovery).to have_received(:kill_all)
    expect(recovery).not_to have_received(:recover_state)
    expect(recovery).not_to have_received(:cleanup_or_taint)
  end

  it 'detects processes stranded in a non-freezer cgroup v1 controller' do
    Dir.mktmpdir('forced-stop-cpu-') do |cpu_root|
      File.write(File.join(cpu_root, 'cgroup.procs'), "123\n")
      allow(OsCtld::CGroup).to receive(:subsystems).and_return(%w[freezer cpu])
      allow(OsCtld::CGroup).to receive(:abs_cgroup_path).with('cpu', ct.cgroup_path).and_return(cpu_root)
      expect { forced_stop.run(stop:) }
        .to raise_error(OsCtld::ContainerControl::Error, /did not stop/)
      expect(ct.state).to eq(:error)
      expect(recovery).to have_received(:kill_all)
      expect(recovery).not_to have_received(:recover_state)
    end
  end

  it 'reports cleanup failure after termination' do
    allow(recovery).to receive(:cleanup_or_taint).and_return(false)
    expect { forced_stop.run(stop: ->(_deadline) { failure }) }
      .to raise_error(OsCtld::ContainerControl::Error, /unable to clean up/)
    expect(ct.state).to eq(:error)
  end
end
# rubocop:enable RSpec/SubjectStub, RSpec/MultipleMemoizedHelpers, RSpec/InstanceVariable
