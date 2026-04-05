# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Builder do
  subject(:builder) { described_class.new('/build-scripts', 'alpine') }

  it 'derives a stable container id from the builder name' do
    expect(builder.ctid).to eq('builder-54c5b3dd')
  end

  it 'loads configured attributes and defaults missing ones' do
    allow(OsCtl::Image::Operations::Config::ParseAttrs).to receive(:run).and_return(
      'DISTNAME' => 'Alpine',
      'RELVER' => '3.20'
    )

    builder.load_config

    expect(builder.distribution).to eq('Alpine')
    expect(builder.version).to eq('3.20')
    expect(builder.arch).to eq('x86_64')
    expect(builder.vendor).to eq('vpsadminos')
    expect(builder.variant).to eq('minimal')
  end

  it 'loads all configured attributes when present' do
    allow(OsCtl::Image::Operations::Config::ParseAttrs).to receive(:run).and_return(
      'DISTNAME' => 'Alpine',
      'RELVER' => '3.20',
      'ARCH' => 'aarch64',
      'VENDOR' => 'vendor',
      'VARIANT' => 'full'
    )

    builder.load_config

    expect(builder.arch).to eq('aarch64')
    expect(builder.vendor).to eq('vendor')
    expect(builder.variant).to eq('full')
  end

  it 'uses the provided client when loading container attributes' do
    client = instance_double(OsCtl::Image::OsCtldClient, find_container: { id: builder.ctid })

    expect(builder.load_attrs(client)).to eq(id: builder.ctid)
    expect(builder.attrs).to eq(id: builder.ctid)
  end

  it 'creates a new client when no client is provided' do
    client = instance_double(OsCtl::Image::OsCtldClient, find_container: { id: builder.ctid })
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)

    builder.load_attrs

    expect(OsCtl::Image::OsCtldClient).to have_received(:new)
    expect(builder.attrs).to eq(id: builder.ctid)
  end
end
