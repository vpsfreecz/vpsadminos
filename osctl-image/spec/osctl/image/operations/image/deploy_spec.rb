# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Image::Deploy do
  let(:build) do
    instance_double(
      OsCtl::Image::Operations::Image::Build,
      output_tar: '/tmp/image-archive.tar',
      output_stream: '/tmp/image-stream.tar',
      image_attrs: {
        distribution: 'alpine',
        version: '3.20',
        arch: 'x86_64',
        vendor: 'override-vendor',
        variant: 'minimal'
      }
    )
  end

  it 'creates the repository and adds the built image with the effective attrs' do
    allow(OsCtl::Image::Operations::Repository::Create).to receive(:run)
    allow(OsCtl::Image::Operations::Repository::AddImage).to receive(:run)

    described_class.new(build, '/repo', tags: %w[stable current]).execute

    expect(OsCtl::Image::Operations::Repository::Create).to have_received(:run).with('/repo')
    expect(OsCtl::Image::Operations::Repository::AddImage).to have_received(:run).with(
      '/repo',
      {
        tar: '/tmp/image-archive.tar',
        zfs: '/tmp/image-stream.tar'
      },
      build.image_attrs,
      %w[stable current]
    )
  end
end
