# frozen_string_literal: true

require 'osctld/container_control/frontend'
require 'osctld/container_control/result'
require 'osctld/switch_user'

RSpec.describe OsCtld::ContainerControl::Frontend do
  let(:frontend_class) do
    Class.new(described_class) do
      def run_exec_runner(**opts)
        exec_runner(opts)
      end
    end
  end

  it 'logs private helper diagnostics without returning them to the caller' do
    ct = Struct.new(:logs) do
      def log(level, message)
        logs << [level, message]
      end
    end.new([])
    frontend = frontend_class.new(Class.new, ct)
    payload = {
      status: false, message: 'helper execution failed (RuntimeError)',
      diagnostic: "private error\nprivate.rb:123", user_runner: false
    }

    result = frontend.send(:runner_result, payload)

    expect(ct.logs).to eq([[:warn, payload[:diagnostic]]])
    expect(result.message).to eq(payload[:message])
    expect(result.user_runner?).to be(false)
  end

  describe 'forked helper failures' do
    %i[setup execution response].each do |stage|
      it "keeps #{stage} failures separate across the real helper pipe" do
        user = Struct.new(:sysusername, :ugid, :homedir).new('unused', 0, '/root')
        ct = Struct.new(:user, :id, :ident, :lxc_home, :log_path, :logs) do
          def log(level, message)
            logs << [level, message]
          end
        end.new(user, 'ct1', 'tank:ct1', '/unused', '/unused', [])
        runner = Class.new do
          define_method(:initialize) do |**|
            raise 'private setup detail' if stage == :setup
          end

          define_method(:execute) do
            raise 'private execution detail' if stage == :execution

            Object.new.tap do |result|
              result.define_singleton_method(:to_json) { raise 'private response detail' }
            end
          end
        end
        command = stub_const('OsCtld::ContainerControl::Commands::FailureSpec', Class.new)
        command.const_set(:Runner, runner)
        frontend = frontend_class.new(command, ct)

        result = frontend.send(:fork_runner, switch_to_system: false)

        expect(result.message).to eq("helper #{stage} failed (RuntimeError)")
        expect(result.user_runner?).to eq(stage == :setup)
        expect(ct.logs.length).to eq(1)
        expect(ct.logs.first.last).to include("private #{stage} detail", __FILE__)
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
