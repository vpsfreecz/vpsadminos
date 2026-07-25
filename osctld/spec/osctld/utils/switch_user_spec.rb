# frozen_string_literal: true

require 'ostruct'
require 'osctld/container/lifecycle'
require 'osctld/utils/switch_user'

RSpec.describe OsCtld::Utils::SwitchUser do
  let(:host) do
    Class.new do
      include OsCtld::Utils::SwitchUser

      def log(*)
        nil
      end

      def client_pid
        Process.pid
      end
    end.new
  end

  it 'builds attach settings for the container user' do
    OsCtld.define_singleton_method(:bin) { |name| "/bin/#{name}" }
    ct = Struct.new(:entry_cgroup_path, :user, :prlimits, :init_pid, keyword_init: true).new(
      entry_cgroup_path: '/osctl/pool.tank/ct.ct1',
      user: Struct.new(:sysusername, :ugid, :homedir, keyword_init: true).new(
        sysusername: 'u-alice',
        ugid: 12_345,
        homedir: '/home/alice'
      ),
      prlimits: Struct.new(:export).new({}),
      init_pid: 4321
    )

    ret = host.ct_attach(ct, 'bash', '-l')

    expect(ret[:cmd]).to eq('/bin/osctld-ct-exec')
    expect(ret[:args]).to eq(%w[bash -l])
    expect(ret[:settings][:user]).to eq('u-alice')
    expect(ret[:settings][:cgroup_path]).to eq(
      '/osctl/pool.tank/ct.ct1'
    )
    expect(ret[:settings][:attachment]).to be_nil
  end

  it 'reserves an exact lifecycle attachment before returning settings' do
    OsCtld.define_singleton_method(:bin) { |name| "/bin/#{name}" }
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      active_run_id: 'run-1',
      register_attachment: 'process-1'
    )
    ct = Struct.new(
      :id,
      :pool,
      :entry_cgroup_path,
      :user,
      :prlimits,
      :init_pid,
      :lifecycle,
      keyword_init: true
    ).new(
      id: 'ct1',
      pool: Struct.new(:name).new('tank'),
      entry_cgroup_path: '/osctl/pool.tank/ct.ct1',
      user: Struct.new(
        :sysusername,
        :ugid,
        :homedir,
        keyword_init: true
      ).new(
        sysusername: 'u-alice',
        ugid: 12_345,
        homedir: '/home/alice'
      ),
      prlimits: Struct.new(:export).new({}),
      init_pid: 4321,
      lifecycle:
    )

    ret = host.ct_attach(ct, 'bash', lifecycle: true)

    expect(lifecycle).to have_received(:register_attachment).with(
      'run-1',
      pid: Process.pid
    )
    expect(ret[:settings][:attachment]).to eq(
      pool: 'tank',
      id: 'ct1',
      run_id: 'run-1',
      process_id: 'process-1'
    )
  end

  it 'delegates container syscmd calls to ContainerControl::Commands::Syscmd' do
    cmd_class = stub_const('OsCtld::ContainerControl::Commands::Syscmd', Class.new do
      def self.run!(*); end
    end)
    allow(cmd_class).to receive(:run!).and_return(:ok)

    ct = Object.new
    expect(host.ct_syscmd(ct, %w[id], run: true)).to eq(:ok)
    expect(cmd_class).to have_received(:run!).with(ct, %w[id], run: true, valid_rcs: [])
  end
end
