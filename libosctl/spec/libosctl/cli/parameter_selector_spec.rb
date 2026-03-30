# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cli/parameter_selector'

RSpec.describe OsCtl::Lib::Cli::ParameterSelector do
  subject(:selector) do
    described_class.new(
      all_params: %i[id state memory vendor:key],
      default_params: %i[id state]
    )
  end

  it 'returns default parameters when no option is provided' do
    expect(selector.parse_option(nil)).to eq(%i[id state])
  end

  it 'returns an empty list for an empty option' do
    expect(selector.parse_option('  ')).to eq([])
  end

  it 'returns all parameters for the all shortcut' do
    expect(selector.parse_option('all')).to eq(%i[id state memory vendor:key])
  end

  it 'extends and removes default parameters with +/- prefixes' do
    expect(selector.parse_option('+memory')).to eq(%i[id state memory])
    expect(selector.parse_option('-state')).to eq([:id])
  end

  it 'accepts an explicit default parameter override' do
    expect(selector.parse_option('+memory', default_params: [:id])).to eq(%i[id memory])
  end

  it 'allows user attributes only when configured' do
    expect(selector.parse_option('vendor:key')).to eq([:'vendor:key'])

    locked_selector = described_class.new(
      all_params: %i[id state],
      default_params: %i[id],
      allow_user_attributes: false
    )

    expect do
      locked_selector.parse_option('vendor:key')
    end.to raise_error(GLI::BadCommandLine, /unknown output parameter/)
  end

  it 'raises on unknown parameters and lists available ones in to_s' do
    expect do
      selector.parse_option('bogus')
    end.to raise_error(GLI::BadCommandLine, /unknown output parameter/)

    expect(selector.to_s).to eq("id\nstate\nmemory\nvendor:key")
  end
end
