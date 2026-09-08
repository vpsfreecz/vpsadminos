# frozen_string_literal: true

module OsCtld
  module ContainerControl
    module Commands; end
  end
end

$:.unshift(File.expand_path('../../../fixtures/ruby_load_path', __dir__))
require 'lxc'

require 'osctld/container_control/commands/state'

RSpec.describe OsCtld::ContainerControl::Commands::State::Frontend do
  let(:command_class) { OsCtld::ContainerControl::Commands::State }
  let(:run_conf) { nil }
  let(:cgroup_exists) { false }
  let(:ct) do
    Struct.new(:id, :cgroup_path, :run_conf, keyword_init: true).new(
      id: 'ct1',
      cgroup_path: '/osctl/pool.tank/group.default/user.test/ct.ct1/user-owned',
      run_conf:
    )
  end
  let(:frontend) { described_class.new(command_class, ct) }

  before do
    stub_const(
      'OsCtld::CGroup',
      Module.new do
        def self.abs_cgroup_path_exist?(_type, _path)
          false
        end
      end
    )
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path_exist?).and_return(cgroup_exists)
  end

  it 'returns stopped without forking when no runtime state or cgroup exists' do
    allow(frontend).to receive(:fork_runner)

    state = frontend.execute

    expect(state.id).to eq('ct1')
    expect(state.state).to eq(:stopped)
    expect(state.init_pid).to be_nil
    expect(frontend).not_to have_received(:fork_runner)
  end

  it 'uses LXC state when a runtime configuration exists despite missing cgroup visibility' do
    allow(frontend).to receive(:fork_runner).and_return(
      OsCtld::ContainerControl::Result.new(
        true,
        data: {
          state: 'running',
          init_pid: 1234
        }
      )
    )

    allow(ct).to receive(:run_conf).and_return(Object.new)

    state = frontend.execute

    expect(state.id).to eq('ct1')
    expect(state.state).to eq(:running)
    expect(state.init_pid).to eq(1234)
  end

  it 'uses LXC state when the cgroup exists' do
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path_exist?).and_return(true)
    allow(frontend).to receive(:fork_runner).and_return(
      OsCtld::ContainerControl::Result.new(
        true,
        data: {
          state: 'stopped',
          init_pid: nil
        }
      )
    )

    state = frontend.execute

    expect(state.id).to eq('ct1')
    expect(state.state).to eq(:stopped)
    expect(state.init_pid).to be_nil
  end

  it 'returns runner errors unchanged' do
    error = OsCtld::ContainerControl::Result.new(false, message: 'boom')
    allow(ct).to receive(:run_conf).and_return(Object.new)
    allow(frontend).to receive(:fork_runner).and_return(error)

    expect(frontend.execute).to eq(error)
  end
end
