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
