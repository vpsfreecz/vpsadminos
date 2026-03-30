# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Lib do
  it 'loads the full library' do
    expect { require 'libosctl' }.not_to raise_error
    expect(OsCtl::Lib::VERSION).to be_a(String)
  end
end
