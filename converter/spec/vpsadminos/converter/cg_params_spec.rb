# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/cg_params'

RSpec.describe VpsAdminOS::Converter::CGParams do
  subject(:params) { described_class.new }

  it 'stores scalar values as single-element arrays' do
    params.set('memory.limit_in_bytes', 1024)

    expect(params['memory.limit_in_bytes']).to eq([1024])
  end

  it 'preserves array values' do
    params.set('cpu.weight', %w[100 200])

    expect(params['cpu.weight']).to eq(%w[100 200])
  end

  it 'dumps subsystem, parameter name, and values' do
    params.set('memory.limit_in_bytes', 1024)
    params.set('cpu.weight', %w[100 200])

    expect(params.dump).to contain_exactly(
      {
        'subsystem' => 'memory',
        'name' => 'memory.limit_in_bytes',
        'value' => [1024]
      },
      {
        'subsystem' => 'cpu',
        'name' => 'cpu.weight',
        'value' => %w[100 200]
      }
    )
  end
end
