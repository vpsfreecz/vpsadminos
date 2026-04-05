# frozen_string_literal: true

require 'spec_helper'

RSpec.describe VpsAdminOS::Converter do
  it 'loads the public entrypoints and net interface registrations' do
    expect { require 'vpsadminos-converter' }.not_to raise_error
    expect { require 'vpsadminos-converter/cli' }.not_to raise_error
    expect { require 'vpsadminos-converter/vz6' }.not_to raise_error

    expect(VpsAdminOS::Converter::VERSION).to be_a(String)
    expect(VpsAdminOS::Converter::NetInterface.for(:bridge)).to eq(
      VpsAdminOS::Converter::NetInterface::Bridge
    )
    expect(VpsAdminOS::Converter::NetInterface.for(:routed)).to eq(
      VpsAdminOS::Converter::NetInterface::Routed
    )
  end
end
