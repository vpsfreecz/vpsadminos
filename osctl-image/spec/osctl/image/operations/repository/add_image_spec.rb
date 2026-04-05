# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Repository::AddImage do
  let(:repo) { instance_double(OsCtl::Repo::Local::Repository, exist?: exists, add: nil) }
  let(:exists) { true }
  let(:attrs) do
    {
      distribution: 'alpine',
      version: '3.20',
      arch: 'x86_64',
      vendor: 'vendor',
      variant: 'minimal'
    }
  end
  let(:images) { { tar: '/tmp/image-archive.tar', zfs: '/tmp/image-stream.tar' } }

  before do
    allow(OsCtl::Repo::Local::Repository).to receive(:new).with('/repo').and_return(repo)
  end

  it 'raises when the repository does not exist' do
    allow(repo).to receive(:exist?).and_return(false)

    expect { described_class.new('/repo', images, attrs, []).execute }
      .to raise_error(OsCtl::Image::OperationError, 'repository does not exist')
  end

  it 'passes attrs, tags and image files through to repo.add' do
    described_class.new('/repo', images, attrs, %w[stable current]).execute

    expect(repo).to have_received(:add).with(
      'vendor',
      'minimal',
      'x86_64',
      'alpine',
      '3.20',
      tags: %w[stable current],
      image: images
    )
  end
end
