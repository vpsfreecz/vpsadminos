# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/user'

RSpec.describe VpsAdminOS::Converter::User do
  it 'builds the default user' do
    user = described_class.default

    expect(user.name).to eq('default')
    expect(user.ugid).to eq(1000)
    expect(user.uid_map).to eq(['0:666000:65536'])
    expect(user.gid_map).to eq(['0:666000:65536'])
  end

  it 'dumps the user config' do
    user = described_class.new('alice', 1234, ['0:100000:65536'], ['0:200000:65536'])

    expect(user.dump_config).to eq(
      'ugid' => 1234,
      'uid_map' => ['0:100000:65536'],
      'gid_map' => ['0:200000:65536']
    )
  end
end
