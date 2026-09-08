# frozen_string_literal: true

require 'osctld/container_control/frontend'
require 'osctld/container_control/result'
require 'osctld/switch_user'
require 'osctld/cgroup'

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

  it 'closes the command pipes and reaps the helper when pidfd pinning fails' do
    user = Struct.new(:sysusername, :ugid, :homedir).new('unused', 0, '/unused')
    ct = Struct.new(
      :user, :prlimits, :attach_cgroup_path, :pool, :id, :lxc_home, :log_path
    ).new(
      user, Struct.new(:export).new({}), '/unused/attach',
      Struct.new(:name).new('tank'), 'ct1', '/unused', '/unused'
    )
    frontend = frontend_class.new(Class.new, ct)
    transient = instance_double(OsCtld::ContainerControl::TransientNetwork, runner_socket: nil, close: nil)
    allow(OsCtld::ContainerControl::TransientNetwork).to receive(:new).with(ct).and_return(transient)
    allow(OsCtld::CGroup).to receive(:mkpath_all)
    allow(OsCtld::CGroup).to receive(:rmpath_all)
    allow(OsCtld::SwitchUser).to receive(:fork).and_return(234)
    allow(OsCtld::ProcessIdentity).to receive(:open).with(234).and_raise(Errno::ESRCH)
    pipes = [IO.pipe, IO.pipe]
    allow(IO).to receive(:pipe).and_return(*pipes)

    allow(Process).to receive(:wait).with(234) do
      expect(pipes.flatten).to all(be_closed)
    end
    expect do
      frontend.run_exec_runner(switch_extra_namespaces: false, transient_network: true)
    end.to raise_error(Errno::ESRCH)
    expect(Process).to have_received(:wait).with(234)
    expect(OsCtld::CGroup).to have_received(:rmpath_all).with('/unused/attach')
  ensure
    pipes&.flatten&.each { |io| io.close unless io.closed? }
  end
end
