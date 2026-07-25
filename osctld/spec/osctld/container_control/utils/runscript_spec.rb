# frozen_string_literal: true

require 'osctld/apparmor'
require 'osctld/cgroup/container_params'
require 'osctld/command'
require 'osctld/utils/switch_user'
require 'osctld/container'
require 'osctld/container/lifecycle'
require 'osctld/container/lxc_config'
require 'osctld/container/run_configuration'
require 'osctld/container_control/utils/runscript'
require 'osctld/mount/manager'

RSpec.describe OsCtld::ContainerControl::Utils::Runscript::Frontend do
  subject(:frontend) do
    Class.new do
      include OsCtld::ContainerControl::Utils::Runscript::Frontend

      attr_reader :ct

      def initialize(ct)
        @ct = ct
      end
    end.new(ct)
  end

  let(:run_id) { 'tank:ct1:run-1' }
  let(:lifecycle) do
    instance_double(
      OsCtld::Container::Lifecycle,
      active_run_id: run_id,
      run: {
        'resources' => {
          'lxc_monitor' => '/osctl/ct.ct1/runs/run-1/user-owned/monitor',
          'lxc_config' => '/var/lib/lxc/ct1/config.run-1',
          'wrapper_cgroup' => '/osctl/ct.ct1/runs/run-1/user-owned/wrapper'
        }
      }
    )
  end
  let(:ct) do
    instance_double(
      OsCtld::Container,
      running?: true,
      lifecycle:
    )
  end

  before do
    allow(ct).to receive(:manipulate) do |_holder, **, &callback|
      callback.call
    end
  end

  it 'leases a running attachment from spawn until reap' do
    allow(lifecycle).to receive(:register_attachment)
      .with(run_id, pid: 123)
      .and_return('process-1')
    allow(lifecycle).to receive(:finish_process).and_return(false)

    opts = frontend.send(:attachment_runner_options, run_id)
    expect(opts.fetch(:cgroup_path))
      .to eq('/osctl/ct.ct1/runs/run-1/user-owned/monitor')
    expect(opts.fetch(:lxc_config))
      .to eq('/var/lib/lxc/ct1/config.run-1')
    process_id = opts.fetch(:on_spawn).call(123)
    opts.fetch(:on_reap).call(123, process_id)

    expect(process_id).to eq('process-1')
    expect(lifecycle).to have_received(:finish_process)
      .with(run_id, 'process-1')
  end

  it 'resumes finalization when the last running attachment reaps' do
    run_conf = Struct.new(:run_id).new(run_id)
    allow(ct).to receive_messages(
      run_conf: nil,
      get_past_run_conf: run_conf
    )
    allow(lifecycle).to receive(:finish_process)
      .with(run_id, 'process-1')
      .and_return('cleanup-1')
    allow(OsCtld::Container::LifecycleFinalizer).to receive(:spawn)

    frontend.send(:finish_attachment, run_id, 'process-1')

    expect(OsCtld::Container::LifecycleFinalizer).to have_received(:spawn)
      .with(ct, run_conf, 'cleanup-1')
  end

  it 'releases CPU scheduling only after failed-launch cgroups are removed' do
    calls = []
    recovery = instance_double(OsCtld::Container::Recovery)
    allow(OsCtld::Container::Recovery).to receive(:new)
      .with(ct)
      .and_return(recovery)
    allow(lifecycle).to receive(:other_runtime_generation?)
      .with(run_id)
      .and_return(false)
    allow(recovery).to receive(:cleanup_generation) { calls << :cleanup }
    allow(OsCtld::CpuScheduler).to receive(:unschedule_ct) do
      calls << :unschedule
    end

    frontend.send(:cleanup_failed_execution_generation, run_id)

    expect(recovery).to have_received(:cleanup_generation).with(run_id)
    expect(OsCtld::CpuScheduler).to have_received(:unschedule_ct).with(ct)
    expect(calls).to eq(%i[cleanup unschedule])
  end

  it 'retains CPU scheduling when failed-launch cgroups remain' do
    recovery = instance_double(OsCtld::Container::Recovery)
    allow(OsCtld::Container::Recovery).to receive(:new)
      .with(ct)
      .and_return(recovery)
    allow(recovery).to receive(:cleanup_generation)
      .with(run_id)
      .and_raise(Errno::EBUSY)
    allow(OsCtld::CpuScheduler).to receive(:unschedule_ct)

    frontend.send(:cleanup_failed_execution_generation, run_id)

    expect(OsCtld::CpuScheduler).not_to have_received(:unschedule_ct)
  end

  it 'waits without a deadline for an in-progress generation' do
    waiting = OsCtld::Container::Lifecycle::Request.new(
      action: :wait,
      revision: 5
    )
    running = OsCtld::Container::Lifecycle::Request.new(
      action: :running,
      run_id:
    )
    allow(lifecycle).to receive(:request_execution)
      .and_return(waiting, running)
    allow(lifecycle).to receive(:wait_for_change).with(5).and_return(true)
    allow(ct).to receive(:running?).and_return(false)

    result = frontend.send(
      :with_execution_mode,
      run: true,
      network: false
    ) do |mode, _runner_opts|
      mode
    end

    expect(result).to eq(:running)
    expect(lifecycle).to have_received(:wait_for_change).with(5)
  end

  it 'locks group membership through stopped execution admission' do
    request = OsCtld::Container::Lifecycle::Request.new(
      action: :launch,
      run_id:
    )
    group = Struct.new(:name).new('/default')
    pool = Struct.new(:name).new('tank')
    allow(lifecycle).to receive_messages(
      active_run_id: nil,
      request_execution: request
    )
    allow(ct).to receive_messages(group:, pool:)
    lock_held = false
    call_order = []
    allow(ct).to receive(:manipulate) do |_holder, **, &callback|
      lock_held = true
      callback.call
    ensure
      lock_held = false
    end
    allow(OsCtld::Commands::Group::CGParamApply).to receive(:run) do
      call_order << :group_policy
      expect(lock_held).to be(true)
      { status: true, output: nil }
    end
    allow(lifecycle).to receive(:request_execution) do
      call_order << :lifecycle
      expect(lock_held).to be(true)
      request
    end
    admission_frontend = Class.new do
      include OsCtld::ContainerControl::Utils::Runscript::Frontend

      attr_reader :ct, :generation_calls

      def initialize(ct)
        @ct = ct
        @generation_calls = []
      end

      def with_execution_generation(request, network:)
        generation_calls << [request, network]
        7
      end
    end.new(ct)

    expect(
      admission_frontend.send(
        :with_execution_mode,
        run: true,
        network: false
      )
    ).to eq(7)
    expect(OsCtld::Commands::Group::CGParamApply).to have_received(:run).with(
      name: '/default',
      pool: 'tank',
      manipulation_lock: 'wait',
      only_cpuset: true
    )
    expect(lifecycle).to have_received(:request_execution)
    expect(admission_frontend.generation_calls).to eq([[request, false]])
    expect(call_order).to eq(%i[group_policy lifecycle])
  end

  it 'prepares and finalizes an exact transient generation' do
    request = OsCtld::Container::Lifecycle::Request.new(
      action: :launch,
      run_id:,
      intent_id: nil
    )
    pool = Struct.new(:name).new('tank')
    dataset = instance_double(OsCtl::Lib::Zfs::Dataset, to_s: 'tank/ct/ct1')
    run_conf = instance_double(
      OsCtld::Container::RunConfiguration,
      run_id:,
      dataset:,
      rootfs: '/tank/ct/ct1/private',
      cgroup_path: '/osctl/ct.ct1/runs/run-1/user-owned',
      mount: nil
    )
    mounts = instance_double(
      OsCtld::Mount::Manager,
      prune: nil,
      all_entries: []
    )
    lxc_config = instance_double(
      OsCtld::Container::LxcConfig,
      configure: true,
      run_config_path: '/var/lib/lxc/ct1/config.run-1'
    )
    apparmor = instance_double(
      OsCtld::AppArmor,
      profile_name: 'ct-tank-ct1-run-1',
      namespace: 'lxc-ct-tank-ct1-run-1'
    )
    cgparams = instance_double(
      OsCtld::CGroup::ContainerParams,
      apply_cpuset_for_start: nil
    )
    transient_ct = instance_double(
      OsCtld::Container,
      pool:,
      lifecycle:,
      init_run_conf: run_conf,
      mounts:,
      netifs: [],
      lxc_config:,
      apparmor:,
      cgparams:
    )
    frontend = described_class_host.new(transient_ct)

    allow(lifecycle).to receive_messages(
      claim_effect: 'effect-1',
      set_effect_worker: true,
      effect_current?: true,
      record_resources: true,
      mark_execution_launching: true,
      finish_effect: true,
      observe_wrapper_gone: 'cleanup-1',
      wait_for_stop: :clean,
      effect_worker_exited: true
    )
    allow(OsCtld::Container::LifecycleExecutor).to receive_messages(
      acquire: 'effect-1',
      release: true
    )
    allow(OsCtld::DistConfig).to receive(:run)
    allow(OsCtld::CpuScheduler).to receive(:schedule_ct)
    allow(OsCtld::Console).to receive(:socket_path).and_return('/run/console')
    allow(OsCtld::Container::LifecycleFinalizer).to receive(:spawn)

    result = frontend.send(
      :with_execution_generation,
      request,
      network: false
    ) do |mode, runner_opts|
      expect(mode).to eq(:run)
      expect(runner_opts).to include(
        run_id:,
        lxc_config: '/var/lib/lxc/ct1/config.run-1',
        cgroup_path: '/osctl/ct.ct1/runs/run-1/user-owned/wrapper',
        reset_subtree_control_path: '/osctl/ct.ct1/runs/run-1/user-owned'
      )
      runner_opts.fetch(:on_spawn).call(Process.pid)
      7
    end

    expect(result).to eq(7)
    expect(lifecycle).to have_received(:record_resources).with(
      run_id,
      hash_including(
        dataset: 'tank/ct/ct1',
        rootfs: '/tank/ct/ct1/private',
        lxc_config: '/var/lib/lxc/ct1/config.run-1'
      ),
      effect_id: 'effect-1',
      intent_id: nil
    )
    expect(cgparams).to have_received(:apply_cpuset_for_start)
      .with(run_id:)
    expect(OsCtld::Container::LifecycleFinalizer).to have_received(:spawn)
      .with(transient_ct, run_conf, 'cleanup-1')
  end

  def described_class_host
    Class.new do
      include OsCtld::ContainerControl::Utils::Runscript::Frontend

      attr_reader :ct

      def initialize(ct)
        @ct = ct
      end
    end
  end
end
