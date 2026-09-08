# frozen_string_literal: true

require 'osctld/container_control/frontend'
require 'osctld/switch_user'

RSpec.describe OsCtld::ContainerControl::Frontend, '#exec_runner' do
  let(:frontend_class) do
    Class.new(described_class) do
      def prepare(**opts)
        exec_runner(opts)
      end
    end
  end

  let(:ct) do
    user = Struct.new(:sysusername, :ugid, :homedir).new('u-alice', 12_345, '/home/alice')
    ct_class = Struct.new(
      :user, :prlimits, :attach_cgroup_path, :entry_cgroup_path, :pool, :id,
      :run_conf, :lxc_home, :log_path, :init_pid, keyword_init: true
    ) do
      def syslogns_tag(**_opts)
        'tank:ct1'
      end
    end

    ct_class.new(
      user:,
      prlimits: Struct.new(:export).new({}),
      attach_cgroup_path: '/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1/osctl.attach',
      entry_cgroup_path: '/osctl/pool.tank/ct.ct1',
      pool: Struct.new(:name).new('tank'),
      id: 'ct1',
      lxc_home: '/run/osctl/lxc',
      log_path: '/tank/log/ct/ct1.log'
    )
  end

  let(:prepared_paths) { [] }
  let(:live_paths) { Set.new }
  let(:preparations) { [] }

  before do
    paths = prepared_paths
    live = live_paths
    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:mkpath_all) do |path, **_opts|
      name = path.join('/')
      paths << name
      live << name
      Fiber.yield(:prepared)
      raise 'stop before helper attach'
    end
    cgroup.define_singleton_method(:rmpath_all) { |path| live.delete(path) }
    allow(OsCtld::SwitchUser).to receive(:fork).and_raise('unexpected helper fork')
  end

  after do
    preparations.each { |preparation| preparation.resume if preparation.alive? }
  end

  def prepare_runner(**opts)
    frontend = frontend_class.new(Class.new, ct)
    preparation = Fiber.new do
      expect do
        frontend.prepare(**opts)
      end.to raise_error(RuntimeError, 'stop before helper attach')
    end
    preparations << preparation
    expect(preparation.resume).to eq(:prepared)
    [frontend, preparation]
  end

  it 'does not remove the leaf of another prepared helper when the first helper finishes' do
    # Model the CI interleaving: both directories exist, but the second helper
    # has not attached yet when the first helper is reaped and cleans up.
    first, = prepare_runner(switch_extra_namespaces: false)
    second, = prepare_runner(switch_extra_namespaces: false)
    first.send(:cleanup_runner_cgroup, prepared_paths.first)

    expect(live_paths).to include(prepared_paths.last)
    expect(prepared_paths.last).to match(/\A#{Regexp.escape(ct.attach_cgroup_path)}\.[0-9a-f]{32}\z/)
    expect(File.dirname(prepared_paths.last)).to eq(File.dirname(ct.attach_cgroup_path))

    second.send(:cleanup_runner_cgroup, prepared_paths.last)
    expect(live_paths).to be_empty
  end

  it 'preserves an explicitly supplied placement path' do
    _, preparation = prepare_runner(switch_extra_namespaces: false, cgroup_path: '/custom/cgroup')
    preparation.resume

    expect(prepared_paths).to eq(['/custom/cgroup'])
    expect(live_paths).to include('/custom/cgroup')
  end

  it 'does not claim ownership of an explicitly supplied shared attach path' do
    _, preparation = prepare_runner(switch_extra_namespaces: false, cgroup_path: ct.attach_cgroup_path)
    preparation.resume

    expect(prepared_paths).to eq([ct.attach_cgroup_path])
    expect(live_paths).to include(ct.attach_cgroup_path)
  end

  it 'preserves the entry path for a new transient run' do
    _, preparation = prepare_runner(switch_extra_namespaces: true)
    preparation.resume

    expect(prepared_paths).to eq([ct.entry_cgroup_path])
    expect(live_paths).to include(ct.entry_cgroup_path)
  end

  it 'cleans its owned leaf if preparation fails before the helper is forked' do
    _, preparation = prepare_runner(switch_extra_namespaces: false)
    preparation.resume

    expect(live_paths).to be_empty
  end
end
