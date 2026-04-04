# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::CpuScheduler do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'dispatches simple scheduler actions' do
    {
      status: :cpu_scheduler_status,
      enable: :cpu_scheduler_enable,
      disable: :cpu_scheduler_disable,
      upkeep: :cpu_scheduler_upkeep
    }.each do |method_name, osctld_cmd|
      command = cmd
      expect(command).to receive(:osctld_fmt).with(osctld_cmd)
      command.public_send(method_name)
    end
  end

  it 'adds derived fields to package listings' do
    command = cmd
    data = [{ id: 0, cpus: [0, 1], containers: 3, usage_score: 5.5 }]
    allow(command).to receive(:osctld_call).and_return(data)
    allow(command).to receive(:format_output)

    command.package_list

    expect(data.first[:ncpus]).to eq(2)
    expect(data.first[:containers_per_cpu]).to eq(1.5)
    expect(data.first[:usage_score_per_cpu]).to eq(2.75)
    expect(command).to have_received(:format_output)
  end

  it 'enables and disables cpu packages' do
    enable = cmd(args: ['1'])
    disable = cmd(args: ['2'])

    expect(enable).to receive(:osctld_fmt).with(:cpu_scheduler_package_enable, cmd_opts: { package: 1 })
    enable.package_enable

    expect(disable).to receive(:osctld_fmt).with(:cpu_scheduler_package_disable, cmd_opts: { package: 2 })
    disable.package_disable
  end
end
