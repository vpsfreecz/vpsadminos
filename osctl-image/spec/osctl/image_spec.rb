# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image do
  it 'loads the component namespaces' do
    expect(described_class::Operations::Builder).to be_a(Module)
    expect(described_class::Operations::Config).to be_a(Module)
    expect(described_class::Operations::Execution).to be_a(Module)
    expect(described_class::Operations::File).to be_a(Module)
    expect(described_class::Operations::Image).to be_a(Module)
    expect(described_class::Operations::Nix).to be_a(Module)
    expect(described_class::Operations::Repository).to be_a(Module)
    expect(described_class::Operations::Test).to be_a(Module)
  end
end
