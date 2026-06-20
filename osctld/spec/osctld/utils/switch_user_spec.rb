# frozen_string_literal: true

require 'ostruct'
require 'osctld/utils/switch_user'

RSpec.describe OsCtld::Utils::SwitchUser do
  let(:host) do
    Class.new do
      include OsCtld::Utils::SwitchUser

      def log(*)
        nil
      end
    end.new
  end

  it 'builds attach settings for the container user' do
    OsCtld.define_singleton_method(:bin) { |name| "/bin/#{name}" }
    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:mkpath_all) { |*_args, **_kwargs| nil }
    allow(OsCtld::CGroup).to receive(:mkpath_all)
    ct = Struct.new(:attach_cgroup_path, :user, :prlimits, :init_pid, keyword_init: true).new(
      attach_cgroup_path: '/osctl/pool.tank/ct.ct1',
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
    expect(OsCtld::CGroup).to have_received(:mkpath_all).with(
      ['', 'osctl', 'pool.tank', 'ct.ct1'],
      chown: 12_345
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
