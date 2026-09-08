# frozen_string_literal: true

require 'osctld/bpf_fs'
require 'osctld/devices/v2/bpf_link'
require 'osctld/devices/v2/bpf_program'

RSpec.describe OsCtld::Devices::V2::BpfProgram do
  let(:program) { described_class.new('newprog', nil) }
  let(:old_link) do
    OsCtld::Devices::V2::BpfLink.new(
      'oldprog', 'tank', '/sys/fs/cgroup/osctl/pool.tank/ct.testct'
    )
  end
  let(:new_link) do
    OsCtld::Devices::V2::BpfLink.new('newprog', 'tank', old_link.cgroup_path)
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
    allow(OsCtld::BpfFs).to receive(:add_pool)
  end

  it 'restores the old attachment when replacing a link pin fails' do
    calls = []
    allow(program).to receive(:run_devcgprog) do |*args|
      calls << args
      raise 'rename failed' if calls.length == 1
    end

    expect { program.replace(old_link, new_link) }.to raise_error('rename failed')
    expected_calls = [
      ['replace', old_link.path, OsCtld::BpfFs.prog_pin_path('newprog'), new_link.path],
      ['replace', old_link.path, OsCtld::BpfFs.prog_pin_path('oldprog')]
    ]
    expect(calls).to eq(expected_calls)
  end

  it 'reports the original and rollback errors when the link cannot be restored' do
    calls = 0
    allow(program).to receive(:run_devcgprog) do
      calls += 1
      raise(calls == 1 ? 'rename failed' : 'rollback failed')
    end

    expect { program.replace(old_link, new_link) }
      .to raise_error(/unable to restore BPF link.*rename failed.*rollback failed/)
  end

  it 'does not touch the link when pool validation rejects replacement' do
    invalid_link = OsCtld::Devices::V2::BpfLink.new(
      'newprog', 'dozer', old_link.cgroup_path
    )
    allow(program).to receive(:run_devcgprog)

    expect { program.replace(old_link, invalid_link) }
      .to raise_error(ArgumentError, /link on pool tank while new_link on pool dozer/)
    expect(program).not_to have_received(:run_devcgprog)
  end
end
