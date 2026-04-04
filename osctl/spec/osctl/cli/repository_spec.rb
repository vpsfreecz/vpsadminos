# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Repository do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'adds repositories with prune settings' do
    command = cmd(
      args: %w[main https://repo.example],
      opts: { 'prune-enable' => true, 'prune-interval' => 3600, 'prune-older-than-days' => 7 },
      gopts: { pool: 'tank' }
    )

    expect(command).to receive(:osctld_fmt).with(
      :repo_add,
      cmd_opts: {
        pool: 'tank',
        name: 'main',
        url: 'https://repo.example',
        prune_enabled: true,
        prune_interval: 3600,
        prune_older_than_days: 7
      }
    )

    command.add
  end

  it 'enables, disables, deletes, and updates repository settings' do
    {
      enable: [:repo_enable, {}],
      disable: [:repo_disable, {}],
      delete: [:repo_delete, {}],
      set_url: [:repo_set, { url: 'https://new.example' }],
      unset_prune: [:repo_unset, { prune_enabled: false }]
    }.each do |method_name, (osctld_cmd, extra)|
      args = method_name == :set_url ? %w[main https://new.example] : ['main']
      command = cmd(args:, gopts: { pool: 'tank' })

      expect(command).to receive(:osctld_fmt).with(
        osctld_cmd,
        cmd_opts: { name: 'main', pool: 'tank' }.merge(extra)
      )

      command.public_send(method_name)
    end
  end

  it 'formats image listings and joins tags' do
    command = cmd(args: ['main'], opts: { vendor: 'default', cached: true, sort: 'distribution' }, gopts: { pool: 'tank' })

    expect(command).to receive(:osctld_fmt) do |_msg, cmd_opts:, fmt_opts:|
      expect(cmd_opts).to eq(pool: 'tank', name: 'main', vendor: 'default', cached: true)
      expect(fmt_opts[:sort]).to eq([:distribution])
      expect(fmt_opts[:opts][:tags][:display].call(%w[stable latest])).to eq('stable,latest')
    end

    command.image_list
  end

  it 'prunes images across repositories' do
    command = cmd(args: %w[main extra], opts: { 'older-than-days' => 30 }, gopts: { pool: 'tank' })

    expect(command).to receive(:osctld_fmt).with(
      :repo_image_prune,
      cmd_opts: { pool: 'tank', repositories: %w[main extra], older_than_days: 30 }
    )

    command.image_prune
  end
end
