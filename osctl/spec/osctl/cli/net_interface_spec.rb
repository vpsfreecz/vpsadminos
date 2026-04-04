# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::NetInterface do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'prepends pool and ctid when listing all interfaces by default' do
    command = cmd

    expect(command).to receive(:osctld_fmt) do |_msg, cmd_opts:, fmt_opts:|
      expect(cmd_opts).to eq(pool: nil)
      expect(fmt_opts[:cols].take(2)).to eq(%i[pool ctid])
    end

    command.list
  end

  it 'does not prepend pool and ctid when listing interfaces for one container id argument' do
    command = cmd(args: ['ct1'])

    expect(command).to receive(:osctld_fmt) do |_msg, cmd_opts:, fmt_opts:|
      expect(cmd_opts).to include(pool: nil, id: 'ct1', ids: ['ct1'])
      expect(fmt_opts[:cols].take(2)).not_to eq(%i[pool ctid])
      expect(fmt_opts[:cols]).not_to include(:ctid)
    end

    command.list
  end

  it 'respects explicit output selection' do
    command = cmd(args: ['ct1'], opts: { output: 'name,enable' })

    expect(command).to receive(:osctld_fmt) do |_msg, cmd_opts:, fmt_opts:|
      expect(cmd_opts).to include(id: 'ct1')
      expect(fmt_opts[:cols]).to eq(%i[name enable])
    end

    command.list
  end
end
