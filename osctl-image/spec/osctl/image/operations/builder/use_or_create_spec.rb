# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Builder::UseOrCreate do
  let(:builder) { instance_double(OsCtl::Image::Builder, ctid: 'builder-1', load_attrs: nil) }
  let(:client) { instance_double(OsCtl::Image::OsCtldClient) }

  before do
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)
  end

  it 'uses an existing builder container when present' do
    allow(client).to receive(:find_container).with('builder-1').and_return(id: 'builder-1')
    allow(client).to receive(:start_container).with('builder-1')
    allow(OsCtl::Image::Operations::Builder::WaitForNetwork).to receive(:run)
    allow(OsCtl::Image::Operations::Builder::Create).to receive(:run)

    described_class.new(builder, '/scripts', vpsadminos_dir: '/repo').execute

    expect(client).to have_received(:start_container).with('builder-1')
    expect(builder).to have_received(:load_attrs).with(client)
    expect(OsCtl::Image::Operations::Builder::WaitForNetwork).to have_received(:run).with(builder)
    expect(OsCtl::Image::Operations::Builder::Create).not_to have_received(:run)
  end

  it 'creates the builder when it does not exist' do
    allow(client).to receive(:find_container).with('builder-1').and_return(nil)
    allow(OsCtl::Image::Operations::Builder::Create).to receive(:run)

    described_class.new(builder, '/scripts', vpsadminos_dir: '/repo').execute

    expect(OsCtl::Image::Operations::Builder::Create).to have_received(:run).with(
      builder,
      '/scripts',
      vpsadminos_dir: '/repo'
    )
  end
end
