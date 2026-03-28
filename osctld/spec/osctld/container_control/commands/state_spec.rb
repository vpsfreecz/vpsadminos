# frozen_string_literal: true

require 'osctld/container_control/commands/state'
require 'osctld/container_control/result'

RSpec.describe OsCtld::ContainerControl::Commands::State do
  subject(:frontend) do
    Class.new(described_class::Frontend) do
      attr_accessor :fork_result

      def fork_runner
        fork_result
      end
    end.new(described_class, ct)
  end

  let(:ct) { Struct.new(:id, :cgroup_path, keyword_init: true).new(id: 'ct1', cgroup_path: '/osctl/pool.tank/ct.ct1') }

  it 'returns stopped without forking when the memory cgroup is missing' do
    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:abs_cgroup_path_exist?) { |_subsys, _path| false }

    state = frontend.execute

    expect(state.id).to eq('ct1')
    expect(state.state).to eq(:stopped)
    expect(state.init_pid).to be_nil
  end

  it 'maps fork runner output to a container state object' do
    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:abs_cgroup_path_exist?) { |_subsys, _path| true }
    frontend.fork_result = OsCtld::ContainerControl::Result.new(
      true,
      data: { state: 'running', init_pid: 4321 }
    )

    state = frontend.execute

    expect(state.id).to eq('ct1')
    expect(state.state).to eq(:running)
    expect(state.init_pid).to eq(4321)
  end
end
