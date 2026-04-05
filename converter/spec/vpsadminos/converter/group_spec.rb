# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/group'

RSpec.describe VpsAdminOS::Converter::Group do
  it 'builds the default group' do
    group = described_class.default

    expect(group.name).to eq('default')
    expect(group.path).to eq('default')
  end

  it 'dumps the group config' do
    group = described_class.new('ops', '/ops')

    expect(group.dump_config).to eq(
      'path' => '/ops',
      'cgparams' => []
    )
  end
end
