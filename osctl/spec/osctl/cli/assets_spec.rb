# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Assets do
  let(:klass) do
    Class.new(OsCtl::Cli::Command) do
      include OsCtl::Cli::Assets
    end
  end

  let(:command) { build_command(klass, opts:) }
  let(:opts) { {} }

  let(:assets) do
    [
      {
        type: 'dataset',
        path: '/tank/ct1',
        state: 'active',
        opts: { desc: 'rootfs' },
        errors: ['missing']
      }
    ]
  end

  it 'formats compact asset output by default' do
    allow(command).to receive(:osctld_call).and_return(assets)
    allow(command).to receive(:format_output)

    command.print_assets(:ct_assets, id: 'ct1', pool: 'tank')

    expect(command).to have_received(:format_output).with(
      assets,
      cols: [
        :type,
        :path,
        :state,
        {
          name: :purpose,
          label: 'PURPOSE',
          display: kind_of(Proc)
        }
      ],
      layout: :columns
    )
  end

  it 'adds the errors column in verbose mode' do
    verbose_command = build_command(klass, opts: { verbose: true })
    allow(verbose_command).to receive(:osctld_call).and_return(assets)
    expect(verbose_command).to receive(:format_output) do |_data, cols:, layout:|
      expect(layout).to eq(:rows)
      expect(cols.map { |col| col.is_a?(Hash) ? col[:name] : col }).to include(:errors)
    end

    verbose_command.print_assets(:ct_assets, id: 'ct1', pool: 'tank')
  end
end
