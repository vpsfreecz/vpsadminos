# frozen_string_literal: true

require 'osctld/apparmor'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_lxc_execute_start'
require 'osctld/user_control/commands/ct_on_start'
require 'osctld/user_control/commands/ct_post_stop'
require 'osctld/user_control/commands/ct_pre_start'
require 'osctld/user_control/commands/ct_wrapper_start'
require 'osctld/utils/switch_user'
require 'osctld/container'
require 'osctld/container/lifecycle'
require 'osctld/container/run_configuration'
require 'osctld/container/run_id'
require 'osctld/cgroup/container_params'
require 'osctld/utils/cgroup_params'
require 'osctld/commands/container/cgparam_apply'
require 'osctld/devices/manager'
require 'osctld/dist_config'
require 'osctld/hook'
require 'osctld/mount/manager'
require 'osctld/mount/shared_dir'
require 'osctld/pool'

RSpec.describe OsCtld::UserControl::Commands::CtWrapperStart do
  let(:user) { Struct.new(:ugid).new(12_345) }
  let(:run_id) do
    instance_double(
      OsCtld::Container::RunId,
      to_s: 'tank:ct1:run-1'
    )
  end
  let(:run_conf) do
    instance_double(
      OsCtld::Container::RunConfiguration,
      run_id:,
      cgroup_path: '/osctl/run-1/user-owned',
      aborted?: false
    )
  end
  let(:lifecycle) do
    instance_double(
      OsCtld::Container::Lifecycle,
      authorize_lxc_start: false,
      activate_lxc_start: false,
      consume_pre_start: false,
      complete_pre_start: false,
      begin_callback: 'callback-1',
      finish_callback: false
    )
  end
  let(:ct) do
    instance_double(
      OsCtld::Container,
      id: 'ct1',
      user:,
      pool:,
      run_conf:,
      get_past_run_conf: nil,
      lifecycle:
    )
  end

  def pool
    @pool ||= Struct.new(:name).new('tank')
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    containers = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    allow(containers).to receive(:find).with('ct1', 'tank').and_return(ct)
  end

  it 'rejects a wrapper without an exact osctld lifecycle run' do
    command = described_class.new(
      user,
      id: 'ct1',
      pool: 'tank',
      pid: 123,
      client_pid: 123
    )

    expect(command.execute).to eq(
      status: false,
      message: 'managed lifecycle run not found'
    )
    expect(lifecycle).not_to have_received(:authorize_lxc_start)
  end

  it 'rejects a wrapper whose exact run lacks launch authorization' do
    command = described_class.new(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1',
      pid: 123,
      client_pid: 123
    )

    expect(command.execute).to eq(
      status: false,
      message: 'managed launch authorization denied; manual lxc-start is unsupported'
    )
    expect(lifecycle).to have_received(:authorize_lxc_start).with(run_id, 123)
  end

  it 'leases the exact user-control callback worker around execution' do
    result = described_class.run(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1',
      pid: 123,
      client_pid: 123
    )

    expect(result).to eq(
      status: false,
      message: 'managed launch authorization denied; manual lxc-start is unsupported'
    )
    expect(lifecycle).to have_received(:begin_callback).with(
      'tank:ct1:run-1',
      name: 'CtWrapperStart'
    )
    expect(lifecycle).to have_received(:finish_callback).with(
      'tank:ct1:run-1',
      'callback-1'
    )
  end

  it 'leases an id-less post-stop callback to an adopted legacy run' do
    allow(lifecycle).to receive_messages(
      adopted_legacy_callback_run_id: run_id,
      execution_run?: false,
      observe_post_stop: nil,
      run: { 'post_stop' => true }
    )
    allow(ct).to receive(:stopped).with(run_id).and_return(true)
    allow(OsCtld::Eventd).to receive(:report)

    result = OsCtld::UserControl::Commands::CtPostStop.run(
      user,
      id: 'ct1',
      pool: 'tank',
      target: 'stop'
    )

    expect(result).to eq(status: true, output: nil)
    expect(lifecycle).to have_received(:begin_callback).with(
      'tank:ct1:run-1',
      name: 'CtPostStop'
    )
    expect(lifecycle).to have_received(:finish_callback).with(
      'tank:ct1:run-1',
      'callback-1'
    )
    expect(ct).to have_received(:stopped).with(run_id)
  end

  it 'rejects id-less post-stop outside an adopted legacy run' do
    allow(lifecycle).to receive(:adopted_legacy_callback_run_id)
      .and_return(nil)

    result = OsCtld::UserControl::Commands::CtPostStop.run(
      user,
      id: 'ct1',
      pool: 'tank',
      target: 'stop'
    )

    expect(result).to eq(
      status: false,
      message: 'managed lifecycle run not found'
    )
    expect(lifecycle).not_to have_received(:begin_callback)
  end

  it 'rejects a wrapper that lies about its process ID' do
    command = described_class.new(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1',
      pid: 123,
      client_pid: 456
    )

    expect(command.execute).to eq(
      status: false,
      message: 'wrapper process identity mismatch'
    )
    expect(lifecycle).not_to have_received(:authorize_lxc_start)
  end

  it 'publishes launch only after cgroup and OOM setup complete' do
    allow(lifecycle).to receive_messages(
      authorize_lxc_start: true,
      activate_lxc_start: true
    )
    allow(OsCtld::CGroup).to receive(:mkpath_all)
    allow(File).to receive(:write)
    command = described_class.new(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1',
      pid: 123,
      client_pid: 123
    )

    expect(command.execute).to eq(status: true, output: nil)
    expect(OsCtld::CGroup).to have_received(:mkpath_all).with(
      ['', 'osctl', 'run-1', 'user-owned'],
      chown: 12_345,
      attach: true,
      leaf: false,
      pid: 123
    )
    expect(File).to have_received(:write).with('/proc/123/oom_score_adj', '0')
    expect(lifecycle).to have_received(:activate_lxc_start).with(run_id, 123)
  end

  it 'rejects pre-start when osctld-ct-start did not authorize the run' do
    command = OsCtld::UserControl::Commands::CtPreStart.new(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1',
      client_pid: 456
    )
    command.instance_variable_set(:@lifecycle_callback_id, 'callback-1')

    expect(command.execute).to eq(
      status: false,
      message: 'managed launch authorization missing; manual lxc-start is unsupported'
    )
    expect(lifecycle).to have_received(:consume_pre_start).with(
      run_id,
      client_pid: 456,
      callback_id: 'callback-1'
    )
  end

  it 'reconciles cpusets from the exact pre-start callback' do
    pool = instance_double(
      OsCtld::Pool,
      name: 'tank',
      fulfil_autostart: nil,
      fulfil_reboot: nil
    )
    cgparams = instance_double(
      OsCtld::CGroup::ContainerParams,
      apply_cpuset_for_start: nil
    )
    devices = instance_double(OsCtld::Devices::Manager, apply: nil)
    shared_dir = instance_double(OsCtld::Mount::SharedDir, create: nil)
    mounts = instance_double(OsCtld::Mount::Manager, shared_dir:)
    allow(lifecycle).to receive_messages(
      consume_pre_start: true,
      execution_run?: false,
      complete_pre_start: [true, 'effect-1']
    )
    allow(run_conf).to receive(:mount)
    allow(ct).to receive_messages(
      id: 'ct1',
      starting: true,
      pool:,
      cgparams:,
      devices:,
      mounts:,
      setup_start_menu: nil
    )
    allow(OsCtld::AppArmor).to receive(:enabled?).and_return(false)
    allow(OsCtld::Hook).to receive(:run)
    allow(OsCtld::Container::LifecycleExecutor).to receive(:release)
    command = OsCtld::UserControl::Commands::CtPreStart.new(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1',
      client_pid: 456
    )
    command.instance_variable_set(:@lifecycle_callback_id, 'callback-1')
    allow(command).to receive(:call_cmd).with(
      OsCtld::Commands::Container::CGParamApply,
      id: 'ct1',
      pool: 'tank',
      manipulation_lock: 'ignore',
      skip_cpuset: true
    ).and_return(status: true, output: nil)

    expect(command.execute).to eq(status: true, output: nil)
    expect(cgparams).to have_received(:apply_cpuset_for_start)
      .with(run_id:)
    expect(lifecycle).to have_received(:complete_pre_start).with(
      run_id,
      callback_id: 'callback-1'
    )
    expect(OsCtld::Container::LifecycleExecutor).to have_received(:release)
      .with(pool, :start, 'effect-1')
  end

  it 'reconciles the namespaced root from the exact start-host callback' do
    cgparams = instance_double(
      OsCtld::CGroup::ContainerParams,
      apply_cpuset_for_start: nil
    )
    allow(ct).to receive(:cgparams).and_return(cgparams)
    allow(OsCtld::DistConfig).to receive(:run)
    allow(OsCtld::Hook).to receive(:run)
    command = OsCtld::UserControl::Commands::CtOnStart.new(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1'
    )

    expect(command.execute).to eq(status: true, output: nil)
    expect(cgparams).to have_received(:apply_cpuset_for_start).with(run_id:)
    expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :start)
  end

  it 'aborts pre-start when a strict non-cpuset write is rejected' do
    pool = instance_double(
      OsCtld::Pool,
      name: 'tank',
      fulfil_autostart: nil,
      fulfil_reboot: nil
    )
    cgparams = instance_double(
      OsCtld::CGroup::ContainerParams,
      apply_cpuset_for_start: nil
    )
    devices = instance_double(OsCtld::Devices::Manager, apply: nil)
    mounts = instance_double(
      OsCtld::Mount::Manager,
      shared_dir: instance_double(OsCtld::Mount::SharedDir)
    )
    allow(lifecycle).to receive_messages(
      consume_pre_start: true,
      execution_run?: false
    )
    allow(run_conf).to receive(:mount)
    allow(ct).to receive_messages(
      id: 'ct1',
      starting: true,
      pool:,
      cgparams:,
      devices:,
      mounts:
    )
    allow(OsCtld::AppArmor).to receive(:enabled?).and_return(false)
    command = OsCtld::UserControl::Commands::CtPreStart.new(
      user,
      id: 'ct1',
      pool: 'tank',
      run_id: 'tank:ct1:run-1',
      client_pid: 456
    )
    command.instance_variable_set(:@lifecycle_callback_id, 'callback-1')
    allow(command).to receive(:call_cmd).with(
      OsCtld::Commands::Container::CGParamApply,
      id: 'ct1',
      pool: 'tank',
      manipulation_lock: 'ignore',
      skip_cpuset: true
    ).and_return(
      status: false,
      message: 'kernel rejected stable container cgroup parameters: pids.max'
    )

    expect(command.execute).to eq(
      status: false,
      message: 'kernel rejected stable container cgroup parameters: pids.max'
    )
    expect(cgparams).not_to have_received(:apply_cpuset_for_start)
    expect(devices).not_to have_received(:apply)
  end

  describe OsCtld::UserControl::Commands::CtLxcExecuteStart do
    let(:user) { Struct.new(:ugid).new(12_345) }
    let(:run_id) do
      instance_double(
        OsCtld::Container::RunId,
        to_s: 'tank:ct1:run-1'
      )
    end
    let(:run_conf) do
      instance_double(
        OsCtld::Container::RunConfiguration,
        run_id:,
        cgroup_path: '/osctl/run-1/user-owned'
      )
    end
    let(:lifecycle) do
      instance_double(
        OsCtld::Container::Lifecycle,
        authorize_lxc_execution: true,
        activate_lxc_start: true
      )
    end
    let(:ct) do
      instance_double(
        OsCtld::Container,
        user:,
        pool:,
        run_conf:,
        get_past_run_conf: nil,
        lifecycle:
      )
    end

    def pool
      @pool ||= Struct.new(:name).new('tank')
    end

    before do
      allow(OsCtl::Lib::Logger).to receive(:log)
      containers = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(containers).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(OsCtld::CGroup).to receive(:mkpath_all)
    end

    it 'activates one exact managed execution without yielding its launch lane' do
      command = described_class.new(
        user,
        id: 'ct1',
        pool: 'tank',
        run_id: 'tank:ct1:run-1',
        pid: 123,
        client_pid: 123
      )

      expect(command.execute).to eq(status: true, output: nil)
      expect(lifecycle).to have_received(:authorize_lxc_execution)
        .with(run_id, 123)
      expect(lifecycle).to have_received(:activate_lxc_start)
        .with(run_id, 123)
    end

    it 'rejects a manual execution without lifecycle authorization' do
      allow(lifecycle).to receive(:authorize_lxc_execution).and_return(false)
      command = described_class.new(
        user,
        id: 'ct1',
        pool: 'tank',
        run_id: 'tank:ct1:run-1',
        pid: 123,
        client_pid: 123
      )

      expect(command.execute).to eq(
        status: false,
        message: 'managed execution authorization denied; manual lxc-execute is unsupported'
      )
      expect(lifecycle).not_to have_received(:activate_lxc_start)
    end
  end
end
