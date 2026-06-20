# frozen_string_literal: true

require 'osctld/container_control/frontend'

RSpec.describe OsCtld::ContainerControl::Frontend do
  let(:frontend_class) do
    Class.new(described_class) do
      def run_exec_runner(**opts)
        exec_runner(opts)
      end
    end
  end

  it 'does not redelegate populated ancestors when preparing an attach runner cgroup' do
    user = Struct.new(:sysusername, :ugid, :homedir, keyword_init: true).new(
      sysusername: 'u-alice',
      ugid: 12_345,
      homedir: '/home/alice'
    )
    ct = Struct.new(
      :user,
      :prlimits,
      :attach_cgroup_path,
      :pool,
      :id,
      :run_conf,
      :lxc_home,
      :log_path,
      keyword_init: true
    ).new(
      user:,
      prlimits: Struct.new(:export).new({}),
      attach_cgroup_path: '/osctl/pool.tank/ct.ct1/osctl.attach',
      pool: Struct.new(:name).new('tank'),
      id: 'ct1',
      run_conf: nil,
      lxc_home: '/run/osctl/lxc',
      log_path: '/tank/log/ct/ct1.log'
    )
    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:mkpath_all) { |*_args, **_kwargs| nil }
    allow(cgroup).to receive(:mkpath_all).and_raise('stop after cgroup preparation')
    pipes = [IO.pipe, IO.pipe]
    allow(IO).to receive(:pipe).and_return(*pipes)

    frontend = frontend_class.new(Class.new, ct)

    expect do
      frontend.run_exec_runner(switch_extra_namespaces: false)
    end.to raise_error(RuntimeError, 'stop after cgroup preparation')
    expect(cgroup).to have_received(:mkpath_all).with(
      ['', 'osctl', 'pool.tank', 'ct.ct1', 'osctl.attach'],
      chown: 12_345,
      delegate_existing: false
    )
  ensure
    pipes&.flatten&.each { |io| io.close unless io.closed? }
  end
end
