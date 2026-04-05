# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Builder::WaitForNetwork do
  let(:builder) { instance_double(OsCtl::Image::Builder) }

  it 'delegates to ControlledRunscript and succeeds on exit status 0' do
    allow(OsCtl::Image::Operations::Builder::ControlledRunscript).to receive(:run).and_return(0)

    expect { described_class.new(builder).execute }.not_to raise_error
    expect(OsCtl::Image::Operations::Builder::ControlledRunscript).to have_received(:run).with(
      builder,
      script: include('Waiting for network'),
      name: 'osctl-image.wait-for-network'
    )
  end

  it 'raises OperationError when the network check fails' do
    allow(OsCtl::Image::Operations::Builder::ControlledRunscript).to receive(:run).and_return(1)

    expect { described_class.new(builder).execute }
      .to raise_error(OsCtl::Image::OperationError, 'network setup failed with exit status 1')
  end
end
